use v5.40;
package Pg::Archiver 0.01 {

  my $cmd = shift @ARGV;

  # Show help? ################################################################
  my $maybe_help = sub {
    if (!$cmd or $cmd !~ m/^base_backup|archive_wal|archive_partial|recover$/) {
      say <<~IHEREDOC;
        Usage:
        pg_archiver.pl [base_backup|archive_wal|archive_partial|recover] [options]

        Options:
        --config [filename]   Filename of configuration file

        --continuous          Continuously monitor for new WAL segments
                                (applies to archive_partial only)

        --no-cleanup          Do not automatically clean up
                                (applies to archive_partial only)

        --wal-file [filename] Filename of WAL file to archive
                                (applies to archive_wal only)

        --start-server        Start the recovery server
                                (applies to recover command only)

        IHEREDOC

      exit 0;
    }
  };
  $maybe_help->();
  undef $maybe_help;

  # Parse CL Arguments ########################################################
  my $parse_argv = sub {
    my %args = ();
    while (my $arg = pop @ARGV) {
      if ($arg =~ m/^--(\S+)$/) {
        $args{$1} = undef;
      } else {
        my $val = $arg;
        $arg = pop @ARGV;
        die "Argument parsing error"
          unless $arg =~ m/^--(\S+)$/;
        $args{$1} = $val;
      }
    }
    return %args;
  };
  my %ARGS = $parse_argv->();
  undef $parse_argv;

  # Parse config ##############################################################
  die "No config file specified! Use the --config [file] argument"
    unless length $ARGS{'config'};

  require Config::PL;
  my %config = Config::PL::config_do( $ARGS{'config'} );

  # Dispatch control ##########################################################
  my $dispatcher = sub {
    my $submodule;
    $submodule = 'BaseBackup'     if $cmd eq 'base_backup';
    $submodule = 'ArchiveWal'     if $cmd eq 'archive_wal';
    $submodule = 'ArchivePartial' if $cmd eq 'archive_partial';
    $submodule = 'Recover'        if $cmd eq 'recover';

    return "Pg::Archiver::$submodule";
  };
  my $module = $dispatcher->();
  undef $dispatcher;

  eval "require $module"
    or die "Cannot load $module: $@";

  my $return = $module->main(config => \%config, ARGS => \%ARGS);
  exit $return;

}
