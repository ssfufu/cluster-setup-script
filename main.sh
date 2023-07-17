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

    echo "--------------------BACKUP SERVER--------------------"
    echo "This will backup the server and containers to a remote server every hour"

    # Get user inputs
    read -p "Enter the remote server's IP address: " remote_ip
    read -p "Enter the remote server's username: " remote_username
    read -p "Enter the remote server's port: " remote_port
    read -p "Enter the remote server's backup directory: " remote_dir
    read -p "Enter the remote server's backup name: " remote_name
    read -p "Enter the remote server's backup extension: " remote_ext
    read -p "Enter the remote server's backup frequency (in hours): " remote_freq
    read -p "Enter the remote server's backup retention (in days): " remote_retention
    read -p "Enter the remote server's backup compression (y/n): " remote_compression
    read -p "Enter the remote server's backup encryption (y/n): " remote_encryption
    read -p "Do you also want to transfer the backups to an FTP server? (y/n): " ftp_transfer

    if [ "$ftp_transfer" = "y" ]; then
        read -p "Enter the FTP server's IP address: " ftp_ip
        read -p "Enter the FTP server's username: " ftp_username
        read -p "Enter the FTP server's password: " ftp_password
        read -p "Enter the FTP server's backup directory: " ftp_dir
    fi

    # Generate SSH key pair for passwordless authentication
    ssh-keygen -t rsa -b 4096 -f "/home/${USER}/.ssh/${remote_name}_rsa" -N ""

    # Print instructions to copy the public key to the remote server
    echo "To set up passwordless authentication, copy the public key to the remote server with this command:"
    echo "ssh-copy-id -i /home/${USER}/.ssh/${remote_name}_rsa.pub ${remote_username}@${remote_ip} -p ${remote_port}"

    # Generate backup script
    backup_script="/home/${USER}/backup_${remote_name}.sh"
    echo "#!/bin/bash" > "$backup_script"

    # Write commands to perform backup
    echo "dirs_to_backup=(\"/etc\" \"/var/lib/lxc\" \"/var/lib/lxd\" \"/var/lib/docker\")" >> "$backup_script"
    echo "for dir in \"\${dirs_to_backup[@]}\"; do" >> "$backup_script"
    if [ "$remote_compression" = "y" ]; then
        echo "  tar -czf \"${remote_name}.tar.gz\" \"\$dir\"" >> "$backup_script"
        echo "  rsync -avz -e \"ssh -i /home/${USER}/.ssh/${remote_name}_rsa -p $remote_port\" \"${remote_name}.tar.gz\" \"${remote_username}@${remote_ip}:${remote_dir}/\"" >> "$backup_script"
        if [ "$ftp_transfer" = "y" ]; then
            echo "  curl -T \"${remote_name}.tar.gz\" -u ${ftp_username}:${ftp_password} ftp://${ftp_ip}/${ftp_dir}/" >> "$backup_script"
        fi
    else
        echo "  rsync -avz -e \"ssh -i /home/${USER}/.ssh/${remote_name}_rsa -p $remote_port\" \"\$dir\" \"${remote_username}@${remote_ip}:${remote_dir}/\"" >> "$backup_script"
    fi
    echo "done" >> "$backup_script"

    # Add backup retention logic
    echo "find \"${remote_dir}\" -name \"${remote_name}*${remote_ext}\" -type f -mtime +${remote_retention} -delete" >> "$backup_script"

    # Set execute permission on the script
    chmod +x "$backup_script"

    echo "Backup script generated: $backup_script"

    # Add a cron job to run the backup script
    (crontab -l 2>/dev/null; echo "0 */${remote_freq} * * * ${backup_script}") | crontab -

    echo "Cron job added to run the backup script every ${remote_freq} hours"


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

    adduser devops lxd
    su -c "lxd init" devops

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

    # deletes the file if already exists
    rm /etc/nginx/sites-available/$CT_NAME /etc/nginx/sites-enable/$CT_NAME

    # create a directory for this site if it doesn't exist
    touch /etc/nginx/sites-available/${CT_NAME}

    # substitute placeholders with variable values in the template and create a new config file
    sed -e "s#server_name#server_name ${SERVER_NAME};#g" \
        -e "s#proxy_set_header Host#proxy_set_header Host ${SERVER_NAME};#g" \
        -e "s#proxy_pass#proxy_pass ${PROXY_PASS};#g" \
        -e "s#proxy_redirect#proxy_redirect ${PROXY_REDIRECT};#g" \
        -e "s#/etc/letsencrypt/live//#/etc/letsencrypt/live/${SERVER_NAME}/#g" \
        -e "s#if (\$host = )#if (\$host = ${SERVER_NAME})#g" \
        -e "/location \/ {/a deny all;" /root/cluster-setup-script/nginx-config > "/etc/nginx/sites-available/${CT_NAME}"
    
    # Add the allowed IPs
    for ip in $ALLOWED_IPS; do
        sed -i "/deny all;/i allow $ip;" "/etc/nginx/sites-available/${CT_NAME}"
    done

    # create a symlink to the sites-enabled directory
    ln -s /etc/nginx/sites-available/${CT_NAME} /etc/nginx/sites-enabled/
    
    systemctl stop nginx

    certbot certonly --standalone -d ${SERVER_NAME} --email ${MAIL} --agree-tos --no-eff-email --noninteractive --force-renewal
    
    systemctl start nginx

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

    rm /etc/nginx/nginx.conf
    cp /root/cluster-setup-script/nginx.conf /etc/nginx/nginx.conf
    
    rm /etc/nginx/sites-available/default
    rm /etc/nginx/sites-enabled/default
    cp /root/cluster-setup-script/default_conf /etc/nginx/sites-available/default
    ln -s /etc/nginx/sites-available/default /etc/nginx/sites-enabled/

    rm /etc/letsencrypt/options-ssl-nginx.conf > /dev/null
    mkdir -p /etc/letsencrypt/
    cp /root/cluster-setup-script/options-ssl-nginx.conf /etc/letsencrypt/options-ssl-nginx.conf
    openssl dhparam -out /etc/letsencrypt/ssl-dhparams.pem 2048
    chmod 644 /etc/letsencrypt/ssl-dhparams.pem

    cd /root/
    curl -LO "https://github.com/nginxinc/nginx-prometheus-exporter/releases/download/v0.11.0/nginx-prometheus-exporter-0.11.0-linux-amd64.tar.gz"
    tar -xzf "nginx-prometheus-exporter-0.11.0-linux-amd64.tar.gz"
    chmod +x nginx-prometheus-exporter
    mv nginx-prometheus-exporter /usr/local/bin/nginx-prometheus-exporter

    cp /root/cluster-setup-script/nginx-prometheus-exporter.service /etc/systemd/system/nginx-prometheus-exporter.service
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

    read -p "What IP(S) do you want to allow? (Separated by a space) " allowed_ips

    nginx_setup
    lxc_lxd_setup
    docker_setup

    echo ""
    echo ""
    echo "--------------------INSTALLING CADVISOR--------------------"

    docker run --volume=/:/rootfs:ro --volume=/var/run:/var/run:ro --volume=/sys:/sys:ro --volume=/var/lib/docker/:/var/lib/docker:ro --volume=/var/lib/lxc/:/var/lib/lxc:ro --publish=127.0.0.1:8899:8080 --detach=true --name=cadvisor gcr.io/cadvisor/cadvisor:v0.47.2
    nginx_ct_setup "127.0.0.1" "8899" "cadvisor" $allowed_ips
    docker run -d -p 127.0.0.1:9111:9100 --net="host" --pid="host" -v "/:/host:ro,rslave" quay.io/prometheus/node-exporter

    echo ""
    echo ""
    echo "--------------------CADVISOR INSTALLED--------------------"

    wireguard_setup

    systemctl restart nginx.service

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

function create_container () {
    packages=("nano" "wget" "software-properties-common" "ca-certificates" "curl" "gnupg" "git")
    echo "jenkins, prometheus, grafana, tolgee, appsmith, n8n, owncloud, nextcloud, react"

    read -p "Enter the container name: " container_name
    if [ -z "$container_name" ]; then
        echo "You must enter a container name"
        exit 1
    fi
    if ! echo "jenkins prometheus grafana tolgee appsmith n8n owncloud nextcloud react" | grep -w "$container_name" >/dev/null; then
        echo "Container name not in the list"
        exit 1
    fi
    if [ -d "/var/lib/lxc/$container_name" ]; then
        echo "Container named $container_name already exists"
        exit 1
    fi

    read -p "What IP(S) do you want to allow? (Separated by a space, and you can get your own IP at ifconfig.me" allowed_ips

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

    dom="$(cat /root/domain.txt)"
    srv_name="${container_name}.${dom}"

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

    lxc-start -n $container_name
    lxc-attach $container_name -- hostnamectl set-hostname $container_name
    sed -i '/127.0.0.1/c\127.0.0.1 '${container_name} /var/lib/lxc/$container_name/rootfs/etc/hosts
    lxc-stop -n $container_name
    lxc-start -n $container_name

    sleep 5

    lxc-attach $container_name -- ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
    sleep 5
    lxc-attach $container_name -- systemctl restart systemd-networkd
    sleep 5
    lxc-attach $container_name -- systemctl restart systemd-resolved
    sleep 5

    echo "--------------------CONTAINER STARTED--------------------"

    echo ""
    echo "--------------------SETTING UP THE CONTAINER--------------------"

    case $container_name in
    "monitoring")
        update_install_packages $container_name prometheus
        file_name="/var/lib/lxc/$container_name/rootfs/etc/prometheus/prometheus.yml"
	    host_ip=$(ip addr show eth0 | grep inet | awk '{ print $2; }' | sed 's/\/.*$//')

	    # Add the content to the file
	    echo "" >> $file_name
	    echo "  - job_name: node" >> $file_name
    	echo "    static_configs:" >> $file_name
	    echo "      - targets: ['$host_ip:9111']" >> $file_name

	    echo "" >> $file_name
	    echo "  - job_name: 'nginx'" >> $file_name
	    echo "    static_configs:" >> $file_name
	    echo "      - targets: ['$host_ip:8888']" >> $file_name

        echo "" >> $file_name
        echo "  - job_name: 'cadvisor'" >> $file_name
        echo "    static_configs:" >> $file_name
        echo "      - targets: ['$host_ip:8899']" >> $file_name

        wget -q -O /usr/share/keyrings/grafana.key https://apt-get.grafana.com/gpg.key
        echo "deb [signed-by=/usr/share/keyrings/grafana.key] https://apt-get.grafana.com stable main" | sudo tee -a /etc/apt-get/sources.list.d/grafana.list
        lxc-attach $container_name -- apt-get update -y > /dev/null
        sleep 5
        lxc-attach $container_name -- apt-get install grafana -y > /dev/null
        sleep 5
        lxc-attach $container_name -- systemctl daemon-reload
        lxc-attach $container_name -- systemctl start grafana-server
        lxc-attach $container_name -- systemctl enable grafana-server.service

        wget -q -O /usr/share/keyrings/grafana.key https://apt-get.grafana.com/gpg.key
        echo "deb [signed-by=/usr/share/keyrings/grafana.key] https://apt-get.grafana.com stable main" | sudo tee -a /etc/apt-get/sources.list.d/grafana.list
        lxc-attach $container_name -- apt-get update -y > /dev/null
        sleep 5
        lxc-attach $container_name -- apt-get install grafana -y > /dev/null
        sleep 5
        lxc-attach $container_name -- systemctl daemon-reload
        lxc-attach $container_name -- systemctl start grafana-server
        lxc-attach $container_name -- systemctl enable grafana-server.service

        nginx_ct_setup $IP "3000" $container_name $allowed_ips
        ;;


	"tolgee")
        update_install_packages $container_name openjdk-11-jdk jq postgresql postgresql-contrib
	    sleep 10

        read -s "Please enter a password for the database: " db_password

	    echo "Creating database..."
	    lxc-attach $container_name -- bash -c " -u postgres psql -c \"CREATE DATABASE tolgee;\""
	    echo "Creating user..."
	    lxc-attach $container_name -- bash -c " -u postgres psql -c \"CREATE USER tolgee WITH ENCRYPTED PASSWORD '${db_password}';\""
    	echo "Granting privileges..."
	    lxc-attach $container_name -- bash -c " -u postgres psql -c \"GRANT ALL PRIVILEGES ON DATABASE tolgee TO tolgee;\""

	    lxc-attach $container_name -- bash -c "curl -s https://api.github.com/repos/tolgee/tolgee-platform/releases/latest | jq -r '.assets[] | select(.content_type == \"application/java-archive\") | .browser_download_url' | xargs -I {} curl -L -o /root/latest-release.jar {}"
        sleep 5
	    echo -e "spring.datasource.url=jdbc:postgresql://localhost:5432/tolgee\nspring.datasource.username=tolgee\nspring.datasource.password=${db_password}\nserver.port=8200" > /var/lib/lxc/${container_name}/rootfs/root/application.properties

        cp /root/cluster-setup-script/tolgee.service /var/lib/lxc/${container_name}/rootfs/etc/systemd/system/tolgee.service

	    lxc-attach $container_name -- bash -c "pg_ctlcluster 13 main start"
        sleep 2
	    lxc-attach $container_name -- bash -c "systemctl daemon-reload"
	    sleep 2
	    lxc-attach $container_name -- bash -c "systemctl start tolgee && systemctl enable tolgee"
        sleep 5
        nginx_ct_setup $IP "8200" $container_name $allowed_ips
	    ;;

	"appsmith")
	    echo -e "Setting up appsmith...\n"
	    mkdir /root/appsmith
        cd /root/appsmith

    	curl -L https://bit.ly/docker-compose-CE -o $PWD/docker-compose.yml

        # Change the ports
        sed -i 's/80:80/127.0.0.1:8000:80/g' $PWD/docker-compose.yml
        # sed -i 's/443:443/127.0.0.1:8443:443/g' $PWD/docker-compose.yml

	    docker-compose up -d
	    sleep 2
        nginx_ct_setup "localhost" "8000" "appsmith" $allowed_ips

	    echo -e "Setup done\n"
        ;;

    "n8n")
        cd /root/cluster-setup-script
        docker-compose up -d
        sleep 5
        nginx_ct_setup "localhost" "5678" $container_name $allowed_ips
        ;;
    "owncloud")
        update_install_packages $container_name mariadb-server php-fpm php-mysql php-xml php-mbstring php-gd php-curl nginx php7.4-fpm php7.4-mysql php7.4-common php7.4-gd php7.4-json php7.4-curl php7.4-zip php7.4-xml php7.4-mbstring php7.4-bz2 php7.4-intl
        sleep 10
        rm /var/lib/lxc/$container_name/rootfs/etc/nginx/sites-available/default
        cp /root/cluster-setup-script/config-owncloud /var/lib/lxc/$container_name/rootfs/etc/nginx/sites-available/default
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
        lxc-attach $container_name -- bash -c "apt-get install php8.2 php8.2-cli php8.2-common php8.2-curl php8.2-mbstring php8.2-mysql php8.2-xml php8.2-zip php8.2-intl php8.2-imagick -y"
        lxc-attach $container_name -- bash -c "a2enmod php8.2 && a2dismod php7.4"
        lxc-attach $container_name -- bash -c "systemctl restart apache2"
        _domain="$(cat /root/domain.txt)"
        lxc-attach $container_name -- bash -c "wget https://download.nextcloud.com/server/releases/latest.zip && unzip latest.zip -d /var/www/"
        lxc-attach $container_name -- bash -c "chown -R www-data:www-data /var/www/nextcloud/"
        lxc-attach $container_name -- bash -c "chmod -R 755 /var/www/nextcloud/"
        sed -i "s/ServerName.*/ServerName ${container_name}.${_domain}/g" /root/cluster-setup-script/nextcloud.conf
        cp /root/cluster-setup-script/nextcloud.conf /var/lib/lxc/$container_name/rootfs/etc/apache2/sites-available/nextcloud.conf
        lxc-attach $container_name -- bash -c "a2ensite nextcloud"
        lxc-attach $container_name -- bash -c "a2enmod rewrite headers env dir mime"
        lxc-attach $container_name -- bash -c "a2dissite 000-default"
        echo "ServerName ${container_name}" >> /var/lib/lxc/$container_name/rootfs/etc/apache2/apache2.conf
        lxc-attach $container_name -- bash -c "systemctl restart apache2"

        nginx_ct_setup $IP "80" $container_name $allowed_ips
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
	esac

    sleep 3
    lxc-info -n $container_name

    echo ""
    echo "--------------------CONTAINER SETUP DONE--------------------"
    echo ""
    echo "The container's IP address is: $IP"
    echo "The container's hostname is: $container_name"
    echo "The container's domain name is: $srv_name"
    echo "The container's ports are:"
    case $container_name in
    "monitoring")
        echo "Prometheus: $IP:9090"
        echo "Grafana: $IP:3000"
        echo "Cadvisor: $IP:8899"
        ;;
    "tolgee")
        echo "Tolgee: $IP:8200"
        ;;
    "appsmith")
        echo "Appsmith: $IP:8000"
        ;;
    "n8n")
        echo "n8n: $IP:5678"
        ;;
    "owncloud")
        echo "owncloud: $IP:80"
        ;;
    "nextcloud")
        echo "nextcloud: $IP:80"
        ;;
    "react")
        echo "react: $IP:3000"
        ;;
    esac
    
    exit 0
}

function reset_server () {
    # echo a warning in red color
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
    # stop and destroy all lxc containers at once
    lxc-ls -f | awk '{print $1}' | grep -v NAME | xargs -I {} lxc-stop -n {}
    lxc-ls -f | awk '{print $1}' | grep -v NAME | xargs -I {} lxc-destroy -n {}

    # Make a for loop to remove all containers lxc that match the names in this script
    for i in jenkins prometheus grafana tolgee owncloud; do
        if [ -d "/var/lib/lxc/$i" ]; then
            echo "Deleting container $i"
            lxc-stop -n $i
            lxc-destroy -n $i
        fi
    done

    echo "Deleting networks..."
    lxc network delete DMZ
    lxc network delete DMZ2

    # Delete lxd and lxc
    echo "Deleting lxd and lxc..."
    apt-get remove -y lxc
    snap remove lxd

    rm -rf /var/lib/lxd
    rm -rf /var/lib/lxc
    rm -rf /etc/lxd
    rm -rf /etc/lxc

    echo "Deleting nginx config files..."
    rm /etc/nginx/sites-available/cadvisor /etc/nginx/sites-enabled/cadvisor
    rm /etc/nginx/sites-available/jenkins /etc/nginx/sites-enabled/jenkins
    rm /etc/nginx/sites-available/prometheus /etc/nginx/sites-enabled/prometheus
    rm /etc/nginx/sites-available/grafana /etc/nginx/sites-enabled/grafana
    rm /etc/nginx/sites-available/tolgee /etc/nginx/sites-enabled/tolgee
    rm /etc/nginx/sites-available/appsmith /etc/nginx/sites-enabled/appsmith
    rm /etc/nginx/sites-available/n8n /etc/nginx/sites-enabled/n8n
    rm /etc/nginx/sites-available/owncloud /etc/nginx/sites-enabled/owncloud

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
