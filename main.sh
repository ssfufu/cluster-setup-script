#!/bin/bash
# checks if the script is launched as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

# checks if the ipcalc package is installed
if ! dpkg -l | grep -w "ipcalc" >/dev/null; then
    echo "ipcalc package is not installed... installing it"
    apt-get install ipcalc -y >/dev/null
    sleep 2
    echo "ipcalc package installed"
fi

nginx_setup() {
    # Get parameters
    local CT_IP="$1"
    local CT_PORT="$2"
    local CT_NAME="$3"
    local DOMAIN="$(cat /root/domain.txt)"
    local MAIL="$(cat /root/mail.txt)"

    # construct server_name and proxy_pass
    local SERVER_NAME="${CT_NAME}.${DOMAIN}"
    local PROXY_PASS="http://${CT_IP}:${CT_PORT}"
    local PROXY_REDIRECT="http://${CT_IP}:${CT_PORT} https://${SERVER_NAME}"

    # deletes the file if already exists
    rm /etc/nginx/sites-available/$CT_NAME /etc/nginx/sites-enable/$CT_NAME

    # create a directory for this site if it doesn't exist
    touch /etc/nginx/sites-available/${CT_NAME}
    # rm /etc/letsencrypt/options-ssl-nginx.conf
    # touch /etc/letsencrypt/options-ssl-nginx.conf

    # echo "# This file contains important security parameters. If you modify this file" >> /etc/letsencrypt/options-ssl-nginx.conf
    # echo "# manually, Certbot will be unable to automatically provide future security" >> /etc/letsencrypt/options-ssl-nginx.conf
    # echo "# updates. Instead, Certbot will print and log an error message with a path to" >> /etc/letsencrypt/options-ssl-nginx.conf
    # echo "# the up-to-date file that you will need to refer to when manually updating" >> /etc/letsencrypt/options-ssl-nginx.conf
    # echo "# this file." >> /etc/letsencrypt/options-ssl-nginx.conf
    # echo "" >> /etc/letsencrypt/options-ssl-nginx.conf
    # echo "ssl_session_cache shared:le_nginx_SSL:10m;" >> /etc/letsencrypt/options-ssl-nginx.conf
    # echo "ssl_session_timeout 1440m;" >> /etc/letsencrypt/options-ssl-nginx.conf
    # echo "ssl_session_tickets off;" >> /etc/letsencrypt/options-ssl-nginx.conf
    # echo "" >> /etc/letsencrypt/options-ssl-nginx.conf
    # echo "ssl_protocols TLSv1.2 TLSv1.3;" >> /etc/letsencrypt/options-ssl-nginx.conf
    # echo "ssl_prefer_server_ciphers off;" >> /etc/letsencrypt/options-ssl-nginx.conf
    # echo "" >> /etc/letsencrypt/options-ssl-nginx.conf
    # echo "ssl_ciphers "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384";" >> /etc/letsencrypt/options-ssl-nginx.conf

    # substitute placeholders with variable values in the template and create a new config file
    sed -e "s#server_name#server_name ${SERVER_NAME};#g" \
        -e "s#proxy_pass#proxy_pass ${PROXY_PASS};#g" \
        -e "s#proxy_redirect#proxy_redirect ${PROXY_REDIRECT};#g" \
        -e "s#/etc/letsencrypt/live//#/etc/letsencrypt/live/${SERVER_NAME}/#g" \
        -e "s#if (\$host = )#if (\$host = ${SERVER_NAME})#g" /root/cluster-setup-script/nginx-config > "/etc/nginx/sites-available/${CT_NAME}"

    ln -s /etc/nginx/sites-available/${CT_NAME} /etc/nginx/sites-enabled/
    
    systemctl stop nginx

    certbot certonly --nginx -d ${SERVER_NAME} --email ${MAIL} --agree-tos --no-eff-email --noninteractive --force-renewal
    systemctl start nginx

}

vps_setup_single () {
    # create a new user and add it to the sudo group
    adduser devops
    usermod -aG sudo devops
    
    read -p "What is your domain(s) ? " domain_user
    touch /root/domain.txt
    echo $domain_user > /root/domain.txt

    read -p "What is your e-mail? " mail_user
    touch /root/mail.txt
    echo $mail_user > /root/mail.txt

    apt-get install nginx -y
    sleep 1
    systemctl enable nginx && systemctl start nginx
    apt-get install lxc snapd -y
    sleep 2
    snap install core
    sleep 2
    snap install lxd
    sleep 2
    snap install --classic certbot
    sleep 1
    ln -s /snap/bin/certbot /usr/bin/certbot


    adduser $SUDO_USER lxd
    su -c "lxd init" $SUDO_USER

    lxd network create DMZ ipv4.address=10.128.151.1/24 ipv4.nat=true ipv4.dhcp=false
    lxd network create DMZ2 ipv4.address=10.128.152.1/24 ipv4.nat=true ipv4.dhcp=false

    # Installing Docker
    for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do apt-get remove $pkg; done

    apt-get update -y
    sleep 3
    apt-get install ca-certificates curl gnupg -y

    install -m 0755 -d /etc/apt-get/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt-get/keyrings/docker.gpg
    chmod a+r /etc/apt-get/keyrings/docker.gpg

    echo \
        "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt-get/keyrings/docker.gpg] https://download.docker.com/linux/debian \
        "$(. /etc/os-release && echo "$VERSION_CODENAME")" stable" | \
        tee /etc/apt-get/sources.list.d/docker.list > /dev/null

    apt-get update -y
    apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin debootstrap bridge-utils -y

    groupadd docker
    usermod -aG docker devops

    systemctl enable docker.service
    systemctl enable containerd.service

    docker run --volume=/:/rootfs:ro --volume=/var/run:/var/run:ro --volume=/sys:/sys:ro --volume=/var/lib/docker/:/var/lib/docker:ro --volume=/var/lib/lxc/:/var/lib/lxc:ro --publish=8080:8080 --detach=true --name=cadvisor gcr.io/cadvisor/cadvisor:v0.47.2
    nginx_setup "localhost" "8080" "cadvisor"
    docker run -d -p 9100:9100 --net="host" --pid="host" -v "/:/host:ro,rslave" quay.io/prometheus/node-exporter


    #cd /root/
    #mkdir wireguard_script && cd wireguard_script
    #curl -O https://raw.githubusercontent.com/angristan/wireguard-install/master/wireguard-install.sh
    #chmod +x wireguard-install.sh
    #./wireguard-install.sh

    echo -e "-------------SETUP DONE-------------\n"
    #echo "You now have a ready to use VPN (execute /home/devops/wireguard_script/wireguard-install.sh for creating, removing clients.)"
    echo "And also a cadvisor web pannel at cadvisor.$domain_user"

}

update_install_packages () {
    container_name=$1
    shift
    packages=("$@")

    lxc-attach $container_name -- bash -c "apt-get update -y && apt-get install nano wget software-properties-common ca-certificates curl gnupg git -y"
    sleep 20
    for i in "${packages[@]}"; do
        lxc-attach $container_name -- apt-get install $i -y
    done

}

create_container () {
    # ask the user for the container name
    read -p "Enter the container name: " container_name
    echo "jenkins, prometheus, grafana, tolgee, appsmith, n8n, owncloud"
    packages=("nano" "wget" "software-properties-common" "ca-certificates" "curl" "gnupg" "git")
    if [ -z "$container_name" ]; then
        echo "You must enter a container name"
        exit 1
    fi

    if [ -d "/var/lib/lxc/$container_name" ]; then
        echo "Container named $container_name already exists"
        exit 1
    fi

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


    read -p "Enter an IP address for the network $interface ($gateway): " IP
    if [ -z "$IP" ]; then
        echo "You must enter an IP address"
        exit 1
    fi

    dom="$(cat /root/domain.txt)"
    srv_name="${container_name}.${dom}"

    echo ""

    # checks if the IP is on the the same network as the gateway (like if the network is 10.128.151.x, the IP must be 10.128.151.x)
    if ! ipcalc -c "$IP" "$gateway" >/dev/null; then
        echo "IP address is not on the same network as the gateway"
        exit 1
    fi

    # makes a loop to check if the IP is already allocated and reask the user for a new IP
    if ping -c 1 "$IP" >/dev/null; then
        echo "IP address is already allocated"
    else
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

        # creates the container
        echo "Creating container..."
        lxc-create -t download -n $container_name -- -d debian -r bullseye -a amd64 > /dev/null

        # updates the contaier's config file
        echo "Updating container's config file"
        sed -i "s/lxc.net.0.link = lxcbr0/lxc.net.0.link = $interface/g" /var/lib/lxc/$container_name/config
        echo "lxc.net.0.ipv4.address = $IP/24" >> /var/lib/lxc/$container_name/config
        echo "lxc.net.0.ipv4.gateway = $gateway" >> /var/lib/lxc/$container_name/config

        #replaces the container's rootfs with the network file
        echo "Replacing container's rootfs with the network file"
        mv /tmp/10-eth0.network /var/lib/lxc/$container_name/rootfs/etc/systemd/network/10-eth0.network
    fi

    lxc-start -n $container_name
    echo "Installing required packages..."

    case $container_name in
	"jenkins")
	    update_install_packages $container_name openjdk-11-jdk

    	lxc-attach $container_name -- bash -c "curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key |  tee /usr/share/keyrings/jenkins-keyring.asc > /dev/null"
	    lxc-attach $container_name -- bash -c "echo deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/ |  tee /etc/apt-get/sources.list.d/jenkins.list > /dev/null"
    	lxc-attach $container_name -- apt-get update -y && apt-get install jenkins -y
	    lxc-attach $container_name -- systemctl start jenkins &&  systemctl enable jenkins
        nginx_setup $IP "8080" $container_name
    	;;


	"prometheus")
	    update_install_packages $container_name prometheus
	    file_name="/var/lib/lxc/$container_name/rootfs/etc/prometheus/prometheus.yml"
	    host_ip=$(ip addr show eth0 | grep inet | awk '{ print $2; }' | sed 's/\/.*$//')

	    # Add the content to the file
	    echo "" >> $file_name
	    echo "  - job_name: node" >> $file_name
	    echo "    # If prometheus-node-exporter is installed, grab stats about the local" >> $file_name
	    echo "    # machine by default." >> $file_name
    	echo "    static_configs:" >> $file_name
	    echo "      - targets: ['$host_ip:9100']" >> $file_name
	    echo "" >> $file_name
	    echo "  - job_name: 'jenkins'" >> $file_name
	    echo "    static_configs:" >> $file_name
	    echo "      - targets: ['10.128.151.10:8080']" >> $file_name
	    echo "    metrics_path: '/prometheus/'" >> $file_name
	    ;;
    
    "grafana")
        update_install_packages $container_name
        wget -q -O /usr/share/keyrings/grafana.key https://apt-get.grafana.com/gpg.key
        echo "deb [signed-by=/usr/share/keyrings/grafana.key] https://apt-get.grafana.com stable main" | sudo tee -a /etc/apt-get/sources.list.d/grafana.list
        apt-get update -y
        apt-get install grafana -y
        systemctl daemon-reload
        systemctl start grafana-server
        systemctl enable grafana-server.service
        nginx_setup $IP "3000" $srv_name
        ;;


	"tolgee")
        update_install_packages $container_name openjdk-11-jdk jq postgresql postgresql-contrib
	    sleep 10

	    echo "Creating database..."
	    lxc-attach $container_name -- bash -c " -u postgres psql -c \"CREATE DATABASE tolgee;\""
	    echo "Creating user..."
	    lxc-attach $container_name -- bash -c " -u postgres psql -c \"CREATE USER tolgee WITH ENCRYPTED PASSWORD 'fedhubs';\""
    	echo "Granting privileges..."
	    lxc-attach $container_name -- bash -c " -u postgres psql -c \"GRANT ALL PRIVILEGES ON DATABASE tolgee TO tolgee;\""

	    echo "Curl and shit..."
	    lxc-attach $container_name -- bash -c "curl -s https://api.github.com/repos/tolgee/tolgee-platform/releases/latest | jq -r '.assets[] | select(.content_type == \"application/java-archive\") | .browser_download_url' | xargs -I {} curl -L -o /root/latest-release.jar {}"
        sleep 5
	    echo -e "spring.datasource.url=jdbc:postgresql://localhost:5432/tolgee\nspring.datasource.username=tolgee\nspring.datasource.password=fedhubs\nserver.port=8200" > /var/lib/lxc/$container_name/rootfs/root/application.properties


	    touch /var/lib/lxc/$container_name/rootfs/etc/systemd/system/tolgee.service
	    echo "[Unit]" > /var/lib/lxc/$container_name/rootfs/etc/systemd/system/tolgee.service
	    echo "Description=Tolgee Service" >> /var/lib/lxc/$container_name/rootfs/etc/systemd/system/tolgee.service
	    echo "After=network.target" >> /var/lib/lxc/$container_name/rootfs/etc/systemd/system/tolgee.service
	    echo "" >> /var/lib/lxc/$container_name/rootfs/etc/systemd/system/tolgee.service
	    echo "[Service]" >> /var/lib/lxc/$container_name/rootfs/etc/systemd/system/tolgee.service
	    echo "User=root" >> /var/lib/lxc/$container_name/rootfs/etc/systemd/system/tolgee.service
	    echo "WorkingDirectory=/root/" >> /var/lib/lxc/$container_name/rootfs/etc/systemd/system/tolgee.service
	    echo "ExecStart=/usr/bin/java -Dtolgee.postgres-autostart.enabled=false -jar latest-release.jar" >> /var/lib/lxc/$container_name/rootfs/etc/systemd/system/tolgee.service
	    echo "SuccessExitStatus=143" >> /var/lib/lxc/$container_name/rootfs/etc/systemd/system/tolgee.service
	    echo "TimeoutStopSec=10" >> /var/lib/lxc/$container_name/rootfs/etc/systemd/system/tolgee.service
	    echo "Restart=on-failure" >> /var/lib/lxc/$container_name/rootfs/etc/systemd/system/tolgee.service
	    echo "RestartSec=5" >> /var/lib/lxc/$container_name/rootfs/etc/systemd/system/tolgee.service
	    echo "" >> /var/lib/lxc/$container_name/rootfs/etc/systemd/system/tolgee.service
	    echo "[Install]" >> /var/lib/lxc/$container_name/rootfs/etc/systemd/system/tolgee.service
	    echo "WantedBy=multi-user.target" >> /var/lib/lxc/$container_name/rootfs/etc/systemd/system/tolgee.service

	    lxc-attach $container_name -- bash -c "pg_ctlcluster 13 main start"
        sleep 2
	    lxc-attach $container_name -- bash -c "systemctl daemon-reload"
	    sleep 2
	    lxc-attach $container_name -- bash -c "systemctl start tolgee && systemctl enable tolgee"
        sleep 5
        nginx_setup $IP "8200" $srv_name
	    ;;

	"appsmith")
	    echo -e "Setting up appsmith...\n"
	    mkdir /root/appsmith
        cd /root/appsmith

    	curl -L https://bit.ly/docker-compose-CE -o $PWD/docker-compose.yml

        # Change the ports
        sed -i 's/80:80/8000:80/g' $PWD/docker-compose.yml
        # sed -i 's/443:443/8443:443/g' $PWD/docker-compose.yml

	    docker-compose up -d
	    sleep 2
        nginx_setup "localhost" "8000" "appsmith"

	    echo -e "Setup done\n"
        ;;

    "n8n")
        cd /root/cluster-setup-script
        docker-compose up -d
        sleep 5
        nginx_setup "localhost" "5678" $srv_name
        ;;
    "owncloud")
        update_install_packages $container_name mariadb-server php-fpm php-mysql php-xml php-mbstring php-gd php-curl nginx php7.4-fpm php7.4-mysql php7.4-common php7.4-gd php7.4-json php7.4-curl php7.4-zip php7.4-xml php7.4-mbstring php7.4-bz2 php7.4-intl
        sleep 10
        rm /var/lib/lxc/$container_name/rootfs/etc/nginx/sites-available/default
        cp /root/cluster-setup-script/config-owncloud /var/lib/lxc/$container_name/rootfs/etc/nginx/sites-available/default
        lxc-attach $container_name -- bash -c "curl https://download.owncloud.org/download/repositories/production/Debian_11/Release.key | apt-get-key add -"
        lxc-attach $container_name -- bash -c "echo 'deb http://download.owncloud.org/download/repositories/production/Debian_11/ /' > /etc/apt-get/sources.list.d/owncloud.list"
        lxc-attach $container_name -- apt-get update -y
        lxc-attach $container_name -- apt-get install -y owncloud-files

        # Configure MariaDB
        echo -n "Please enter a owncloud database password: "
        read -s db_password
        lxc-attach $container_name -- bash -c "mysql -e \"CREATE DATABASE owncloud; GRANT ALL ON owncloud.* to 'owncloud'@'localhost' IDENTIFIED BY '$db_password'; FLUSH PRIVILEGES;\""

        # Configure PHP
        lxc-attach $container_name -- bash -c "sed -i 's/post_max_size = .*/post_max_size = 2000M/' /etc/php/7.4/fpm/php.ini"
        lxc-attach $container_name -- bash -c "sed -i 's/upload_max_filesize = .*/upload_max_filesize = 2000M/' /etc/php/7.4/fpm/php.ini"
        lxc-attach $container_name -- bash -c "sed -i 's/max_execution_time = .*/max_execution_time = 3600/' /etc/php/7.4/fpm/php.ini"
        lxc-attach $container_name -- bash -c "sed -i 's/memory_limit = .*/memory_limit = 512M/' /etc/php/7.4/fpm/php.ini"
        lxc-attach $container_name -- bash -c "systemctl restart php7.4-fpm"
        lxc-attach $container_name -- bash -c "systemctl restart nginx"
        nginx_setup $IP "80" $server_name
        ;;
	esac

    sleep 3
    lxc-info -n $container_name

    exit 0
}

main () {
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
            *)
            	echo "Wrong input"
            	;;
    	esac
    done

}

main "$@"
