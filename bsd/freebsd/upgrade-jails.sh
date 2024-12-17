#!/bin/sh

# https://alfaexploit.com/en/posts/managing_jails_in_freebsd_with_bastille/#update

for JAIL_PATH in /usr/local/bastille/jails/*; do JAIL=$(basename $JAIL_PATH) && echo -n "-- $JAIL: " && grep osrelease $JAIL_PATH/jail.conf >/dev/null 2>/dev/null ; if [ $? -eq 0 ]; then echo "Thin jail" ; else echo "Thick jail"; fi ; done

yes | sudo bastille pkg $1 update -f
sudo bastille pkg $1 upgrade -y

# sudo bastille bootstrap 14.0-RELEASE update
# sudo bastille list release

# sudo bastille update $1
sudo bastille upgrade $1 14.0-RELEASE
sudo bastille upgrade $1 install

sudo bastille stop $1
sudo bastille start $1

sudo bastille upgrade $1 install

yes | sudo bastille pkg $1 update -f
sudo bastille pkg $1 upgrade -y
