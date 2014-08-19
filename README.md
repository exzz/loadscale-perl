# LoadScale-perl

With loadscale-perl you can manage your backend instance number from your haproxy statistics

## How does it work ?

loadscale-perl is a daemon running side by side with haproxy process. It reads session numbers from haproxy stats socket and, following user defined thresholds, spawns or detroys new cloud instance to handle load.

** Example **
On boot, loadscale-perl will identify backend instance based on their running IMAGE_NAME, and update haproxy configuration.

Scale up :
If INSTANCE_RATIO * 100 instances have sessions rate above RATE_UP_LIMIT, this script will create INSTANCE_SPAWN new instance and update haproxy configuration to includes these new VM into backend.

Scale down :
If INSTANCE_RATIO * 100 instances have sessions rate below RATE_DOWN_LIMIT, this script will remove instance from haproxy configuration one by one and wait DESTROY_DELAY before destroying corresponding cloud instance. This delay gives time to clients to end their session. 

A SCALE_DELAY seconds lock is enable after each scale operation (up or down). This interval should give enough time to complete instance boot (cloud creation, OS boot and load balanced application set up).

## Installation

Ubuntu :
```
sudo aptitude install haproxy cpanminus build-essential libssl-dev
sudo cpanm Net::OpenStack::Compute LWP::Protocol::https POE File::Pid Net::HAProxy Template Data::Section::Simple Sys::Syslog Config::Tiny
```

Enable fancy colors :
```
sudo cpanm Term::ANSIColor
```

## Getting started

loadscale-perl read configuration from a INI configuration file :

```
[OPENSTACK]
; Openstack API credential
AUTH_URL            = https://identity.fr1.cloudwatt.com/v2.0
USER                = nicolas.leclercq@cloudwatt.com
PASSWORD            = mysecretpassword
PROJECT_ID          = mytenantid

; instance configuration
IMAGE_NAME          = web-image
FLAVOR_NAME         = t1.cw.tiny
KEY_NAME            = mykey
SECURITYGROUP_NAMES = default,web
NETWORK_NAMES       = front,back
; common network between haproxy and backends
MAIN_NETWORK        = front

[THRESHOLD]
; stats update frequency
MAIN_LOOP           = 20

; minimun instances into backend
MIN_INSTANCE        = 2
; maximum instances into backend
MAX_INSTANCE        = 30

; rate value threshold to schedule scale up process
RATE_UP_LIMIT       = 20
; rate value threshold to schedule scale down process
RATE_DOWN_LIMIT     = 10
; instance minimum count to schedule scale process
INSTANCE_RATIO      = 0.5
; number of instance to spawn on scale up
INSTANCE_SPAWN      = 5

; time to wait between 2 scale operations (up or down)
SCALE_DELAY         = 60
; time to wait between load balancer update and instance deletion
; should be enough to let clients end their connections
DESTROY_DELAY       = 120
```

Haproxy configuration file template is embeded into perl file. 


## Usage

Standard, log to current terminal and syslog :
```
sudo perl loadscale.pl --config loadscale.ini --verbose
```

Daemonize, log to syslog :
```
sudo perl loadscale.pl --config /etc/loadscale/loadscale.ini --daemonize --pid /var/run/loadscale.pid
```


