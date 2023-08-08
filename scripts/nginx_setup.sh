#!/bin/bash
function nginx_setup() {
    echo ""
    echo ""
    echo "--------------------NGINX INSTALLATION--------------------"
    apt-get install nginx -y > /dev/null
    sleep 1
    systemctl enable nginx && systemctl start nginx
    snap install --classic certbot > /dev/null
    sleep 5
    ln -s /snap/bin/certbot /usr/bin/certbot
    ip_self=$(ip addr show wlo1 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    read -ra IPs <<< "$(cat /root/allowed_ips.txt)"

    rm /etc/nginx/nginx.conf
    cp /root/cluster-setup-script/nginx/nginx.conf /etc/nginx/nginx.conf
    sed -i "\|allow 127.0.0.1;|a \\\n\
                    allow $ip_self;" /etc/nginx/nginx.conf
    sed -i "\|allow $ip_self;|a \\\n\
                    allow 10.128.151.0/24;" /etc/nginx/nginx.conf
    sed -i "\|allow 10.128.151.0/24;|a \\\n\
                    allow 10.128.152.0/24;" /etc/nginx/nginx.conf

    last_ip="10.128.152.0/24"
    for ip in "${IPs[@]}"; do
        sed -i "\|allow $last_ip;|a \\
                    allow $ip;" /etc/nginx/nginx.conf
        last_ip=$ip
    done




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