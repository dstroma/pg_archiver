use v5.26;
use warnings;
use experimental 'signatures';
package Pg::Archiver::Recover {
  use autodie;
  use CloudStore ();
  use DBI;
  use File::Path            qw/ make_path /;
  use File::Spec::Functions qw/ catfile catdir /;
  use constant WAL_FILE_SIZE        => 16 * 1024 * 1024;
  use constant RECOVERY_SERVER_PORT => 6543;

  sub main ($class, %params) {
    my %config   = $params{'config'}->%*;
    my %ARGS     = $params{'ARGS'}->%*;

    # Create a recovery identifier and recovery directories
    my $recovery_id   = sprintf '%x', time();
    my $recovery_name = "data_$recovery_id";
    my $recovery_dir  = "$config{recovery_dir}/$recovery_name";

    say '';
    say "Recovery id will be : $recovery_id";
    say "Recovery directory  : $recovery_dir";

    make_path $recovery_dir . '/pg_wal_from_archive';
    make_path $recovery_dir . '/pg_wal';
    make_path $recovery_dir . '/pg_wal/archive_status';
    chmod 0750, $recovery_dir;

    # Connect to cloud file storage service
    say '';
    say 'Connecting to storage service and searching for base backups...';
    eval "use $config{storage_class}; 1"
      or die "FATAL! Cannot load package $config{storage_class}: $@";
    my $storage = $config{storage_class}->new(
      ($config{storage_options}  || {}) -> %*
    );
    $storage->connect(
      ($config{storage_conninfo} || {}) -> %*
    );

    # Find base backup and determine which one is the newest
    my @files = $storage->find(in => $config{storage_path}, prefix => 'basebackup', pattern => qr/\.tar\.(gz|bz2)$/);
    my $basebackup_a = (sort { $b->last_modified <=> $a->last_modified } @files)[0]; # Choose newest by time
    my $basebackup_b = (sort { $b->name          cmp $a->name          } @files)[0]; # Choose newest by name

    $basebackup_a->name eq $basebackup_b->name
      or die 'FATAL! Not sure which base backup file to use! ' .
      $basebackup_a->name . ' or ' . $basebackup_b->name . "\n";
    my $basebackup = $basebackup_a;
    undef $basebackup_a;
    undef $basebackup_b;

    # Download base backup
    say 'Downloading base backup file ', $basebackup->name, ' ...';
    my $basebackup_local_filename = $recovery_dir . '/' . $basebackup->name;
    $storage->download($basebackup->location => $basebackup_local_filename);

    # Get meta file and label file
    $basebackup->name =~ m/^(.+)\.tar\.(gz|bz2)$/ || die 'FATAL! Cannot determine meta filename';
    my $remote_meta_filename  = $config{storage_path}.'/'.$1.'.meta';
    my $remote_label_filename = $config{storage_path}.'/'.$1.'.label';
    $storage->download($remote_label_filename => "$recovery_dir/backup_label");
    my $basebackup_pg_meta;
    $storage->download($remote_meta_filename => \$basebackup_pg_meta);
    my %basebackup_pg_meta = map { split /=/, $_ } split /\n/, $basebackup_pg_meta;

    say 'Decompressing base backup file ...';
    system("tar -xjf $basebackup_local_filename -C $recovery_dir") == 0
      or die 'FATAL! Could not decompress base backup file, exiting.';
    unlink $basebackup_local_filename
      or warn "Could not delete $basebackup_local_filename: $!";

    # Determine starting WAL file needed
    my ($start_wal, $start_wal_offset) = $basebackup_pg_meta{'pg_stop_backup_name_offset'} =~ m/(\d+),(\d+)/;

    # Get full WAL files
    # Can't string sort on name because of files like full_wal_000000010000000000000030.00000060.backup
    say '';
    say 'Searching for full WAL files...';
    my @full_wals = (sort {
      $a->last_modified <=> $b->last_modified
    } $storage->find(
      in     => $config{storage_path},
      prefix => 'full_wal'
    )) or die 'FATAL: No WAL files!';

    my %latest_wal_info = (
      timestamp => $full_wals[-1]->last_modified,
      name      => extract_wal_name($full_wals[-1]->name)
    );

    say 'Downloading and decompressing full WAL files...';
    foreach my $i (@full_wals) {
      my ($wal_sequence_num) = $i->name =~ m`^full_wall_(\d+)\.`; # get the main sequence number
      next unless $wal_sequence_num ge $start_wal;                # Skip files we don't need. We only need ones newer than start_wal

      say "\tgot wal file: " . $i->name;
      $storage->download($i->location => $recovery_dir . '/pg_wal_from_archive/' . substr($i->name, 9));
      my $extract_ok = system("bunzip2 $recovery_dir" . '/pg_wal_from_archive/' . substr($i->name, 9));
      $extract_ok == 0
        or die 'FATAL! Could not decompress ' . $i->name . ', exiting.'
    }

    # Get partial WAL segments
    say '';
    say 'Searching for partial WAL file segments...';
    my @objects2 = sort { $a->last_modified <=> $b->last_modified } $storage->find(in => $config{storage_path}, prefix => 'part_wal');
    my %tmp_files = ();
    foreach my $i (@objects2) {
      my $partial_wal_name = extract_wal_name($i->name);
      next if $i->last_modified <= $latest_wal_info{timestamp} or $partial_wal_name le $latest_wal_info{name};
      say $i->name;
      $storage->download($i->location => "$config{'temp_save_path'}/get_" . $i->name);
      my $extract_ok = system("bunzip2 -f $config{'temp_save_path'}/get_" . $i->name);

      # Merge the partial files
      $tmp_files{ $partial_wal_name } = 1;
      open(my $fhout, '>>', $recovery_dir . '/pg_wal_from_archive/' . $partial_wal_name) or die "FATAL! Cannot open file for output: $!";
      open(my $fhin, '<', "$config{'temp_save_path'}/get_" . substr($i->name, 0, -4)) or die "FATAL! Cannot open file for input: $!";
      binmode($fhout);
      binmode($fhin);
      print $fhout $_ while <$fhin>;
      close($fhout);
      close($fhin);
    }

    # Zero-pad WAL files
    say '';
    say 'Zero-padding partial WAL segments...';
    my $pfix = $recovery_dir . '/pg_wal_from_archive/';
    foreach my $key (keys %tmp_files) {
      my $sz = -s $pfix.$key;
      open my $fhout, '>>', $pfix.$key or die "FATAL! Cannot open $pfix$key for appending: $!";
      print $fhout chr(0) for $sz .. WAL_FILE_SIZE;
      close($fhout);
    }

    # Remove old pid file and server logs
    say '';
    say 'Removing old pid file and renaming pg_log to pg_log_old (if they exist)...';
    system "rm $recovery_dir/postmaster.pid"                  if -e "$recovery_dir/postmaster.pid";
    system "mkdir $recovery_dir/pg_log_old"                   if -e "$recovery_dir/pg_log";
    system "mv $recovery_dir/pg_log $recovery_dir/pg_log_old" if -e "$recovery_dir/pg_log";
    system "touch $recovery_dir/postgresql.conf";

    # Ensure pg_hba is present
    $config{'pghba'} ?
      system "cp $config{'pghba'} $recovery_dir/pg_hba.conf" :
      warn 'WARNING: No pga_hba.conf path in config file, you will have to add one manually.';

    # Create a recovery.conf file (ver < 12) / or add restore command to postgresql.conf
    my $restore_command = "restore_command = 'cp $recovery_dir/pg_wal_from_archive/%f %p'";
    my $recovery_file = 'postgresql.conf';
    say '';
    say 'Creating restore commands in ' . $recovery_file;
    if (open(my $fo, '>>', "$recovery_dir/$recovery_file")) {
      print $fo "# Automatically generated recovery.conf by walrecover.pl\n";
      print $fo "$restore_command\n";
      close($fo);
    } else {
      warn "Cannot create a recovery.conf file: $!";
      warn "Add the following restore command to recovery.conf:\n$restore_command\n";
    }
    system "touch $recovery_dir/recovery.signal";

    my $maybe_config = $config{pgconf} ? qq` -c config_file=$config{pgconf}` : '';
    my $server_start_command =
      qq`$config{pgbin_dir}/pg_ctl start -D $recovery_dir -o '-p ${\RECOVERY_SERVER_PORT}` .
      qq`$maybe_config -c archive_mode=off -c hot_standby=off'`;

    say '';
    say 'All done!';
    say 'Use command below to start server on port 6543 (remove recovery.conf when recovery is complete):';
    say $server_start_command;
    say '';
    say 'Use command below to connect to the server:';
    say "\t" . 'psql -p 6543';
    say 'or';
    say "\t" . 'sudo -u postgres psql -p 6543';
    say '';
  }

  sub extract_wal_name ($name) {
    $name =~ m/^(full|part)_wal_(\w+)[_\.]/ ? $2 : undef;
  }
}

1;
