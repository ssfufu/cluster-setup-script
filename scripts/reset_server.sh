#!/bin/bash
function reset_server () {
    echo -e "\e[31mWARNING: This will delete all containers, networks, nginx config files, environment files and wireguard\e[0m"
    echo -e "\e[31m         It will also stop and remove all docker containers, images, volumes and networks\e[0m"
    echo -e "\e[31m         Make sure to backup your system\e[0m"
    echo ""
    
    echo -e "\e[31m         Are you sure you want to continue? (y/n)\e[0m"
    read -p "" choice

    if [ "$choice" != "y" ]; then
        echo "Aborting..."
        exit 1
    fi

    echo "Resetting server..."

    echo "Deleting containers..."
    for i in monitoring tolgee owncloud nextcloud react cube; do
        if [ -d "/var/lib/lxc/$i" ]; then
            echo "Deleting container $i"
            lxc-stop -n $i
            lxc-destroy -n $i
        fi
    done

    echo "Deleting networks..."
    lxc network delete DMZ
    lxc network delete DMZ2

    echo "Deleting lxd and lxc..."
    apt-get remove -y lxc
    snap remove lxd

    echo "Deleting nginx config files..."
    rm /etc/nginx/sites-available/cadvisor /etc/nginx/sites-enabled/cadvisor > /dev/null
    rm /etc/nginx/sites-available/monitoring /etc/nginx/sites-enabled/monitoring > /dev/null
    rm /etc/nginx/sites-available/tolgee /etc/nginx/sites-enabled/tolgee > /dev/null
    rm /etc/nginx/sites-available/appsmith /etc/nginx/sites-enabled/appsmith > /dev/null
    rm /etc/nginx/sites-available/n8n /etc/nginx/sites-enabled/n8n > /dev/null
    rm /etc/nginx/sites-available/owncloud /etc/nginx/sites-enabled/owncloud > /dev/null
    rm /etc/nginx/sites-available/nextcloud /etc/nginx/sites-enabled/nextcloud > /dev/null
    rm /etc/nginx/sites-available/react /etc/nginx/sites-enabled/react > /dev/null
    rm /etc/nginx/sites-available/cube /etc/nginx/sites-enabled/cube > /dev/null

    echo "Deleting environment files..."
    rm /root/domain.txt
    rm /root/mail.txt

    echo "Deleting wireguard..."
    systemctl stop wgquick@wg0.service
    systemctl disable wgquick@wg0.service
    apt-get remove -y wireguard wireguard-tools qrencode
    rm -rf /etc/wireguard
    rm -f /etc/sysctl.d/wg.conf
    sysctl --system

    echo "Deleting call docker containers..."
    docker stop $(docker ps -a -q)
    docker rm $(docker ps -a -q)
    rm -rf /home/devops/appsmith
    rm -rf /home/devops/n8n
    rm /root/nginx-prometheus-exporter_0.11.0_linux_amd64.tar.gz
    rm /root/CHANGELOG.md /root/LICENSE /root/README.md /root/wg0* /root/wireguard-install.sh /root/cluster-setup-script /root/allowed_ips.txt /root/updates.sh

    #removes the lines that contains IPs in /etc/hosts.allow that match the IPs in the allowed_ips.txt
    echo "Deleting IPs from /etc/hosts.allow..."
    while read -r line; do
        sed -i "/$line/d" /etc/hosts.allow
    done < /root/allowed_ips.txt
    echo "Removing the deny all line from /etc/hosts.deny..."
    if grep -q "deny all" /etc/hosts.deny; then
        sed -i "/deny all/d" /etc/hosts.deny
    fi

    echo "Deleting docker images..."
    docker rmi $(docker images -a -q)

    # remove the cronjob in the cron -e and script of the backup
    echo "Deleting backup script and cronjob..."
    rm /etc/cron.d/backup*
    rm /root/backup*.sh


    echo "Reset done"
    echo "You can now run the script again to setup the server"
    exit 0

}