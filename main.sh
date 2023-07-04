#!/bin/bash
# checks if the user is root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

# checks if the ipcalc package is installed
if ! dpkg -l | grep -w "ipcalc" >/dev/null; then
    echo "ipcalc package is not installed... installing it"
    apt install ipcalc -y >/dev/null
    echo "ipcalc package installed"
fi

vps_setup_single () {
    sudo apt install nginx -y
    sudo systemctl enable nginx && sudo systemctl start nginx
    sudo apt install lxc snapd
    sudo snap install core
    sudo snap install lxd

    sudo adduser $SUDO_USER lxd
    newgrp lxd
    sudo -i

    # Do not create a bridge by default
    lxd init
    exit

    # Installing Docker
    for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do sudo apt-get remove $pkg; done

    sudo apt-get update
    sudo apt-get install ca-certificates curl gnupg

    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
      "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
      "$(. /etc/os-release && echo "$VERSION_CODENAME")" stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update
    sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    sudo groupadd docker
    sudo usermod -aG docker $SUDO_USER
    newgrp docker

    sudo systemctl enable docker.service
    sudo systemctl enable containerd.service

    touch /home/$SUDO_USER/.setup
    echo "done" >> /home/$SUDO_USER/.setup
}

update_install_packages () {
    container_name=$1
    shift
    packages=("$@")

    lxc-attach $container_name -- apt update -y
    lxc-attach $container_name -- apt install nano wget software-properties-common ca-certificates curl gnupg git -y
    for i in "${packages[@]}"; do
        lxc-attach $container_name -- apt install $i -y
    done

}

create_container () {
    # ask the user for the container name
    read -p "Enter the container name: " container_name
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

    	lxc-attach $container_name -- bash -c "curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key | sudo tee /usr/share/keyrings/jenkins-keyring.asc > /dev/null"
	    lxc-attach $container_name -- bash -c "echo deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/ | sudo tee /etc/apt/sources.list.d/jenkins.list > /dev/null"
    	lxc-attach $container_name -- apt update -y && apt install jenkins -y
	    lxc-attach $container_name -- systemctl start jenkins && sudo systemctl enable jenkins
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


	"tolgee")
        update_install_packages $container_name openjdk-11-jdk jq postgresql postgresql-contrib
	    sleep 10

	    echo "Creating database..."
	    lxc-attach $container_name -- bash -c "sudo -u postgres psql -c \"CREATE DATABASE tolgee;\""
	    echo "Creating user..."
	    lxc-attach $container_name -- bash -c "sudo -u postgres psql -c \"CREATE USER tolgee WITH ENCRYPTED PASSWORD 'password';\""
    	    echo "Granting privileges..."
	    lxc-attach $container_name -- bash -c "sudo -u postgres psql -c \"GRANT ALL PRIVILEGES ON DATABASE tolgee TO tolgee;\""

	    echo "Curl and shit..."
	    lxc-attach $container_name -- bash -c "curl -s https://api.github.com/repos/tolgee/tolgee-platform/releases/latest | jq -r '.assets[] | select(.content_type == \"application/java-archive\") | .browser_download_url' | xargs -I {} curl -L -o /root/latest-release.jar {}"
	    echo -e "spring.datasource.url=jdbc:postgresql://localhost:5432/tolgee\nspring.datasource.username=tolgee\nspring.datasource.password=password\nserver.port=8200" > /var/lib/lxc/$container_name/rootfs/root/application.properties


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
	    lxc-attach $container_name -- bash -c "systemctl daemon-reload"

	    lxc-attach $container_name -- sleep 2

	    lxc-attach $container_name -- bash -c "systemctl start tolgee && systemctl enable tolgee"
	    ;;

	"appsmith")
	    echo -e "Setting up appsmith...\n"
	    cd ~
    	    curl -L https://bit.ly/docker-compose-CE -o $PWD/docker-compose.yml
	    docker-compose up -d
	    sleep 2
	    echo -e "Setup done\n"
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
                vps_setup_function
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
