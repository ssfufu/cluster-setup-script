#!/bin/bash
function wireguard_setup () {
    echo "--------------------INSTALLING WIREGUARD--------------------"

    # detects if IPV6 is disabled and enables it
    if ! grep -q "net.ipv6.conf.all.disable_ipv6 = 0" /etc/sysctl.conf; then
        echo "net.ipv6.conf.all.disable_ipv6 = 0" >> /etc/sysctl.conf
        echo "net.ipv6.conf.default.disable_ipv6 = 0" >> /etc/sysctl.conf
        echo "net.ipv6.conf.lo.disable_ipv6 = 0" >> /etc/sysctl.conf
        sysctl -p
    fi

    cd /root/
    mkdir wireguard_script && cd wireguard_script
    curl -O https://raw.githubusercontent.com/angristan/wireguard-install/master/wireguard-install.sh
    chmod +x wireguard-install.sh
    echo ""
    echo ""
    echo -e "\e[31--------------------------------------------------------------------------------------------\e[0m"
    echo -e "\e[31mWarning: Just press enter, to get the default config. This is important for the SSH config.\e[0m"
    echo -e "\e[31--------------------------------------------------------------------------------------------\e[0m"
    echo ""
    echo ""
    sleep 5
    ./wireguard-install.sh
    systemctl restart wg-quick@wg0.service

    echo ""
    echo ""
    echo "--------------------WIREGUARD ISNTALLED--------------------"
}