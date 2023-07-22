#!/bin/bash
# checks if the script is launched as root or not
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

# checks if the ipcalc package is installed or not
if ! dpkg -l | grep -w "ipcalc" >/dev/null; then
    echo "ipcalc package is not installed... installing it"
    apt-get install ipcalc -y >/dev/null
    sleep 2
    echo "ipcalc package installed successfully"
fi

function backup_server () {
    echo "--------------------BACKUP SERVER--------------------" | tee -a $logfile

    read -p "Do you want to implement a backup function to the server? (y/n): " backup_server
    if [ "$backup_server" = "n" ]; then
        echo "Skipping backup server" | tee -a $logfile
        return
    fi

    read -p "Enter the remote server's IP address: " remote_ip
    read -p "Enter the remote server's username: " remote_username
    read -s -p "Enter the remote server's password: " remote_password
    read -p "Enter the remote server's ssh port: " remote_port
    read -p "Enter the remote server's backup directory: " remote_dir
    read -p "Enter the remote server's backup name: " remote_name
    read -p "Enter the remote server's backup extension: " remote_ext
    read -p "Enter the remote server's backup frequency (in hours): " remote_freq
    read -p "Enter the remote server's backup retention (in days): " remote_retention
    read -p "Enter the remote server's backup compression (y/n): " remote_compression
    read -p "Do you also want to transfer the backups to an FTP server? (y/n): " ftp_transfer

    logfile="/var/log/backup_${remote_name}.log"
    error_logfile="/var/log/backup_${remote_name}_error.log"

    if [ "$ftp_transfer" = "y" ]; then
        read -p "Enter the FTP server's IP address: " ftp_ip
        read -p "Enter the FTP server's username: " ftp_username
        read -p "Enter the FTP server's password: " ftp_password
        read -p "Enter the FTP server's backup directory: " ftp_dir
    fi

    if [ $USER = "root" ]; then
        home_dir="/root"
    else
        home_dir="/home/${USER}"
    fi

    ssh-keygen -t rsa -b 4096 -f "${home_dir}/.ssh/${remote_name}_rsa" -N "" |& tee -a $logfile
    echo "SSH key pair generated: ${home_dir}/.ssh/${remote_name}_rsa" | tee -a $logfile

    echo "Trying to copy the public key to the remote server..." | tee -a $logfile
    sshpass -p "$remote_password" ssh-copy-id -p "${remote_port}" -i "${home_dir}/.ssh/${remote_name}_rsa.pub" "${remote_username}@${remote_ip}" |& tee -a $logfile

    backup_script="${home_dir}/backup_${remote_name}.sh"
    touch $backup_script && chmod +x $backup_script
    touch $logfile
    touch $error_logfile

    echo "#!/bin/bash" > $backup_script
    echo "current_time=\$(date +\"%d.%m.%Y_%H:%M\")" >> "$backup_script"
    echo "echo \"\${current_time}: Starting backup\" >> $logfile" >> "$backup_script"

    # Stop all running Docker and LXC containers
    echo "docker stop \$(docker ps -q)" >> "$backup_script"
    echo "for container in \$(lxc-ls); do lxc-stop -n \"\$container\"; done" >> "$backup_script"

    echo "dirs_to_backup=(\"/etc\" \"/var/lib/lxc\" \"/home/devops\")" >> "$backup_script"
    echo "current_date=\$(date +%Y%m%d_%H%M)" >> "$backup_script"
    echo "tarball_name=\"${remote_name}_\${current_date}.tar.gz\"" >> "$backup_script"
    echo "tar -czf \"\${tarball_name}\" \"\${dirs_to_backup[@]}\" 2>> $error_logfile" >> "$backup_script"
    echo "rsync -avz -e \"ssh -i ${home_dir}/.ssh/${remote_name}_rsa -p $remote_port\" \"\${tarball_name}\" \"${remote_username}@${remote_ip}:${remote_dir}/\" 2>> $error_logfile" >> "$backup_script"

    if [ "$ftp_transfer" = "y" ]; then
        echo "curl -T \"\${tarball_name}\" -u ${ftp_username}:${ftp_password} ftp://${ftp_ip}/${ftp_dir}/ 2>> $error_logfile" >> "$backup_script"
    fi

    # Delete any backup files on the remote server that are more than 2 days old
    echo "find \"${remote_dir}\" -name \"${remote_name}_*.tar.gz\" -type f -mtime +${remote_retention} -delete 2>> $error_logfile" >> "$backup_script"

    # Start all Docker and LXC containers again
    echo "docker start \$(docker ps -a -q)" >> "$backup_script"
    echo "for container in \$(lxc-ls); do lxc-start -n \"\$container\"; done" >> "$backup_script"

    echo "Backup script generated: $backup_script" | tee -a $logfile

    echo "0 */${remote_freq} * * * root ${backup_script}" > "/etc/cron.d/backup_${remote_name}.sh"
    chmod 600 "/etc/cron.d/backup_${remote_name}.sh"
    echo "" >> /etc/cron.d/backup_${remote_name}.sh

    echo "Cron job added to run the backup script every ${remote_freq} hours" | tee -a $logfile
}

function docker_setup () {
    echo ""
    echo ""
    echo "--------------------INSTALLING DOCKER--------------------"
    echo ""
    echo ""

    for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do apt-get remove $pkg; done > /dev/null

    apt-get update -y > /dev/null
    sleep 3
    apt-get install ca-certificates curl gnupg -y > /dev/null

    install -m 0755 -d /etc/apt-get/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt-get/keyrings/docker.gpg
    chmod a+r /etc/apt-get/keyrings/docker.gpg

    echo \
        "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt-get/keyrings/docker.gpg] https://download.docker.com/linux/debian \
        "$(. /etc/os-release && echo "$VERSION_CODENAME")" stable" | \
        tee /etc/apt-get/sources.list.d/docker.list > /dev/null

    apt-get update -y > /dev/null
    apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin debootstrap bridge-utils -y > /dev/null

    groupadd docker
    usermod -aG docker devops

    systemctl enable docker.service > /dev/null
    systemctl enable containerd.service > /dev/null

    systemctl restart docker.socket > /dev/null
    systemctl restart docker.service > /dev/null


    echo ""
    echo ""
    echo "--------------------DOCKER INSTALLED--------------------"
}

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
    echo -e "\e[31mWarning: Just press enter, to get the default config. This is important for the SSH config.\e[0m"
    echo ""
    sleep 5
    ./wireguard-install.sh
    systemctl restart wg-quick@wg0.service

    echo ""
    echo ""
    echo "--------------------WIREGUARD ISNTALLED--------------------"
}

function lxc_lxd_setup () {
    echo ""
    echo ""
    echo "--------------------LXC/LXD INSTALLATION--------------------"
    apt-get install lxc snapd -y > /dev/null
    sleep 2
    snap install core > /dev/null
    sleep 2
    snap install lxd > /dev/null
    sleep 2

    cp /root/cluster-setup-script/lxd/lxd_net.service /etc/systemd/system/lxd_net.service
    systemctl daemon-reload
    systemctl enable lxd_net.service

    adduser devops lxd
    lxd init --preseed - < /root/cluster-setup-script/lxd/lxd_init.yaml

    lxc network create DMZ ipv4.address=10.128.151.1/24 ipv4.nat=true ipv4.dhcp=false
    lxc network create DMZ2 ipv4.address=10.128.152.1/24 ipv4.nat=true ipv4.dhcp=false

    echo ""
    echo ""
    echo "--------------------LXC INSTALLED--------------------"    
}

function nginx_ct_setup() {
    # Get parameters
    local CT_IP="$1"
    local CT_PORT="$2"
    local CT_NAME="$3"
    local ALLOWED_IPS="$4"
    local DOMAIN="$(cat /root/domain.txt)"
    local MAIL="$(cat /root/mail.txt)"

    # Get the server's IP address and the VPN's IP range and add it to the allowed IPs
    local SERVER_IP=$(curl -s ifconfig.me)
    ALLOWED_IPS="$ALLOWED_IPS $SERVER_IP 10.66.66.0/24"

    # construct server_name and proxy_pass
    local SERVER_NAME="${CT_NAME}.${DOMAIN}"
    local PROXY_PASS="http://${CT_IP}:${CT_PORT}"
    local PROXY_REDIRECT="http://${CT_IP}:${CT_PORT} https://${SERVER_NAME}"
    local dir_path="/etc/letsencrypt/live/${SERVER_NAME}"

    # deletes the file if already exists
    rm /etc/nginx/sites-available/$CT_NAME /etc/nginx/sites-enabled/$CT_NAME > /dev/null

    # create a directory for this site if it doesn't exist
    touch /etc/nginx/sites-available/${CT_NAME} > /dev/null

    # substitute placeholders with variable values in the template and create a new config file
    sed -e "s#server_name#server_name ${SERVER_NAME};#g" \
        -e "s#proxy_set_header Host#proxy_set_header Host ${SERVER_NAME};#g" \
        -e "s#proxy_pass#proxy_pass ${PROXY_PASS};#g" \
        -e "s#proxy_redirect#proxy_redirect ${PROXY_REDIRECT};#g" \
        -e "s#/etc/letsencrypt/live//#/etc/letsencrypt/live/${SERVER_NAME}/#g" \
        -e "s#if (\$host = )#if (\$host = ${SERVER_NAME})#g" \
        -e "/location \/ {/a deny all;" /root/cluster-setup-script/nginx/nginx-config > "/etc/nginx/sites-available/${CT_NAME}"
    
    # Add the allowed IPs
    #if the ct nameis n8n, allow all ips
    if [ "$CT_NAME" = "monitoring" ] || [ "$CT_NAME" = "tolgee" ] || [ "$CT_NAME" = "nextcloud" ] || [ "$CT_NAME" = "owncloud" ] || [ "$CT_NAME" = "react" ]; then
        echo "Allowing all IPs"
        sed -i "s/deny all/allow all/g" "/etc/nginx/sites-available/${CT_NAME}"
    else 
        echo "Allowing only the specified IPs"
        for ip in $ALLOWED_IPS; do
            sed -i "/deny all;/i allow $ip;" "/etc/nginx/sites-available/${CT_NAME}"
        done
    fi


    # create a symlink to the sites-enabled directory
    ln -s /etc/nginx/sites-available/${CT_NAME} /etc/nginx/sites-enabled/ > /dev/null

    if [ -d "$dir_path" ]; then
        echo "There already is a certificate for that."
    else
        systemctl stop nginx

        certbot certonly --standalone -d ${SERVER_NAME} --email ${MAIL} --agree-tos --no-eff-email --noninteractive --force-renewal
        
        systemctl start nginx
    fi

    systemctl restart nginx.service

}

function nginx_setup() {
    echo ""
    echo ""
    echo "--------------------NGINX INSTALLATION--------------------"
    apt-get install nginx -y > /dev/null
    sleep 1
    systemctl enable nginx && systemctl start nginx
    snap install --classic certbot > /dev/null
    sleep 1
    ln -s /snap/bin/certbot /usr/bin/certbot
    ip_self=$(ip addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    local IP_nginx=$(cat /root/allowed_ips.txt)
    
    rm /etc/nginx/nginx.conf
    cp /root/cluster-setup-script/nginx/nginx.conf /etc/nginx/nginx.conf
    sed -i "/allow 127.0.0.1;/a \\\n\
                    allow $ip_self;" /etc/nginx/nginx.conf
    sed -i "/allow $ip_self;/a \\\n\
                    allow $IP_nginx;" /etc/nginx/nginx.conf
    sed -i "/allow $IP_nginx;/a \\\n\
                    allow 10.128.151.0/24;" /etc/nginx/nginx.conf
    sed -i "/allow 10.128.151.0/24;/a \\\n\
                    allow 10.128.152.0/24;" /etc/nginx/nginx.conf

    
    rm /etc/nginx/sites-available/default
    rm /etc/nginx/sites-enabled/default
    cp /root/cluster-setup-script/nginx/default_conf /etc/nginx/sites-available/default
    ln -s /etc/nginx/sites-available/default /etc/nginx/sites-enabled/

    rm /etc/letsencrypt/options-ssl-nginx.conf > /dev/null
    mkdir -p /etc/letsencrypt/
    cp /root/cluster-setup-script/nginx/options-ssl-nginx.conf /etc/letsencrypt/options-ssl-nginx.conf
    openssl dhparam -out /etc/letsencrypt/ssl-dhparams.pem 2048
    chmod 644 /etc/letsencrypt/ssl-dhparams.pem
    
    echo ""
    echo ""
    echo "Installing nginx-prometheus-exporter"
    echo "Downloading nginx-prometheus-exporter"
    curl -L https://github.com/nginxinc/nginx-prometheus-exporter/releases/download/v0.11.0/nginx-prometheus-exporter_0.11.0_linux_amd64.tar.gz -o /root/nginx-prometheus-exporter_0.11.0_linux_amd64.tar.gz
    echo "Extracting nginx-prometheus-exporter"
    tar -xzf /root/nginx-prometheus-exporter_0.11.0_linux_amd64.tar.gz -C /root/
    echo "chmod and moving nginx-prometheus-exporter to /usr/local/bin"
    chmod +x /root/nginx-prometheus-exporter
    mv /root/nginx-prometheus-exporter /usr/local/bin/nginx-prometheus-exporter

    echo ""
    echo ""
    echo "Creating nginx-prometheus-exporter.service"
    cp /root/cluster-setup-script/prometheus/nginx-prometheus-exporter.service /etc/systemd/system/nginx-prometheus-exporter.service
    systemctl daemon-reload
    systemctl enable nginx-prometheus-exporter.service
    systemctl start nginx-prometheus-exporter.service

    systemctl restart nginx.service

    echo ""
    echo ""
    echo "--------------------NGINX INSTALLED--------------------"
}

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
    apt install sshpass -y

    nginx_setup
    lxc_lxd_setup
    docker_setup

    echo ""
    echo ""
    echo "--------------------INSTALLING CADVISOR--------------------"

    docker run --restart=unless-stopped --volume=/:/rootfs:ro --volume=/var/run:/var/run:ro --volume=/sys:/sys:ro --volume=/var/lib/docker/:/var/lib/docker:ro --volume=/var/lib/lxc/:/var/lib/lxc:ro --publish=127.0.0.1:8899:8080 --detach=true --name=cadvisor gcr.io/cadvisor/cadvisor:v0.47.2
    nginx_ct_setup "127.0.0.1" "8899" "cadvisor" $allowed_ips
    docker run --restart=unless-stopped -d -p 127.0.0.1:9111:9100 --net="host" --pid="host" -v "/:/host:ro,rslave" quay.io/prometheus/node-exporter --name=node-exporter

    echo ""
    echo ""
    echo "--------------------CADVISOR INSTALLED--------------------"

    echo ""
    echo ""
    echo "--------------------INSTALLING WIREGUARD SERVER--------------------"
    wireguard_setup
    echo ""
    echo ""
    echo "--------------------WIREGUARD SERVER INSTALLED--------------------"

    echo ""
    echo ""
    echo "--------------------SETTING UP SSH--------------------"
    systemctl restart nginx.service
    local IP_user=$allowed_ips
    rm /etc/ssh/sshd_config
    cp /root/cluster-setup-script/ssh/sshd_config_template /etc/ssh/sshd_config
    touch /etc/hosts.allow
    echo "sshd: 10.66.66." > /etc/hosts.allow
    echo "sshd: ${IP_user}" >> /etc/hosts.allow
    touch /etc/hosts.deny
    echo "sshd: ALL" > /etc/hosts.deny
    systemctl restart sshd.service
    echo ""
    echo -e "\e[31mWarning: you will ABSOLUTELY have to be connected to the VPN to ssh to this server OR connect from ${IP_user} \e[0m"
    echo -e "\e[33mThe command to ssh to this server is now ssh -p 6845 devops@10.66.66.1 or ssh -p 6845 devops@${IP_server}\e[0m"


    echo ""
    echo "--------------------BACKUP SETUP--------------------"
    backup_server


    echo ""
    echo ""
    echo -e "-------------SETUP DONE-------------\n"
    echo "You now have a ready to use VPN (execute /root/wireguard_script/wireguard-install.sh for creating, removing clients.)"
    echo "And also a cadvisor web pannel at cadvisor.$domain_user"

    echo ""

}

function update_install_packages () {
    container_name=$1
    shift
    packages=("$@")

    lxc-attach $container_name -- bash -c "apt-get update -y && apt-get install nano wget software-properties-common ca-certificates curl gnupg git -y"
    sleep 20
    for i in "${packages[@]}"; do
        lxc-attach $container_name -- apt-get install $i -y
    done

}

function check_docker_container_exists() {
    local dcname="$1"
    if [ "$(docker ps -a -q -f name=^/${dcname}$)" ]; then
        return 0
    else
        return 1
    fi
}

function user_ct_setup () {

    local container_name="$1"
    local dom="$(cat /root/domain.txt)"

    echo ""
    echo ""
    echo "------------------------------------------------------------"
    read -p "Have you created a user at the site? (y/n) " user_created
    echo "------------------------------------------------------------"
    echo ""
    if [ "$user_created" == "n" ]; then
        echo "You can create a user at the site by going to https://${container_name}.$dom"
    else
        sed -i 's/deny all/allow all/g' /etc/nginx/sites-available/${container_name}
        rm /etc/nginx/sites-enabled/${container_name}
        ln -s /etc/nginx/sites-available/${container_name} /etc/nginx/sites-enabled/
        systemctl restart nginx.service
        sleep 2
    fi
}

function create_container () {
    packages=("nano" "wget" "software-properties-common" "ca-certificates" "curl" "gnupg" "git")
    docker_cts=("n8n" "appsmith")
    lxc_cts=("monitoring" "tolgee" "owncloud" "nextcloud" "react" "cube")
    echo "The following containers are available:"
    echo "Docker containers: ${docker_cts[*]}"
    echo "LXC containers: ${lxc_cts[*]}"
    echo ""

    read -p "Enter the container name: " container_name
    if [ -z "$container_name" ]; then
        echo "You must enter a container name"
        exit 1
    fi
    if ! echo "monitoring tolgee appsmith n8n owncloud nextcloud react cube" | grep -w "$container_name" >/dev/null; then
        echo "Container name not in the list"
        exit 1
    fi
    dom="$(cat /root/domain.txt)"
    srv_name="${container_name}.${dom}"
    if [ -d "/var/lib/lxc/${container_name}" ]; then
        echo "Container named $container_name already exists"
        exit 1
    else
        if echo "monitoring tolgee owncloud nextcloud react cube" | grep -w "$container_name" >/dev/null; then
            local allowed_ips=$(cat /root/allowed_ips.txt)
            # asks the user for the network interface the container will use, list the interfaces to choose from
            echo -e "\nThe following interfaces are available:"
            ip a | grep -E "^[0-9]" | awk '{print $2}' | sed 's/://g' | grep -E "^DMZ" | sed 's/^/ - /g'
            echo ""
            read -p "Enter the interface the container will use: " interface

            # store the gateway IP address of the interface
            gateway=$(ip r | grep -w "$interface" | awk '{print $9}')

            if [ -z "$interface" ]; then
                echo "You must enter an interface"
                exit 1
            fi

            if ! ip a | grep -E "^[0-9]" | awk '{print $2}' | sed 's/://g' | grep -w "$interface" >/dev/null; then
                echo "Interface $interface does not exist"
                exit 1
            fi

            range_start=2
            range_end=254
            # Get the subnet
            subnet=$(echo "$gateway" | cut -d"." -f1-3)

            # Loop through the IP addresses
            for i in $(seq $range_start $range_end); do
                IP="$subnet.$i"
                # Check if the IP address is in use
                if ! ping -c 1 -W 1 "$IP" > /dev/null 2>&1; then
                    echo "Found available IP address: $IP"
                    break
                fi
            done

            # Check if we found an IP address
            if [ -z "$IP" ]; then
                echo "No available IP addresses found in the range $subnet.$range_start to $subnet.$range_end"
                exit 1
            fi

            echo ""
            echo "--------------------CREATING CONTAINER--------------------"
            # creates a file at /var/lib/lxc/<container_name>/rootfs/etc/systemd/network/10-eth0.network
            touch /tmp/10-eth0.network
            net_file="/tmp/10-eth0.network"

            echo "Creating network file..."
            echo "[Match]" >> $net_file
            echo "Name=eth0" >> $net_file
            echo "" >> $net_file
            echo "[Network]" >> $net_file
            echo "Address=$IP/24" >> $net_file
            echo "Gateway=$gateway" >> $net_file
            echo "DNS=8.8.8.8" >> $net_file

            lxc-create -t download -n $container_name -- -d debian -r bullseye -a amd64 > /dev/null
            sleep 5
            echo "--------------------CONTAINER CREATED--------------------"
            echo ""
            echo "--------------------STARTING CONTAINER--------------------"
            # updates the container's config file
            echo "Updating container's config file"
            sed -i "s/lxc.net.0.link = lxcbr0/lxc.net.0.link = $interface/g" /var/lib/lxc/$container_name/config
            echo "lxc.net.0.ipv4.address = $IP/24" >> /var/lib/lxc/$container_name/config
            echo "lxc.net.0.ipv4.gateway = $gateway" >> /var/lib/lxc/$container_name/config

            #take the /var/lib/lxc/<container_name>/rootfs/etc/systemd/resolved.conf file and add the DNS=
            echo "Adding DNS to the container's resolved.conf file"

            # checks if DNS= is commented or not
            if grep -q "#DNS=" /var/lib/lxc/$container_name/rootfs/etc/systemd/resolved.conf; then
                sed -i "s/#DNS=/DNS=8.8.8.8/g" /var/lib/lxc/$container_name/rootfs/etc/systemd/resolved.conf
            else
                echo "DNS=8.8.8.8" >> /var/lib/lxc/$container_name/rootfs/etc/systemd/resolved.conf
            fi

            #same for dnsfallback=
            if grep -q "#FallbackDNS=" /var/lib/lxc/$container_name/rootfs/etc/systemd/resolved.conf; then
                sed -i "s/#FallbackDNS=/FallbackDNS=8.8.4.4/g" /var/lib/lxc/$container_name/rootfs/etc/systemd/resolved.conf
            else
                echo "FallbackDNS=8.8.4.4" >> /var/lib/lxc/$container_name/rootfs/etc/systemd/resolved.conf
            fi

            #replaces the container's rootfs with the network file
            echo "Replacing container's rootfs with the network file"
            mv /tmp/10-eth0.network /var/lib/lxc/$container_name/rootfs/etc/systemd/network/10-eth0.network
            echo "lxc.start.auto = 1" >> /var/lib/lxc/$container_name/config
            echo "lxc.start.delay = 5" >> /var/lib/lxc/$container_name/config
            
            lxc-start -n $container_name
            sleep 2
            lxc-attach $container_name -- hostnamectl set-hostname $container_name
            sed -i '/127.0.0.1/c\127.0.0.1 '${container_name} /var/lib/lxc/$container_name/rootfs/etc/hosts
            lxc-attach $container_name -- bash -c "echo $container_name > /etc/hostname"
            lxc-stop -n $container_name
            sleep 5
            lxc-start -n $container_name

            sleep 5

            lxc-attach $container_name -- bash -c "ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf"
            sleep 5
            lxc-attach $container_name -- systemctl restart systemd-networkd
            sleep 5
            lxc-attach $container_name -- systemctl restart systemd-resolved
            sleep 5
            lxc-stop -n $container_name
            lxc-autostart -n $container_name
            sleep 5
            lxc-start -n $container_name

            echo ""
            echo "--------------------CONTAINER STARTED--------------------"

            echo ""
            echo "--------------------SETTING UP THE CONTAINER--------------------"
            case $container_name in
            "monitoring")
                update_install_packages $container_name prometheus
                file_name="/var/lib/lxc/$container_name/rootfs/etc/prometheus/prometheus.yml"
                host_ip=$(ip addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

                # Add the content to the file
                echo "" >> $file_name
                echo "  - job_name: nodexp" >> $file_name
                echo "    static_configs:" >> $file_name
                echo "      - targets: ['$gateway:9111']" >> $file_name

                echo "" >> $file_name
                echo "  - job_name: 'nginx'" >> $file_name
                echo "    static_configs:" >> $file_name
                echo "      - targets: ['$host_ip:8080']" >> $file_name

                echo "" >> $file_name
                echo "  - job_name: 'cadvisor'" >> $file_name
                echo "    static_configs:" >> $file_name
                echo "      - targets: ['$gateway:8899']" >> $file_name

                touch /var/lib/lxc/$container_name/rootfs/root/grafana.sh
                echo "#!/bin/bash" >> /var/lib/lxc/$container_name/rootfs/root/grafana.sh
                echo "wget -q -O /usr/share/keyrings/grafana.key https://apt.grafana.com/gpg.key" >> /var/lib/lxc/$container_name/rootfs/root/grafana.sh
                echo "echo 'deb [signed-by=/usr/share/keyrings/grafana.key] https://apt.grafana.com stable main' | tee -a /etc/apt/sources.list.d/grafana.list" >> /var/lib/lxc/$container_name/rootfs/root/grafana.sh
                echo "apt-get update -y" >> /var/lib/lxc/$container_name/rootfs/root/grafana.sh
                echo "apt-get install grafana -y" >> /var/lib/lxc/$container_name/rootfs/root/grafana.sh
                echo "systemctl daemon-reload" >> /var/lib/lxc/$container_name/rootfs/root/grafana.sh
                echo "systemctl start grafana-server" >> /var/lib/lxc/$container_name/rootfs/root/grafana.sh
                echo "systemctl enable grafana-server.service" >> /var/lib/lxc/$container_name/rootfs/root/grafana.sh

                lxc-attach $container_name -- bash -c "chmod +x /root/grafana.sh"
                lxc-attach $container_name -- bash -c "/root/grafana.sh"

                nginx_ct_setup $IP "3000" $container_name $allowed_ips
                ;;


            "tolgee")
                update_install_packages $container_name openjdk-11-jdk jq postgresql postgresql-contrib
                sleep 10

                echo ""
                echo "--- Setting up PostgreSQL ---"
                read -s -p "Please enter a password for the database (also it will be the initial password for the intial user <tolgee>): " db_password
                echo ""
                
                echo "Creating database..."
                lxc-attach $container_name -- bash -c "su postgres -c \"psql -c 'CREATE DATABASE tolgee;'\""

                echo "Creating user..."
                lxc-attach $container_name -- bash -c "su postgres -c \"psql -c 'CREATE USER tolgee WITH ENCRYPTED PASSWORD '\''${db_password}'\'';'\""

                echo "Granting privileges..."
                lxc-attach $container_name -- bash -c "su postgres -c \"psql -c 'GRANT ALL PRIVILEGES ON DATABASE tolgee TO tolgee;'\""

                lxc-attach $container_name -- bash -c "curl -s https://api.github.com/repos/tolgee/tolgee-platform/releases/latest | jq -r '.assets[] | select(.content_type == \"application/java-archive\") | .browser_download_url' | xargs -I {} curl -L -o /root/latest-release.jar {}"
                sleep 5
                echo -e "spring.datasource.url=jdbc:postgresql://localhost:5432/tolgee\n
                    spring.datasource.username=tolgee\n
                    spring.datasource.password=${db_password}\n
                    server.port=8200\n
                    tolgee.authentication.enabled=true\n
                    tolgee.authentication.create-initial-user=true\n
                    tolgee.authentication.initial-username=tolgee\n
                    tolgee.authentication.initial-password=${db_password}\n" > /var/lib/lxc/${container_name}/rootfs/root/application.properties

                cp /root/cluster-setup-script/tolgee/tolgee.service /var/lib/lxc/${container_name}/rootfs/etc/systemd/system/tolgee.service

                lxc-attach $container_name -- bash -c "pg_ctlcluster 13 main start"
                sleep 2
                lxc-attach $container_name -- bash -c "systemctl daemon-reload"
                sleep 2
                lxc-attach $container_name -- bash -c "systemctl start tolgee && systemctl enable tolgee"
                sleep 5
                nginx_ct_setup $IP "8200" $container_name $allowed_ips
                ;;

            "owncloud")
                update_install_packages $container_name mariadb-server php-fpm php-mysql php-xml php-mbstring php-gd php-curl nginx php7.4-fpm php7.4-mysql php7.4-common php7.4-gd php7.4-json php7.4-curl php7.4-zip php7.4-xml php7.4-mbstring php7.4-bz2 php7.4-intl
                sleep 10
                rm /var/lib/lxc/$container_name/rootfs/etc/nginx/sites-available/default
                cp /root/cluster-setup-script/owncloud-nextcloud/config-owncloud /var/lib/lxc/$container_name/rootfs/etc/nginx/sites-available/default
                sed -i "s/server_name/server_name $IP;/g" /var/lib/lxc/$container_name/rootfs/etc/nginx/sites-available/default

                lxc-attach $container_name -- bash -c "curl https://download.owncloud.org/download/repositories/production/Debian_11/Release.key | apt-get-key add -"
                lxc-attach $container_name -- bash -c "echo 'deb http://download.owncloud.org/download/repositories/production/Debian_11/ /' > /etc/apt-get/sources.list.d/owncloud.list"
                lxc-attach $container_name -- apt-get update -y
                lxc-attach $container_name -- apt-get install -y owncloud-files

                # Configure MariaDB
                echo -n "Please enter a owncloud database password: "
                read -s db_password
                lxc-attach $container_name -- bash -c "mysql -e \"CREATE DATABASE owncloud; GRANT ALL ON owncloud.* to 'owncloud'@'localhost' IDENTIFIED BY '${db_password}'; FLUSH PRIVILEGES;\""

                # Configure PHP
                lxc-attach $container_name -- bash -c "sed -i 's/post_max_size = .*/post_max_size = 2000M/' /etc/php/7.4/fpm/php.ini"
                lxc-attach $container_name -- bash -c "sed -i 's/upload_max_filesize = .*/upload_max_filesize = 2000M/' /etc/php/7.4/fpm/php.ini"
                lxc-attach $container_name -- bash -c "sed -i 's/max_execution_time = .*/max_execution_time = 3600/' /etc/php/7.4/fpm/php.ini"
                lxc-attach $container_name -- bash -c "sed -i 's/memory_limit = .*/memory_limit = 512M/' /etc/php/7.4/fpm/php.ini"
                lxc-attach $container_name -- bash -c "systemctl restart php7.4-fpm"
                lxc-attach $container_name -- bash -c "systemctl restart nginx"
                nginx_ct_setup $IP "80" $container_name $allowed_ips

                ;;
            "nextcloud")
                update_install_packages $container_name apache2 libapache2-mod-php mariadb-client unzip wget php-gd php-json php-mysql php-curl php-mbstring php-intl php-imagick php-xml php-zip
                sleep 10
                lxc-attach $container_name -- bash -c "sudo wget https://packages.sury.org/php/apt.gpg -O /etc/apt/trusted.gpg.d/php.gpg"
                lxc-attach $container_name -- bash -c "echo 'deb https://packages.sury.org/php/ $(lsb_release -sc) main' > /etc/apt/sources.list.d/php.list"
                lxc-attach $container_name -- apt-get update -y
                # install php 8.2
                lxc-attach $container_name -- bash -c "apt-get install php8.2 php8.2-cli php8.2-common php8.2-curl php8.2-mbstring php8.2-mysql php8.2-xml php8.2-zip php8.2-intl php8.2-imagick php8.2-gd -y"
                lxc-attach $container_name -- bash -c "a2enmod php8.2 && a2dismod php7.4"
                lxc-attach $container_name -- bash -c "systemctl restart apache2"
                _domain="$(cat /root/domain.txt)"
                lxc-attach $container_name -- bash -c "wget https://download.nextcloud.com/server/releases/latest.zip && unzip latest.zip -d /var/www/"
                lxc-attach $container_name -- bash -c "chown -R www-data:www-data /var/www/nextcloud/"
                lxc-attach $container_name -- bash -c "chmod -R 755 /var/www/nextcloud/"
                sed -i "s/ServerName.*/ServerName ${container_name}.${_domain}/g" /root/cluster-setup-script/owncloud-nextcloud/nextcloud.conf
                cp /root/cluster-setup-script/owncloud-nextcloud/nextcloud.conf /var/lib/lxc/$container_name/rootfs/etc/apache2/sites-available/nextcloud.conf
                lxc-attach $container_name -- bash -c "a2ensite nextcloud"
                lxc-attach $container_name -- bash -c "a2enmod rewrite headers env dir mime"
                lxc-attach $container_name -- bash -c "a2dissite 000-default"
                echo "ServerName ${container_name}" >> /var/lib/lxc/$container_name/rootfs/etc/apache2/apache2.conf
                lxc-attach $container_name -- bash -c "systemctl restart apache2"

                nginx_ct_setup $IP "80" $container_name $allowed_ips
                systemctl restart nginx.service
                ;;
                
            "react")
                update_install_packages $container_name
                # install nodejs latest version
                lxc-attach $container_name -- bash -c "curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.3/install.sh | bash"
                lxc-attach $container_name -- bash -c 'export NVM_DIR="$HOME/.nvm"'
                lxc-attach $container_name -- bash -c '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"'

                lxc-attach $container_name -- bash -c "nvm install --lts"
                lxc-attach $container_name -- bash -c "nvm use --lts"

                sleep 10
                nginx_ct_setup $IP "3000" $container_name $allowed_ips
                lxc-attach $container_name -- bash -c "npm install -g pm2"
                lxc-attach $container_name -- bash -c "pm2 startup"
                echo "Installing react..."
                read -p "Enter the git repo: " git_repo
                read -p "Is it a private repo? (y/n) " private_repo
                if [ "$private_repo" == "y" ]; then
                    read -p "Enter the git username: " git_username
                    read -p "Enter the personal access token: " git_password
                    git_repo=$(echo $git_repo | sed 's/https:\/\///g')
                    git_repo="https://$git_username:$git_password@$git_repo"
                fi
                repo_name=$(echo $git_repo | sed 's/.*\///g' | sed 's/.git//g')

                lxc-attach $container_name -- bash -c "mkdir /root/react"
                lxc-attach $container_name -- bash -c "cd /root/react && git clone $git_repo"

                lxc-attach $container_name -- bash -c "cd /root/react/${repo_name} && npm install && npm run build"
                # check if the build folder is build or dist and store it in a variable
                if [ -d "/root/react/${repo_name}/build" ]; then
                    build_folder="build"
                elif [ -d "/root/react/${repo_name}/dist" ]; then
                    build_folder="dist"
                else
                    echo "Build folder not found"
                    exit 1
                fi

                lxc-attach $container_name -- bash -c "cd /root/react/${repo_name} && pm2 serve ${build_folder} 3000 --name react"
                lxc-attach $container_name -- bash -c "pm2 save"
                lxc-attach $container_name -- bash -c "pm2 startup"
                lxc-attach $container_name -- bash -c "systemctl restart pm2-root"
                ;;
            "cube")
                update_install_packages $container_name
                # install nodejs latest version
                lxc-attach $container_name -- bash -c "curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.3/install.sh | bash"
                touch /var/lib/lxc/$container_name/rootfs/root/cube_script.sh
                echo -e "curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.3/install.sh | bash\n export NVM_DIR=\"\$HOME/.nvm\"\n[ -s \"\$NVM_DIR/nvm.sh\" ] && \\. \"\$NVM_DIR/nvm.sh\"\nnvm install --lts\nnvm use --lts\nnpm install -g cubejs-cli\nnpm install -g pm2" > /var/lib/lxc/$container_name/rootfs/root/cube_script.sh
                lxc-attach $container_name -- bash -c "chmod +x /root/cube_script.sh"
                lxc-attach $container_name -- bash -c "/root/cube_script.sh"

                lxc-attach $container_name -- bash -c "mkdir /root/cube"
                read -p "Enter the app name: " app_name
                read -p "Enter the database name: " db_name
                read -p "Enter the database username: " db_username
                read -s -p "Enter the database password: " db_password
                echo ""

                lxc-attach $container_name -- bash -c "cd /root/cube && cubejs create ${app_name}"
                sleep 5
                cp /root/cluster-setup-script/cube/.env /var/lib/lxc/$container_name/rootfs/root/cube/${app_name}/.env
                sed -i "s/CUBEJS_DB_NAME=/CUBEJS_DB_NAME=$db_name/g" /var/lib/lxc/$container_name/rootfs/root/cube/${app_name}/.env
                sed -i "s/CUBEJS_DB_USER=/CUBEJS_DB_USER=$db_username/g" /var/lib/lxc/$container_name/rootfs/root/cube/${app_name}/.env
                sed -i "s/CUBEJS_DB_PASS=/CUBEJS_DB_PASS=$db_password/g" /var/lib/lxc/$container_name/rootfs/root/cube/${app_name}/.env
                sed -i "s/CUBEJS_APP=/CUBEJS_APP=$app_name/g" /var/lib/lxc/$container_name/rootfs/root/cube/${app_name}/.env
                echo "NODE_ENV=production" >> /var/lib/lxc/$container_name/rootfs/root/cube/${app_name}/.env
                lxc-attach $container_name -- bash -c "cd /root/cube/${app_name} && npm install && npm update && npm run build"
                sleep 5
                lxc-attach $container_name -- bash -c "cd /root/cube/${app_name} && pm2 start --name ${app_name} npm -- run start"

                sleep 10
                nginx_ct_setup $IP "4000" $container_name $allowed_ips
                ;;
            esac

            sleep 3
            lxc-info -n $container_name
        fi
    fi

    check_docker_container_exists $container_name
    if [ $? -eq 0 ]; then
        echo "Container exists"
        exit 1
    else 
        echo "Container does not exist"
        case $container_name in
        "appsmith")
            echo -e "Setting up appsmith...\n"
            mkdir /root/cluster-setup-script/appsmith
            mkdir /home/devops/appsmith
            cd /root/cluster-setup-script/appsmith
            curl -L https://bit.ly/docker-compose-CE -o $PWD/docker-compose.yml
            # Change the ports
            sed -i 's/80:80/127.0.0.1:8000:80/g' $PWD/docker-compose.yml
            sed -i 's/443:443/127.0.0.1:8443:443/g' $PWD/docker-compose.yml
            sed -i 's/\.\/stacks:\/appsmith-stacks/\/home\/devops\/appsmith:\/appsmith-stacks/g' $PWD/docker-compose.yml
            docker compose up -d
            sleep 2
            echo ""
            echo -e "\e[31m\e[1mIMPORTANT: Only the IP(s) you gave at setup will be able to access the site until you create a user at the site\e[0m"
            local allowed_ips=$(cat /root/allowed_ips.txt)
            echo ""
            nginx_ct_setup "localhost" "8000" "appsmith" $allowed_ips
            user_ct_setup $container_name

            echo -e "Setup done\n"
            ;;

        "n8n")
            cd /root/cluster-setup-script/n8n
            read -p "Enter the username: " n8n_username
            read -s -p "Enter the password: " n8n_password
            echo ""
            read -p "Enter the mail address: " n8n_mail

            echo -e "Setting up n8n...\n"

            docker compose up -d
            echo ""
            echo -e "\e[31m\e[1mIMPORTANT: Only the IP(s) you give will be able to access the site until you create a user at the site\e[0m"
            local allowed_ips=$(cat /root/allowed_ips.txt)
            nginx_ct_setup "localhost" "5678" $container_name $allowed_ips
            user_ct_setup $container_name

            echo -e "Setup done\n"
            ;;
        esac
    fi

    sleep 3

    echo ""
    echo "--------------------CONTAINER SETUP DONE--------------------"
    echo ""
    case $container_name in
    "monitoring")
        echo "Your visual monitoring services are available at: "
        echo https://$srv_name
        echo "https://cadvisor.$dom"
        ;;
    *)
        echo "You can go to your site at: https://${srv_name}"
        ;;
    esac
    echo ""
    echo -e "\e[33mThe container is ready but it might take a few moments to get the applications running\e[0m"
    echo ""
    echo "You can now run the script again to create another container"
    
    exit 0
}

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

    # remove the cronjob in the cron -e and script of the backup
    echo "Deleting backup script and cronjob..."
    rm /etc/cron.d/backup*
    rm /root/backup*.sh


    echo "Reset done"
    echo "You can now run the script again to setup the server"
    exit 0

}

function main () {
    echo ""
    echo "   ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░"
    echo "  ░░░░██████╗░██████╗███████╗██╗░░░██╗███╗░░██╗███████╗██████╗░░█████╗░██╗░░░░░░██████╗░░░"
    echo " ░░░░██╔════╝██╔════╝██╔════╝██║░░░██║████╗░██║██╔════╝██╔══██╗██╔══██╗██║░░░░░██╔════╝░░░░"
    echo "░░░░░╚█████╗░╚█████╗░█████╗░░██║░░░██║██╔██╗██║█████╗░░██████╔╝███████║██║░░░░░╚█████╗░░░░░░"
    echo "░░░░░░╚═══██╗░╚═══██╗██╔══╝░░██║░░░██║██║╚████║██╔══╝░░██╔══██╗██╔══██║██║░░░░░░╚═══██╗░░░░░"
    echo " ░░░░██████╔╝██████╔╝██║░░░░░╚██████╔╝██║░╚███║███████╗██║░░██║██║░░██║███████╗██████╔╝░░░░"
    echo "  ░░░╚═════╝░╚═════╝░╚═╝░░░░░░╚═════╝░╚═╝░░╚══╝╚══════╝╚═╝░░╚═╝╚═╝░░╚═╝╚══════╝╚═════╝░░░░"
    echo "   ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░"
    echo -e "\n---------------------------------------------"
    echo ""
    echo "This script is an installation tool used to setup a system for containers"
    echo ""
    echo "---------------------------------------------"
    echo ""

    local choice_state=false

    while [[ $choice_state == false ]]; do
        echo "    - Setup your system [1]"
        echo "    - Setup a new container [2]"
        echo "    - Reset the server [3]"

	    echo ""
        read -p "What would you like to do: " user_choice
        case $user_choice in
            1)
                vps_setup_single
                choice_state=true
                ;;
            2)
            	create_container
            	choice_state=true
            	;;
            3)
                	reset_server
                	choice_state=true
                	;;
            *)
            	echo "Wrong input"
            	;;
    	esac
    done

}

main "$@"
