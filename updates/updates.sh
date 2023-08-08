#!/bin/bash

# Update the system
apt-get update -y
apt-get upgrade -y

#Update the LXC containers
/usr/bin/lxc-ls --fancy | awk '{print $1}' | grep -v NAME | xargs -I {} /usr/bin/lxc-attach -n {} -- /usr/bin/apt-get update -y >> /var/log/lxc-updates.log
/usr/bin/lxc-ls --fancy | awk '{print $1}' | grep -v NAME | xargs -I {} /usr/bin/lxc-attach -n {} -- /usr/bin/apt-get upgrade -y >> /var/log/lxc-updates.log