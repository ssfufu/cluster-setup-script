#!/bin/bash
source scripts/update_install_packages.sh
source scripts/nginx_ct_setup.sh
source scripts/check_docker_container_exists.sh
source scripts/user_ct_setup.sh

function create_container () {
    packages=("nano" "wget" "software-properties-common" "ca-certificates" "curl" "gnupg" "git")
    docker_cts=("n8n" "appsmith" "illa")
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
    if ! echo "monitoring tolgee appsmith n8n illa owncloud nextcloud react cube" | grep -w "$container_name" >/dev/null; then
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
                port_forwarding="3000"

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
                ;;


            "tolgee")
                update_install_packages $container_name openjdk-11-jdk jq postgresql postgresql-contrib
                sleep 10

                read -p "Do you want to create a local database, or use an existing one? (create / existing) " db_choice
                if [[ $db_choice == "create" ]]; then
                    sed -i "s/#listen_addresses = 'localhost'/listen_addresses = 'localhost,127.0.0.1'/g" /var/lib/lxc/${container_name}/rootfs/etc/postgresql/13/main/postgresql.conf
                    lxc-attach $container_name -- bash -c "systemctl restart postgresql"
                    sleep 2
                    db_username="tolgee"
                    db_name="tolgee"
                    db_host="127.0.0.1"
                    db_port="5432"
                    read -s -p "Please enter a password for the database: " db_password
                    echo ""
                    echo "The database will be created with the following credentials:"
                    echo "Database name: $db_name"
                    echo "Database username: $db_username"
                    read -p "Do you wish to see the password? (y/n) " see_password
                    if [[ $see_password == "y" ]]; then
                        echo "Database password: $db_password"
                    fi
                    lxc-attach $container_name -- bash -c "su - postgres -c \"psql -c 'CREATE USER tolgee WITH PASSWORD '\''${db_password}'\'';'\""
                    sleep 1
                    lxc-attach $container_name -- bash -c "su - postgres -c \"psql -c 'CREATE DATABASE tolgee OWNER tolgee;'\""
                    sleep 1
                elif [[ $db_choice == "existing" ]]; then
                    read -p "Please enter the host of the database: " db_host
                    read -p "Please enter the port of the database: " db_port
                    read -p "Please enter the name of the database: " db_name
                    read -p "Please enter the username of the database: " db_username
                    read -s -p "Please enter the password of the database: " db_password
                    ecbo ""
                fi

                echo ""
                read -s -p "Please enter a password for the admin user: " admin_password
                echo "The initial admin user will be created with the following credentials:"
                echo "Username: tolgee"
                read -p "Do you wish to see the password? (y/n) " see_password_admin
                if [[ $see_password_admin == "y" ]]; then
                    echo "Password: $admin_password"
                fi
                echo ""


                lxc-attach $container_name -- bash -c "curl -s https://api.github.com/repos/tolgee/tolgee-platform/releases/latest | jq -r '.assets[] | select(.content_type == \"application/java-archive\") | .browser_download_url' | xargs -I {} curl -L -o /root/latest-release.jar {}"
                sleep 5
                touch /var/lib/lxc/${container_name}/rootfs/root/application.properties
                echo -e "spring.datasource.url=jdbc:postgresql://${db_host}:${db_port}/tolgee\n
                    spring.datasource.username=${db_username}\n
                    spring.datasource.password=${db_password}\n
                    server.port=8200\n
                    tolgee.authentication.enabled=true\n
                    tolgee.authentication.create-initial-user=true\n
                    tolgee.authentication.initial-username=tolgee\n
                    tolgee.authentication.initial-password=${admin_password}\n" > /var/lib/lxc/${container_name}/rootfs/root/application.properties

                cp /root/cluster-setup-script/tolgee/tolgee.service /var/lib/lxc/${container_name}/rootfs/etc/systemd/system/tolgee.service

                lxc-attach $container_name -- bash -c "pg_ctlcluster 13 main start"
                sleep 2
                lxc-attach $container_name -- bash -c "systemctl daemon-reload"
                sleep 2
                lxc-attach $container_name -- bash -c "systemctl start tolgee && systemctl enable tolgee"
                sleep 5
                 port_forwarding=8200
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
                port_forwarding=80
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
                port_forwarding=80
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
                port_forwarding=3000
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
                echo -e "export NVM_DIR=\"\$HOME/.nvm\"\n[ -s \"\$NVM_DIR/nvm.sh\" ] && \\. \"\$NVM_DIR/nvm.sh\"\nnvm install --lts\nnvm use --lts\nnpm install -g cubejs-cli\nnpm install -g pm2" > /var/lib/lxc/$container_name/rootfs/root/cube_script.sh
                lxc-attach $container_name -- bash -c "chmod +x /root/cube_script.sh"
                lxc-attach $container_name -- bash -c "/root/cube_script.sh"

                lxc-attach $container_name -- bash -c "mkdir /root/cube"
                read -p "Enter the app name: " app_name
                read -p "Enter the database name: " db_name
                read -p "Enter the database username: " db_username
                read -s -p "Enter the database password: " db_password
                echo ""

                lxc-attach $container_name -- bash -c "export NVM_DIR=\"/root/.nvm\" && [ -s \"\$NVM_DIR/nvm.sh\" ] && \\. \"\$NVM_DIR/nvm.sh\" && nvm use --lts && cd /root/cube && cubejs create ${app_name}"
                sleep 5
                #Generate a secret and put in .env
                secret=$(openssl rand -hex 32)
                cp /root/cluster-setup-script/cube/.env /var/lib/lxc/$container_name/rootfs/root/cube/${app_name}/.env
                sed -i "s/CUBEJS_DB_NAME=/CUBEJS_DB_NAME=$db_name/g" /var/lib/lxc/$container_name/rootfs/root/cube/${app_name}/.env
                sed -i "s/CUBEJS_DB_USER=/CUBEJS_DB_USER=$db_username/g" /var/lib/lxc/$container_name/rootfs/root/cube/${app_name}/.env
                sed -i "s/CUBEJS_DB_PASS=/CUBEJS_DB_PASS=$db_password/g" /var/lib/lxc/$container_name/rootfs/root/cube/${app_name}/.env
                sed -i "s/CUBEJS_APP=/CUBEJS_APP=$app_name/g" /var/lib/lxc/$container_name/rootfs/root/cube/${app_name}/.env
                sed -i "s/CUBEJS_API_SECRET=/CUBEJS_API_SECRET=$secret/g" /var/lib/lxc/$container_name/rootfs/root/cube/${app_name}/.env
                echo "NODE_ENV=production" >> /var/lib/lxc/$container_name/rootfs/root/cube/${app_name}/.env
                cp /root/cluster-setup-script/cube/jwt.js /var/lib/lxc/$container_name/rootfs/root/cube/${app_name}/jwt.js
                sed -i "s/YOUR_CUBEJS_SECRET/$secret/g" /var/lib/lxc/$container_name/rootfs/root/cube/${app_name}/jwt.js
                lxc-attach $container_name -- bash -c "export NVM_DIR=\"/root/.nvm\" && [ -s \"\$NVM_DIR/nvm.sh\" ] && \\. \"\$NVM_DIR/nvm.sh\" && nvm use --lts && cd /root/cube/${app_name} && npm install && npm update"
                sleep 5
                lxc-attach $container_name -- bash -c "export NVM_DIR=\"/root/.nvm\" && [ -s \"\$NVM_DIR/nvm.sh\" ] && \\. \"\$NVM_DIR/nvm.sh\" && nvm use --lts && cd /root/cube/${app_name} && pm2 start --name ${app_name} npm -- run dev && pm2 save"
                sleep 10
                port_forwarding=4000
                ;;
            esac
            if [ "$container_name" == "nextcloud" ]; then
                nginx_ct_setup $IP $port_forwarding $container_name "/root/allowed_ips.txt"
            else
                echo ""
                echo ""
                echo "--------------------------------SUBDOMAIN SETUP-----------------------------------"
                echo ""
                read -p "Do you want the subdomain to be ${container_name} ? (y/n) " subdomain_choice
                if [ "$subdomain_choice" == "n" ]; then
                    read -p "Enter the subdomain: " subdomain
                    nginx_ct_setup $IP $port_forwarding $subdomain "/root/allowed_ips.txt"
                elif [ "$subdomain_choice" == "y" ]; then
                    nginx_ct_setup $IP $port_forwarding $container_name "/root/allowed_ips.txt"
                fi
            fi

            sleep 3
            lxc-info -n $container_name
        fi
    fi

    check_docker_container_exists $container_name
    if [ $? -eq 0 ]; then
        echo "Container exists"
        exit 1
    elif [[ ! " ${lxc_cts[@]} " =~ " ${container_name} " ]]; then
        echo "Container does not exist yet"
        case $container_name in
        "appsmith")
            echo -e "Setting up appsmith...\n"
            mkdir /home/devops/appsmith
            docker compose -f /root/cluster-setup-script/docker_compose_files/appsmith/docker-compose.yml up -d
            sleep 2
            echo ""
            echo -e "\e[31m\e[1mIMPORTANT: Only the IP(s) you gave at setup will be able to access the site until you create a user at the site\e[0m"
            local allowed_ips=$(cat /root/allowed_ips.txt)
            echo ""
            port_forwarding=7667
            echo -e "Setup done\n"
            ;;

        "n8n")
            echo -e "Setting up n8n...\n"
            docker compose-f /root/cluster-setup-script/docker_compose_files/n8n/docker-compose.yml up -d
            echo ""
            echo -e "\e[31m\e[1mIMPORTANT: Only the IP(s) you gave will be able to access the site until you create a user at the site\e[0m"
            local allowed_ips=$(cat /root/allowed_ips.txt)
            port_forwarding=5678
            echo -e "Setup done\n"
            ;;
        
        "illa")
            echo -e "Setting up illa...\n"
            port_forwarding=2022
            mkdir -p /home/devops/illa/database
            mkdir -p /home/devops/illa/drive
            docker compose -f /root/cluster-setup-script/docker_compose_files/illa/docker-compose.yml up -d
            echo ""
            echo -e "\e[31m\e[1mIMPORTANT: Only the IP(s) you gave will be able to access the site until you create a user at the site\e[0m"
            echo -e "\e[31m\e[1mIMPORTANT: Do you want to add new IPs to get acess to illa? (y/n) \e[0m"
            read -p "" choice
            if [ "$choice" == "y" ]; then
                echo -e "\e[31m\e[1mIMPORTANT: Enter the IPs separated by a space\e[0m"
                read -p "" ips
                sed -i "1s/^/$ips /" /root/allowed_ips.txt
            fi
            local allowed_ips=$(cat /root/allowed_ips.txt)
            echo -e "Setup done\n"
            ;;
        esac

        echo ""
        echo ""
        echo "--------------------------------SUBDOMAIN SETUP-----------------------------------"
        echo ""
        local allowed_ips=$(cat /root/allowed_ips.txt)
        read -p "Do you want the subdomain to be ${container_name} ? (y/n) " subdomain_choice
        if [ "$subdomain_choice" == "n" ]; then
            read -p "Enter the subdomain: " subdomain
            nginx_ct_setup "localhost" $port_forwarding $subdomain "/root/allowed_ips.txt"
            user_ct_setup $subdomain
        elif [ "$subdomain_choice" == "y" ]; then
            nginx_ct_setup "localhost" $port_forwarding $container_name "/root/allowed_ips.txt"
            user_ct_setup $container_name
        fi
    fi

    sleep 3
    fqdn="https://$subdomain.$dom"

    echo ""
    echo "--------------------CONTAINER SETUP DONE--------------------"
    echo ""
    case $container_name in
    "monitoring")
        echo "Your visual monitoring services are available at: "
        echo $fqdn
        echo "https://cadvisor.$dom"
        ;;
    *)
        echo "You can go to your site at: ${fqdn}"
        ;;
    esac
    echo ""
    echo -e "\e[33mThe container is ready but it might take a few moments to get the applications running\e[0m"
    echo ""
    echo "You can now run the script again to create another container"
    
    exit 0
}