#!/usr/bin/env perl

#
# loadscale-perl
#
# author: Nicolas Leclercq
# email:   <nicolas.private@gmail.com>

# vim: set ts=2 sw=2 tw=0:
# vim: set expandtab:

use strict;
use warnings;

use Getopt::Long;
use Config::Tiny;
use POE;
use File::Pid;
use POSIX qw(setsid);
use Net::HAProxy;
use Net::OpenStack::Compute;
use Template;
use Data::Section::Simple qw(get_data_section);

use LoadScale::Logger;

#
# Parse command line arguments
#
my $OPTIONS = {};
Getopt::Long::GetOptions(
  "daemonize" => \$OPTIONS->{daemonize},
  "verbose"   => \$OPTIONS->{verbose},
  "config=s"  => \$OPTIONS->{config_file},
  "pid=s"     => \$OPTIONS->{pid_file}
);
die "Usage: $0 [--daemonize --pid PATH] [--verbose] --config FILE\n" unless $OPTIONS->{config_file};

# enable debug
$LoadScale::Logger::debug = 1 if $OPTIONS->{verbose};

# daemonize
if ( $OPTIONS->{daemonize} and $OPTIONS->{pid_file} ) {
  chdir '/';
  umask 0;
  open STDIN,  '/dev/null'   or die "Can't read /dev/null: $!";
  open STDOUT, '>>/dev/null' or die "Can't write to /dev/null: $!";
  open STDERR, '>>/dev/null' or die "Can't write to /dev/null: $!";

  defined( my $pid = fork ) or die "Can't fork: $!";
  exit if $pid;

  POSIX::setsid() or die "Can't start a new session.";
  my $pidfile = File::Pid->new( { file => $OPTIONS->{pid_file} } );
  $pidfile->write or die "Can't write PID file: $!";
}

#
# Parse config file
#
my $CONFIG = Config::Tiny->new;
$CONFIG = Config::Tiny->read( $OPTIONS->{config_file} );

#
# Moar config
#
$CONFIG->{LB}{GROUP_NAME}  = "web-backend";
$CONFIG->{LB}{SOCKET}      = "/tmp/haproxy.sock";
$CONFIG->{LB}{GROUP_TYPE}  = "2";                                  # BACKEND
$CONFIG->{LB}{CONFIG_PATH} = "/etc/haproxy/haproxy.cfg";
$CONFIG->{LB}{RELOAD_CMD}  = "/usr/sbin/service haproxy reload";

#
# Startup
#
sub start_handler {
  my ( $kernel, $heap, $session ) = @_[ KERNEL, HEAP, SESSION ];

  # handle signal
  $kernel->sig( INT  => 'stop_handler' );
  $kernel->sig( TERM => 'stop_handler' );
  $kernel->sig( QUIT => 'stop_handler' );

  # init logger
  LoadScale::Logger::init;

  info("Starting");

  # init internal vars
  $heap->{instances} = {};
  $heap->{state}     = undef;

  # haproxy socket
  $heap->{lb}{handler} = Net::HAProxy->new( socket => $CONFIG->{LB}{SOCKET} );

  $heap->{lb}{group_name} = $CONFIG->{LB}{GROUP_NAME};
  $heap->{lb}{group_type} = $CONFIG->{LB}{GROUP_TYPE};

  # openstack control
  $heap->{openstack}{connect} = {
    auth_url   => $CONFIG->{OPENSTACK}{AUTH_URL},
    user       => $CONFIG->{OPENSTACK}{USER},
    password   => $CONFIG->{OPENSTACK}{PASSWORD},
    project_id => $CONFIG->{OPENSTACK}{PROJECT_ID}
  };

  my $compute = Net::OpenStack::Compute->new( %{ $heap->{openstack}{connect} } );

  my $networks = [];
  foreach my $network_name ( split( ',', $CONFIG->{OPENSTACK}{NETWORK_NAMES} ) ) {
    my $network_id =
      pop [ map { $_->{label} eq $network_name ? $_->{id} : () } @{ $compute->get_networks() } ];
    push $networks, { uuid => $network_id };
  }
  $heap->{openstack}{create} = {
    flavorRef => pop [
      map { $_->{name} eq $CONFIG->{OPENSTACK}{FLAVOR_NAME} ? $_->{id} : () }
        @{ $compute->get_flavors() }
    ],
    imageRef => pop [
      map { $_->{name} eq $CONFIG->{OPENSTACK}{IMAGE_NAME} ? $_->{id} : () }
        @{ $compute->get_images() }
    ],
    networks => $networks,
    security_groups =>
      [ map { { name => $_ } } split( ',', $CONFIG->{OPENSTACK}{SECURITYGROUP_NAMES} ) ],
    key_name => $CONFIG->{OPENSTACK}{KEY_NAME}
  };

  # bootstrap configuration on init
  # get all running instances with same image name and add them to load balancer
  debug("Bootstrapping configuration");
  my $image_id = $heap->{openstack}{create}{imageRef};

  foreach my $instance ( @{ $compute->get_servers() } ) {

    $instance = $compute->get_server( $instance->{id} );

    # add to lb instance running our bachend image
    if ( $instance->{image}{id} eq $image_id ) {
      $kernel->call( $session, "lb_add", { id => $instance->{id} } );
    }
  }

  # start main loop
  $kernel->post( $session, "scale" );
}

#
# Shutdown
#
sub stop_handler {
  info("Exiting");
  LoadScale::Logger::close;
}

#
# Control load blancer handler
# Modify haproxy configuration file from embded template
#
# lb_add : add instance ip as load balancer backend
# lb_remove : remove instance from backend list, schedule instance deletion
# lb_reload : kill -HUP haproxy service to force configuration reload
# lb_read_stats : read current haproxy stats
#
sub lb_control_handler {
  my ( $kernel, $heap, $session, $state, $data ) = @_[ KERNEL, HEAP, SESSION, STATE, ARG0 ];

  #
  # add instance into backend list
  #
  if ( $state eq "lb_add" ) {

    my $compute  = Net::OpenStack::Compute->new( %{ $heap->{openstack}{connect} } );
    my $instance = $compute->get_server( $data->{id} );

    # add instance to current configuration
    $heap->{instances}{ $data->{id} }{name} = $instance->{name};
    $heap->{instances}{ $data->{id} }{addr} =
      $instance->{addresses}{ $CONFIG->{OPENSTACK}{MAIN_NETWORK} }[0]{addr};

    $kernel->call( $session, "lb_reload" );

    info "New instance $data->{id} added to haproxy backend";
  }

  #
  # remove instance from backend list
  #
  if ( $state eq 'lb_remove' ) {
    if ( exists $heap->{instances}{ $data->{id} } ) {

      delete $heap->{instances}{ $data->{id} };

      $kernel->call( $session, "lb_reload" );
      info "Instance $data->{id} removed from haproxy backend";

      # schedule instance deletion
      $kernel->alarm_add( instance_delete => time() + $CONFIG->{THRESHOLD}{DESTROY_DELAY}, $data );
    }
  }

  #
  # update haproxy configuration file and reload process
  #
  if ( $state eq 'lb_reload' ) {

    # load configuration template
    debug "Updating haproxy configuration";
    my $tt       = Template->new;
    my $template = get_data_section("haproxy");
    $tt->process( \$template, { status => $heap->{instances} }, $CONFIG->{LB}{CONFIG_PATH} )
      || error $tt->error;

    # apply haproxy config
    debug "Reloading haproxy";
    qx($CONFIG->{LB}{RELOAD_CMD});
  }

  #
  # read current haproxy stats
  #
  if ( $state eq 'lb_read_stats' ) {

    debug "Updating haproxy stats";

    my $lb         = $heap->{lb}{handler};
    my $group_name = $heap->{lb}{group_name};
    my $group_type = $heap->{lb}{group_type};

    foreach my $server ( @{ $lb->stats } ) {
      if (  ( $server->{pxname} eq $group_name )
        and ( $server->{type} eq $group_type ) )
      {
        $heap->{instances}{ $server->{svname} }{rate}   = $server->{rate};
        $heap->{instances}{ $server->{svname} }{status} = $server->{status};
        debug "Stats : $server->{svname} $server->{status} $server->{rate}";
      }
    }
  }
}

#
# Openstack instance control handler
#
# instance_create : spawn new instance, schedule load balancer update
# instance_destroy : delete instance
#
sub instance_control_handler {
  my ( $kernel, $heap, $session, $state, $data ) = @_[ KERNEL, HEAP, SESSION, STATE, ARG0 ];

  my $compute = Net::OpenStack::Compute->new( %{ $heap->{openstack}{connect} } );

  # create new instance
  if ( $state eq 'instance_create' ) {
    my $instance;
    eval {
      $instance = $compute->create_server(
        { %{ $heap->{openstack}{create} }, name => $heap->{lb}{group_name} . '-' . time() } );
    };
    if ($@) {
      debug $@;
      error "Cannot create instance";
    }
    else {
      info "New cloud instance created $instance->{id}";
      $kernel->post( $session, "lb_add", { id => $instance->{id} } );
    }
  }

  # destroy instance
  if ( $state eq 'instance_delete' ) {
    eval { $compute->delete_server( $data->{id} ); };
    if ($@) {
      debug $@;
      error "Cannot delete instance $data->{id}, scheduling retry";
      $kernel->alarm_add( instance_delete => time() + $CONFIG->{THRESHOLD}{DESTROY_DELAY}, $data );
    }
    else {
      info "Cloud instance $data->{id} destroyed";
    }
  }
}

#
# Scale handler
# This is the main loop : from haproxy stats enable scale up or scale down
sub scale_handler {
  my ( $kernel, $heap, $session, $state, $data ) = @_[ KERNEL, HEAP, SESSION, STATE, ARG0 ];

  # update instance stats
  $kernel->call( $session, "lb_read_stats" );

  my $down_count = 0;
  my $up_count   = 0;
  my $count      = 0;
  my $ratio      = $CONFIG->{THRESHOLD}{INSTANCE_RATIO} * scalar keys %{ $heap->{instances} };

  foreach my $uuid ( keys %{ $heap->{instances} } ) {
    my $instance = $heap->{instances}{$uuid};

    if ( $instance->{status} eq 'UP' ) {

      if ( $instance->{rate} > $CONFIG->{THRESHOLD}{RATE_UP_LIMIT} ) {
        $up_count++;
      }
      elsif ( $instance->{rate} < $CONFIG->{THRESHOLD}{RATE_DOWN_LIMIT} ) {
        $down_count++;
      }

      $count++;
    }
  }
  debug "Stats : $up_count over / $down_count below / $count total (threshold is $ratio)"; 

  # pending operation
  if ( $heap->{state} ) {
    debug "Skipping, pending lock ($heap->{state})";
  }

  # scale up
  elsif ( $up_count > $ratio ) {
    my $MAX_INSTANCE = $CONFIG->{THRESHOLD}{MAX_INSTANCE};

    if ( $count >= $MAX_INSTANCE ) {
      error "Cannot scale up, max instance count reach ($count/$MAX_INSTANCE)";
    }
    else {
      debug "Scaling up";

      # lock
      $heap->{state} = "scale_up";
      $kernel->alarm( reset_state => time() + $CONFIG->{THRESHOLD}{SCALE_DELAY}, 0 );

      for ( 1 .. $CONFIG->{THRESHOLD}{INSTANCE_SPAWN} ) {

        # add intance, then update lb config
        $kernel->post( $session, "instance_create" );
      }
    }
  }

  # scale down
  elsif ( $down_count > $ratio ) {
    my $MIN_INSTANCE = $CONFIG->{THRESHOLD}{MIN_INSTANCE};

    if ( $count <= $MIN_INSTANCE ) {
      error "Cannot scale down, min instance count reach ($count/$MIN_INSTANCE)";
    }
    else {
      debug "Scaling down";

      # lock
      $heap->{state} = "scale_down";
      $kernel->alarm( reset_state => time() + $CONFIG->{THRESHOLD}{SCALE_DELAY}, 0 );

      # update lb config, then destroy instance
      $kernel->post( $session, "lb_remove", { id => ( keys %{ $heap->{instances} } )[0] } );
    }
  }

  # loop
  $kernel->alarm( scale => time() + $CONFIG->{THRESHOLD}{MAIN_LOOP}, 0 );
}

sub reset_state_handler {
  my ( $kernel, $heap, $session, $state, $data ) = @_[ KERNEL, HEAP, SESSION, STATE, ARG0 ];

  $heap->{state} = undef;
}

#
# POE event routing
#
POE::Session->create(
  inline_states => {
    _start => \&start_handler,
    _stop  => \&stop_handler,

    scale => \&scale_handler,

    lb_add        => \&lb_control_handler,
    lb_remove     => \&lb_control_handler,
    lb_reload     => \&lb_control_handler,
    lb_read_stats => \&lb_control_handler,

    reset_state => \&reset_state_handler,

    instance_create => \&instance_control_handler,
    instance_delete => \&instance_control_handler,
  }
);

# release the Kraken
POE::Kernel->run();
exit;

__DATA__

@@ haproxy
global
  log /dev/log    local0
  log /dev/log    local1 notice
  chroot /var/lib/haproxy
  user haproxy
  group haproxy
  daemon
  stats socket /tmp/haproxy.sock mode 0666 level admin

defaults
  log     global
  mode    http
  option  httplog
  option  dontlognull
  option contstats
  contimeout 5000
  clitimeout 50000
  srvtimeout 50000
  errorfile 400 /etc/haproxy/errors/400.http
  errorfile 403 /etc/haproxy/errors/403.http
  errorfile 408 /etc/haproxy/errors/408.http
  errorfile 500 /etc/haproxy/errors/500.http
  errorfile 502 /etc/haproxy/errors/502.http
  errorfile 503 /etc/haproxy/errors/503.http
  errorfile 504 /etc/haproxy/errors/504.http

listen stats :1936
  mode http
  stats enable
  stats hide-version
  stats realm Haproxy\ Statistics
  stats uri /
  stats auth wesh:wesh

listen web-frontend
  bind *:80
  default_backend web-backend

backend web-backend
  balance roundrobin
[% FOREACH key IN status.keys -%]
  server [% key %] [% status.$key.addr %]:80 check
[% END -%]
