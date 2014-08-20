#!/bin/sh

mkdir /etc/loadscale
cp loadscale.conf /etc/init/

cd ../..
aptitude install haproxy
echo "ENABLED=1" > /etc/default/haproxy
update-rc.d haproxy defaults
service haproxy start

aptitude install cpanminus build-essential libssl-dev
cpanm -n Dist::Zilla
dzil listdeps --missing| cpanm -n
dzil install

cp loadscale.ini /etc/loadscale/

echo "Please edit /etc/loadscale/loadscale.ini"
echo "Then run : start loadscale"

cd -
