use v5.36;
package Pg::Archiver::ArchivePartial {
  use DBI;
  use CloudStore;
  use experimental 'try';
  use Fcntl qw(:flock);

  my $stop              = 0;
  my $last_cleanup_time = 0;
  my $cleanup_interval  = 10_000; # about 2h 45m
  my $sleep_interval    = 15; # seconds
  my $check_connections = 0;
  my $check_connection_interval  = 60*5;
  my $last_connection_check_time = 0;
  my %config;

  sub main ($class, %params) {
    %config      = $params{'config'}->%*;
    my %ARGS     = $params{'ARGS'}->%*;
    my $filename = $ARGS{'wal-file'};

    my $continuous = exists $ARGS{'continuous'};
    my $no_cleanup = exists $ARGS{'no-cleanup'};

    $SIG{TERM} = sub { $stop = 1 };

    # Connect to database
    my $dbh;
    my $storage;

    while (!$stop) {
      affirm_connections(\$dbh, \$storage);
      tick($dbh, $storage);
      cleanup($dbh, $storage)
        if !$no_cleanup and $last_cleanup_time < time() - $cleanup_interval;
      sleep $sleep_interval
        if $continuous;
      $check_connections = 1
        if $continuous;
      $stop = 1
        if !$continuous;
    }

    $dbh->disconnect();
  }

  sub affirm_connections ($ref_dbh, $ref_storage) {
    my $local_dbh;
    unless ($ref_dbh and $$ref_dbh and $ref_dbh->$*->do("SELECT 1")) {
      $local_dbh = DBI->connect("dbi:Pg:database=postgres", $config{'db_username'}, $config{'db_password'})
        or die DBI::errstr();
      $$ref_dbh = $local_dbh;
    }

    # Connect to cloudfiles
    eval "use $config{storage_class}; 1" or die "Cannot load package $config{storage_class}: $@";
    my $storage = $config{storage_class}->new(%{$config{storage_options} || {}});
    $storage->connect(%{$config{storage_conninfo} || {}});
    $$ref_storage = $storage;
  }

  sub tick ($dbh, $storage) {
    my ($sqlcol) = $dbh->selectrow_array('SELECT pg_walfile_name_offset(pg_current_wal_lsn())');
    $sqlcol =~ m/\((\w+),(\w+)\)/ or die 'Cannot figure out filename and offset';
    my ($wal_filename, $offset_new) = ($1, $2);

    # open data file
    unless (-e $config{'metadata_file'}) {
      system('touch', $config{'metadata_file'});
    }
    open(my $dfh, '+<', $config{'metadata_file'}) or die "Cannot open $config{'metadata_file'}: $!";
    flock($dfh, LOCK_EX);
    my %metadata = map { chomp $_; split /=/, $_ } <$dfh>;

    # No-op?
    if (%metadata) {
      if ($wal_filename eq $metadata{'last_part_wal_filename'} and $offset_new == $metadata{'last_part_wal_offset'}) {
        print "No changes to walfile.\n";
        flock($dfh, LOCK_UN);
        close($dfh);
        return 0;
      }
    }

    # Start over at the beginning of the WAL file?
    if (!%metadata or $wal_filename ne $metadata{'last_part_wal_filename'}) {
      $metadata{'last_part_wal_offset'} = 0;
      $metadata{'last_part_wal_seq_id'} = 0;
    }

    # Determine sequence id
    my $offset_old =  $metadata{'last_part_wal_offset'} || 0;
    my $seq_id     = ($metadata{'last_part_wal_seq_id'} || 0) + 1;
    $metadata{'last_part_wal_seq_id'}++;
    $metadata{'last_part_wal_offset'} = $offset_new;
    $metadata{'last_part_wal_filename'} = $wal_filename;

    # copy wal segment
    my $tempfile = $config{'temp_save_path'} . '/' . 'partial_' . $wal_filename . '_' . $seq_id . '.tmp';
    open(my $fh_walin, '<', $config{'walfile_path'} . '/' . $wal_filename) or die "Cannot open $wal_filename: $!";
    open(my $fh_walout, '>', $tempfile) or die "Cannot create temporary file: $!";
    binmode($fh_walin);
    binmode($fh_walout);
    sysseek($fh_walin, $offset_old, 0);
    my $length = $offset_new - $offset_old;
    my $bytes_read = 0;
    for (my $i = 1; $i <= int($length / 1024) + 1; $i++) {
      my $bytes_to_read = ($i * 1024 > $length)  ?  ($length - ($i - 1) * 1024)  :  1024;
      sysread($fh_walin, my $buf, $bytes_to_read);
      print $fh_walout $buf;
      $bytes_read += $bytes_to_read;
    }
    close($fh_walin);
    close($fh_walout);

    # gzip
    my $syscall = system("bzip2 $tempfile -f");
    die "Cannot bzip2 wal file." unless $syscall == 0;

    # use an existing container
    my $objname   = 'part_wal_' . $wal_filename . '_' . $offset_old . '-' . $offset_new . '.bz2';
    $storage->upload("$tempfile.bz2" => "$config{storage_path}/$objname") or die "Cannot upload $tempfile.gz2 to $objname";
    print "Saved $objname.\n";

    # Save metadata
    truncate($dfh, 0);
    seek($dfh, 0, 0);
    print $dfh "$_=$metadata{$_}\n" for keys %metadata;
    flock($dfh, LOCK_UN);
    close($dfh);

    # Delete temporary file
    unlink "$tempfile.bz2";

    print "Done with uploads.\n";
  }

  sub cleanup ($dbh, $storage) {
    # Delete partial walfiles that are older than the newest full wall
    try {
      # Sort old to new
      my @full_wals = sort { $a->last_modified <=> $b->last_modified } $storage->find(in => $config{storage_path}, prefix => 'full_wal');
      my @part_wals = sort { $a->last_modified <=> $b->last_modified } $storage->find(in => $config{storage_path}, prefix => 'part_wal');
      my $newest_full_wal = pop @full_wals;
      foreach my $part_wal (@part_wals) {
        if (
          $part_wal->last_modified <= $newest_full_wal->last_modified
          and extract_wal_name($part_wal->name) le extract_wal_name($newest_full_wal->name)
        ) {
          $storage->delete_file($config{storage_path} . '/' . $part_wal->name);
          print "Deleted ${\$part_wal->name} (it is older than ${\$newest_full_wal->name}).\n";
        }
      }
    } catch ($e) {
      warn $e;
    }
    print "Done with cleanup.\n";
    $last_cleanup_time = time();
  }

}

1;
