# vim: set ts=2 sw=2 tw=0:
# vim: set expandtab:

package LoadScale::Args;

=head1 NAME

LoadScale::Args - Parse command line args

=head1 DESCRIPTION

=head1 SYNOPSIS

 my $OPTION = LoadScale::Args::get_args;

=head1 VARIABLES

 $CONFIG

=over 4

=cut

use Exporter;
@ISA    = qw(Exporter);
@EXPORT = qw(get_args);

use strict;
use warnings;

use Getopt::Long;

sub usage {
  die "Usage: $0 [--daemonize --pid PATH] [--verbose] --config PATH\n";
}

sub get_args {

  my $OPTIONS = {};

  Getopt::Long::GetOptions(
    "daemonize" => \$OPTIONS->{daemonize},
    "verbose"   => \$OPTIONS->{verbose},
    "help"      => \$OPTIONS->{help},
    "config=s"  => \$OPTIONS->{config_file},
    "pid=s"     => \$OPTIONS->{pid_file}
  );

  usage() if $OPTIONS->{help};
  usage() if !$OPTIONS->{config_file};
  usage() if ( $OPTIONS->{daemonize} xor $OPTIONS->{pid_file} );

  return $OPTIONS;
}

1;
