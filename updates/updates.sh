#!/bin/bash

# Update the system
apt-get update -y
apt-get upgrade -y

#Update the LXC containers
lxc-ls --fancy | awk '{print $1}' | grep -v NAME | xargs -n1 lxc-attach -n -- apt-get update -y
lxc-ls --fancy | awk '{print $1}' | grep -v NAME | xargs -n1 lxc-attach -n -- apt-get upgrade -y