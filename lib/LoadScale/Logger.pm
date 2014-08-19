# vim: set ts=2 sw=2 tw=0:
# vim: set expandtab:

package LoadScale::Logger;

=head1 NAME

LoadScale::Logger - Logging Module

=head1 DESCRIPTION

=head1 SYNOPSIS

 # init
 LoadScale::Logger::init;

 # usage
 info("hi !");
 error("oops");
 debug("trace");

 # close
 LoadScale::Logger::close;

=head1 VARIABLES

 # enable debug
 $LoadScale::Logger::debug = 1;

=over 4

=cut

use Exporter;
@ISA    = qw(Exporter);
@EXPORT = qw(init close info error debug);

use strict;
use warnings;

use Sys::Syslog qw(:standard :macros);
our $no_color = 0;
eval "use Term::ANSIColor";
if ($@) { $no_color = 1; }

our $debug = 0;

sub init {
  openlog( "loadscale-perl", "ndelay,pid", LOG_USER );
}

sub close {
  closelog();
  print color('reset');
}

sub log_msg {
  my ( $msg, $type ) = @_;

  # set log color
  my $color = 'white';
  $type eq 'info'  && do { $color = 'green'; };
  $type eq 'error' && do { $color = 'red'; };

  # send message to syslog
  syslog( $type, $msg );

  # print message to console
  my ( $sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst ) =
    localtime(time);
  $mon++;
  $year += 1900;

  my $date =
      "$year-"
    . sprintf( "%02i", $mon ) . "-"
    . sprintf( "%02i", $mday ) . " "
    . sprintf( "%02i", $hour ) . ":"
    . sprintf( "%02i", $min ) . ":"
    . sprintf( "%02i", $sec );

  $msg = "[$date] " . uc($type) . " - $msg\n";
  if ($no_color) {
    print $msg;
  }
  else {
    print colored( [$color], $msg );
  }
}

sub info  { log_msg( @_, 'info' ); }
sub error { log_msg( @_, 'warning' ); }
sub debug { log_msg( @_, 'debug' ) if $debug; }

1;
