#!/bin/bash
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
    echo "-------------------------- ${SERVER_IP} --------------------------"
    # check if there is a wireguard interface
    wg_dir="/etc/wireguard"
    if [ -d "$wg_dir" ]; then
        touch /root/wgip
        echo $(ip addr show wg0 | grep inet | awk '{print $2}' | sed 's/\([0-9]\+\.[0-9]\+\.[0-9]\+\.\)[0-9]\+/\10/' ) >> /root/wgip
        local wgip=$(cat /root/wgip)
        ALLOWED_IPS="$ALLOWED_IPS $SERVER_IP ${wgip}/24"
    else
        ALLOWED_IPS="$ALLOWED_IPS $SERVER_IP"
        echo ""
        echo ""
        echo "--------------------------------------------------------------------"
        echo "-------------------------- ${ALLOWED_IPS} --------------------------"
        echo "--------------------------------------------------------------------"
        echo ""
        echo ""
    fi

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
    if [ "$CT_NAME" = "monitoring" ] || [ "$CT_NAME" = "tolgee" ] || [ "$CT_NAME" = "nextcloud" ] || [ "$CT_NAME" = "owncloud" ] || [ "$CT_NAME" = "react" ] || [ "$CT_NAME" = "n8n" ]; then
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