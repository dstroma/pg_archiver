use v5.26;
use warnings;
use Test::More 0.98;

use_ok $_ for qw(
    Pg::Archiver
    Pg::Archiver::ArchivePartial
    Pg::Archiver::ArchiveWal
    Pg::Archiver::BaseBackup
    Pg::Archiver::Recover
);

done_testing;

