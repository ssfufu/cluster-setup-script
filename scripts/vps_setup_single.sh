#!/bin/bash
source scripts/nginx_ct_setup.sh
source scripts/nginx_setup.sh
source scripts/wireguard_setup.sh
source scripts/lxc_lxd_setup.sh
source scripts/docker_setup.sh
source scripts/backup_server.sh
function vps_setup_single () {
    # create a new user and add it to the sudo group
    adduser devops
    usermod -aG sudo devops
    
    read -p "What is your domain(s) ? " domain_user
    touch /root/domain.txt
    echo $domain_user > /root/domain.txt

    read -p "What is your e-mail? " mail_user
    touch /root/mail.txt
    echo $mail_user > /root/mail.txt
    local IP_server=$(curl -s ifconfig.me)

    read -p "What IP(S) do you want to allow? (Separated by a space) " allowed_ips
    touch /root/allowed_ips.txt
    echo $allowed_ips > /root/allowed_ips.txt
    apt-get install sshpass -y
    apt-get install jq -y
    apt-get install lxc snapd -y > /dev/null
    sleep 2
    export PATH=$PATH:/snap/bin
    sleep 1
    snap install core > /dev/null
    sleep 2
    nginx_setup
    read -p "Do you want to install a VPN ? " vpn_choice
    if [ "$vpn_choice" == "y" ]; then
	    echo ""
	    echo ""
	    echo "--------------------INSTALLING WIREGUARD SERVER--------------------"
	    wireguard_setup
	    echo ""
	    echo ""
	    echo "--------------------WIREGUARD SERVER INSTALLED--------------------"
    fi

    lxc_lxd_setup
    docker_setup

    echo ""
    echo ""
    echo "--------------------INSTALLING CADVISOR--------------------"

    docker compose -f /root/cluster-setup-script/docker_compose_files/docker-compose-watchover.yml up -d
    cadvisor_latest_version=$(curl -s "https://gcr.io/v2/cadvisor/cadvisor/tags/list" | jq -r '.tags[]' | sort -V | tail -n 1)
    cadvisor_version_full="gcr.io/cadvisor/cadvisor:${cadvisor_latest_version}"
    sed -i "s|image:.*|image: ${cadvisor_version_full}|" /root/cluster-setup-script/docker_compose_files/cadvisor/docker-compose.yml
    docker compose -f /root/cluster-setup-script/docker_compose_files/cadvisor/docker-compose.yml up -d
    nginx_ct_setup "127.0.0.1" "8899" "cadvisor" "/root/allowed_ips.txt"

    docker compose -f /root/cluster-setup-script/docker_compose_files/node-exporter/docker-compose.yml up -d
    touch /etc/cron.d/cadvisor_version_updater
    echo "0 4 * 0 * root /root/cluster-setup-script/cadvisor_version_updater.sh" > /etc/cron.d/cadvisor_version_updater
    chmod 600 /etc/cron.d/cadvisor_version_updater

    echo ""
    echo ""
    echo "--------------------CADVISOR INSTALLED--------------------"

    echo ""
    echo ""
    echo "--------------------SETTING UP SSH--------------------"
    systemctl restart nginx.service
    local IP_user=$(cat /root/allowed_ips.txt)
    rm /etc/ssh/sshd_config
    cp /root/cluster-setup-script/ssh/sshd_config_template /etc/ssh/sshd_config
    touch /etc/hosts.allow
    local wgip=$(cat /root/wgip | awk -F'.' '{print $1"."$2"."$3"."}' )
    if [ "$vpn_choice" == "y" ]; then
        local wgip_server=$(ip a show wg0 | grep inet | awk '{print $2}' | cut -d'/' -f1)
        echo "sshd: ${wgip}" > /etc/hosts.allow
    fi
    for ip in $IP_user; do
        echo "sshd: $ip" >> /etc/hosts.allow
    done
    touch /etc/hosts.deny
    echo "sshd: ALL" > /etc/hosts.deny
    systemctl restart sshd.service
    echo ""
    echo -e "\e[31mWarning: you will ABSOLUTELY have to be connected to the VPN (if existing) to ssh to this server OR connect from those IPs: ${IP_user} \e[0m"
    if [ "$vpn_choice" == "y" ]; then
        echo -e "\e[33mThe command to ssh to this server is now ssh -p 6845 devops@${wgip_server} or ssh -p 6845 devops@${IP_server}\e[0m"
    else
        echo -e "\e[33mThe command to ssh to this server is now ssh -p 6845 devops@${IP_server}\e[0m"
    fi

    echo ""
    echo "--------------------BACKUP SETUP--------------------"
    backup_server

    echo ""
    echo "--------------------AUTOMATIC UPDATES--------------------"
    cp /root/cluster-setup-script/updates/updates.sh /root/updates.sh
    chmod +x /root/updates.sh
    touch /etc/cron.d/auto_updates
    echo "0 3 * * * root /root/updates.sh" > /etc/cron.d/auto_updates
    chmod 600 /etc/cron.d/auto_updates

    echo ""
    echo ""
    echo -e "-------------SETUP DONE-------------\n"
    echo "You now have a ready to use VPN (execute /root/wireguard_script/wireguard-install.sh for creating, removing clients.)"
    echo "And also a cadvisor web pannel at https://cadvisor.$domain_user"

    echo ""

}