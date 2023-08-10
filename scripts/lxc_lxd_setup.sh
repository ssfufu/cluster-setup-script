#!/bin/bash
function lxc_lxd_setup () {
    echo ""
    echo ""
    echo "--------------------LXC/LXD INSTALLATION--------------------"
    snap install lxd > /dev/null
    sleep 2

    cp /root/cluster-setup-script/lxd/lxd_net.service /etc/systemd/system/lxd_net.service
    systemctl daemon-reload
    systemctl enable lxd_net.service

    adduser devops lxd
    lxd init --preseed - < /root/cluster-setup-script/lxd/lxd_init.yaml

    lxc network create DMZ ipv4.address=10.128.151.1/24 ipv4.nat=true ipv4.dhcp=false
    lxc network create DMZ2 ipv4.address=10.128.152.1/24 ipv4.nat=true ipv4.dhcp=false

    echo "lxc.start.auto = 1" >> /etc/lxc/default.conf
    echo "lxc.start.delay = 5" >> /etc/lxc/default.conf
    cp /root/cluster-setup-script/lxd/lxc-containers.service /etc/systemd/system/lxc-containers.service
    systemctl daemon-reload
    systemctl enable lxc-containers.service

    echo ""
    echo ""
    echo "--------------------LXC INSTALLED--------------------"    
}