# vim: set ts=2 sw=2 tw=0:
# vim: set expandtab:

package LoadScale::Config;

=head1 NAME

LoadScale::Config - Parse config file

=head1 DESCRIPTION

=head1 SYNOPSIS

 my $CONFIG = LoadScale::Config::get_config("/etc/blah/blah.conf");

=head1 VARIABLES

=over 4

=cut

use Exporter;
@ISA    = qw(Exporter);
@EXPORT = qw(get_config);

use strict;
use warnings;

use Config::Tiny;

sub get_config {
  my ($config_file) = @_;

  die "Config file $config_file not found" unless -e $config_file;

  my $CONFIG = Config::Tiny->new;
  $CONFIG = Config::Tiny->read($config_file);

  die "Cannot parse $config_file config file" unless defined $CONFIG;

  return $CONFIG;
}

1;
