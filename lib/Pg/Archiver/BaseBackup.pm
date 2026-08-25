use v5.36;
package Pg::Archiver::BaseBackup {
  use CloudStore ();
  use DBI ();
  use POSIX qw(strftime);

  my @colors = qw(
    black white
    red orange yellow green blue indigo violet
    bronze silver gold
    amber ash aqua azure
    beige blond blush brown
    coral cyan
    ivory
    gray
    jade
    lemon lilac lime
    maroon mint
    navy
    olive
    pink plum purple
    rose ruby rust
    salmon
    tan teal
  );

  sub create_backup_label {
    my $dt        = strftime("%Y%m%d_%H%M%S", gmtime(time));
    my $rand_part = $colors[int(rand(scalar @colors))];
    return $dt . '_' . $rand_part;
  }

  sub main ($class, %params) {
    my %config = $params{'config'}->%*;

    # Make sure tmpdir exists
    mkdir $config{'temp_save_path'}
      or die "config 'temp_save_path' does not exist/cannot be created. $!"
      unless length $config{temp_save_path} and -d $config{temp_save_path};

    # Create a backup label
    my $backup_label = create_backup_label();

    # Connect to database and order a start backup
    my $dbh = DBI->connect('dbi:Pg:database=postgres', $config{'db_username'}, $config{'db_password'})
      or die DBI::errstr();
    $dbh->selectrow_array('SELECT pg_backup_start(?, false)', undef, $backup_label)
      or die DBI::errstr();

    # Backup the data directory
    my $cmd = "tar -cjf $config{'temp_save_path'}/$backup_label.tar.bz2 -C $config{'pgdata_dir'} --exclude pg_wal ./";
    say "Backing up data directory using:\n$cmd";
    system $cmd;
    die "Backup file not created successfully!"
      unless -s "$config{'temp_save_path'}/$backup_label.tar.bz2";

    # Stop backup
    my ($pg_stop_backup_lsn, $pg_labelfile, $pg_mapfile) = $dbh->selectrow_array(
      'SELECT lsn, labelfile, spcmapfile FROM pg_backup_stop()'
    ) or die DBI::errstr();
    my ($pg_stop_backup_loc) = $dbh->selectrow_array("SELECT pg_walfile_name_offset(?)", undef, $pg_stop_backup_lsn);
    $dbh->disconnect;

    my $backup_meta = "pg_stop_backup=$pg_stop_backup_lsn\n"
                    . "pg_stop_backup_name_offset=$pg_stop_backup_loc\n";

    # Setup cloud storage
    eval "use $config{storage_class}; 1"
      or die "Cannot load package $config{storage_class}: $@";

    my $storage = $config{storage_class}->new(%{$config{storage_options} || {}});
    $storage->connect(%{$config{storage_conninfo} || {}});

    # Upload
    $storage->upload("$config{'temp_save_path'}/$backup_label.tar.bz2" => "$config{storage_path}/basebackup_$backup_label.tar.bz2");
    $storage->upload(\$backup_meta                                     => "$config{storage_path}/basebackup_$backup_label.meta");
    $storage->upload(\$pg_labelfile                                    => "$config{storage_path}/basebackup_$backup_label.label");
    $storage->upload(\$pg_mapfile                                      => "$config{storage_path}/basebackup_$backup_label.scpmap");

    # Verify files exist
    my $f1 = $storage->find("$config{storage_path}/basebackup_$backup_label.tar.bz2");
    my $f2 = $storage->find("$config{storage_path}/basebackup_$backup_label.meta");
    die "It would seem the upload to cloud storage was not successful" unless $f1 and $f2;

    # Delete local backup file and exit
    unlink("$config{'temp_save_path'}/$backup_label.tar.bz2");
    return 0;
  }
}
