use v5.36;
package Pg::Archiver::Recover {
  use CloudStore ();
  use DBI;
  use File::Path     qw/ make_path  /;
  use Scalar::Util   qw/ refaddr    /;
  use List::Util     qw/ max maxstr /;
  use autodie;

  sub main ($class, %params) {
    my %config   = $params{'config'}->%*;
    my %ARGS     = $params{'ARGS'}->%*;
    my $filename = $ARGS{'wal-file'};

    # Create a recovery identifier
    my $recovery_id   = sprintf('%x', time());
    my $recovery_name = 'data_' . $recovery_id;
    my $recovery_dir  = "$config{recovery_dir}/$recovery_name";

    say '';
    say "Recovery id will be   :  $recovery_id.";
    say "Recovery directory is :  $recovery_dir.";

    # Create directories
    make_path $recovery_dir . '/pg_wal_from_archive';
    make_path $recovery_dir . '/pg_wal';
    make_path $recovery_dir . '/pg_wal/archive_status';
    chmod 0700, $recovery_dir;

    # Connect to cloudstorage
    say '';
    say 'Connecting to cloudstorage and searching for base backups...';
    eval "use $config{storage_class}; 1" or die "FATAL! Cannot load package $config{storage_class}: $@";
    my $storage = $config{storage_class}->new(%{$config{storage_options} || {}});
    $storage->connect(%{$config{storage_conninfo} || {}});

    my @files = $storage->find(in => $config{storage_path}, prefix => 'basebackup', pattern => qr/\.tar\.(gz|bz2)$/);
    my $basebackup_a = (sort { $b->last_modified <=> $a->last_modified } @files)[0]; # Choose newest by time
    my $basebackup_b = (sort { $b->name          cmp $a->name          } @files)[0]; # Choose newest by name

    # Verify we are looking at the newest base backup
    unless (refaddr $basebackup_a == refaddr $basebackup_b) {
      die 'FATAL! Not sure which base backup file to use!';
    }
    my $basebackup = $basebackup_a;

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
    say '';
    say 'Searching for full WAL files...';
    my @full_wals = sort {
      $a->last_modified <=> $b->last_modified
    } $storage->find(
      in     => $config{storage_path},
      prefix => 'full_wal'
    );

    # Doesn't work because e.g. full_wal_000000010000000000000030.00000060.backup.bz2
    # Verify correct sort order
    #my @full_wals_b = sort { $a->name cmp $b->name } @full_wals;
    #for my $i (0..$#full_wals) {
    #  if (refaddr $full_wals[$i] != refaddr $full_wals_b[$i]) {
    #    use Data::Dumper;
    #    die 'Sorting wals by time vs. name leads to different order'.
    #    Dumper { full_wals_by_last_modified => \@full_wals, full_wals_by_name => \@full_wals_b };
    #  }
    #}

    my %latest_wal_info = (
      timestamp => $full_wals[-1]->last_modified,
      name      => extract_wal_name($full_wals[-1]->name)
    );

    say 'Downloading and decompressing full WAL files...';
    foreach my $i (@full_wals) {
      my $wal_sequence_num = (split(/_|\./, $i->name))[2]; # e.g. part_wal_322307982739823.tar.bz2 -- we want big number
      next unless $wal_sequence_num ge $start_wal; # Skip files we don't need. We only need ones newer than start_wal
      say $i->name;
      $storage->download($i->location => $recovery_dir . '/pg_wal_from_archive/' . substr($i->name, 9));
      my $extract_ok = system("bunzip2 $recovery_dir" . '/pg_wal_from_archive/' . substr($i->name, 9));
      if ($extract_ok != 0) {
        die 'FATAL! Could not decompress ' . $i->name . ', exiting.';
      }
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
      for (my $i = $sz; $i < 1024*1024*16; $i++) {
        print $fhout chr(0);
      }
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
    if ($config{'pghba'}) {
      system "cp $config{'pghba'} $recovery_dir/pg_hba.conf";
    }

    # Create a recovery.conf file
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

    my $maybe_config = $config{'pgconf'} ? "-c config_file=$config{'pgconf'}" : '';
    my $server_start_command = "$config{'pgbin_dir'}/pg_ctl start -D $recovery_dir -o '-p 6543 $maybe_config -c archive_mode=off -c hot_standby=off'";

    say '';
    say '...all done!';
    say 'Recovery data directory is ' . $recovery_dir;
    say 'Use command below to start server. Remove recovery.conf when recovery done. ';
    say $server_start_command;
    say '';
  }

  sub extract_wal_name ($name) {
    $name =~ m/^(full|part)_wal_(\w+)[_\.]/ ? $2 : undef;
  }
}

1;
