# vim: set ts=2 sw=2 tw=0:
# vim: set expandtab:

package LoadScale::Daemon;

=head1 NAME

LoadScale::Daemon - Daemonize current process

=head1 DESCRIPTION

=head1 SYNOPSIS

 LoadScale::Daemon::detach;

=head1 VARIABLES

 $CONFIG

=over 4

=cut

use Exporter;
@ISA    = qw(Exporter);
@EXPORT = qw(detach);

use strict;
use warnings;

use File::Pid;
use POSIX qw(setsid);

sub detach {
  my ($pid_file) = @_;

  chdir '/';
  umask 0;
  open STDIN,  '/dev/null'   or die "Can't read /dev/null: $!";
  open STDOUT, '>>/dev/null' or die "Can't write to /dev/null: $!";
  open STDERR, '>>/dev/null' or die "Can't write to /dev/null: $!";

  defined( my $pid = fork ) or die "Can't fork: $!";
  exit if $pid;

  POSIX::setsid() or die "Can't start a new session.";
  my $pidfile = File::Pid->new( { file => $pid_file } );
  $pidfile->write or die "Can't write PID file: $!";
}

1;
