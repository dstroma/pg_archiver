use v5.36;
package Pg::Archiver::ArchiveWal {
  use CloudStore ();

  sub main ($class, %params) {
    my %config   = $params{'config'}->%*;
    my %ARGS     = $params{'ARGS'}->%*;
    my $filename = $ARGS{'wal-file'};

    die '--wal-file is a required command line argument in archive_wal mode'
      unless $filename;

    # open data file
    open(my $dfh, '>', $config{'metadata_file'})
      or die "Cannot open $config{'metadata_file'}: $!";

    # gzip walfile
    my $compressed_filename_w_path = "$config{'temp_save_path'}/$filename.bz2";
    my $syscall = system("bzip2 -c $config{'walfile_path'}/$filename > $compressed_filename_w_path");
    die "Cannot compress wal file." unless $syscall == 0;

    # Setup Storage
    eval "use $config{storage_class}; 1" or die "Cannot load package $config{storage_class}: $@";
    my $storage = $config{storage_class}->new(%{$config{storage_options} || {}});
    $storage->connect(%{$config{storage_conninfo} || {}});
    $storage->upload($compressed_filename_w_path => "$config{storage_path}/full_wal_$filename.bz2");

    # Verify files exist
    my $file = $storage->find("$config{storage_path}/full_wal_$filename.bz2");
    die "It would seem the upload was not successful"
      unless $file and $file->last_modified;

    # Update datafile, remove gzipped file
    # Reset partial file sequence
    my %metadata = (
      last_part_wal_seq_id   => 0,
      last_part_wal_filename => '',
      last_part_wal_offset   => 0,
      last_full_wal_filename => $filename,
    );

    # Save metadata
    truncate $dfh, 0;
    seek     $dfh, 0, 0;
    print    $dfh $_ . '=' . $metadata{$_} . "\n" for keys %metadata;
    close    $dfh;

    # Delete temporary file
    unlink $compressed_filename_w_path
      or warn "Unable to delete temporary file: $!";

    return 0;
  }
}

1
