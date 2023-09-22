#!/bin/bash
function nginx_ct_setup() {
    # Get parameters
    CT_IP="$1"
    CT_PORT="$2"
    CT_NAME="$3"
    ALLOWED_IPS_PATH="$4"
    DOMAIN="$(cat /root/domain.txt)"
    MAIL="$(cat /root/mail.txt)"

    # Get the server's IP address and the VPN's IP range and add it to the allowed IPs
    SERVER_IP=$(curl -s ifconfig.me)
    wg_dir="/etc/wireguard"
    if [ -d "$wg_dir" ]; then
        # check if the file /root/wgip exists
        if [ ! -f "/root/wgip" ]; then
            touch /root/wgip
            echo $(ip addr show wg0 | grep 'inet ' | grep -v ':' | awk '{print $2}' | sed 's/\([0-9]\+\.[0-9]\+\.[0-9]\+\.\)[0-9]\+/\10/' ) > /root/wgip
        fi
        wgip=$(cat /root/wgip)
        if ! grep -q "$wgip" /root/allowed_ips.txt; then
            sed -i "1s|\$| ${SERVER_IP} ${wgip}|" "${ALLOWED_IPS_PATH}"
        fi
    elif [ ! -d "$wg_dir" ]; then
        sed -i "1s|$| ${SERVER_IP}|" "${ALLOWED_IPS_PATH}"
    fi

    # construct server_name and proxy_pass
    SERVER_NAME="${CT_NAME}.${DOMAIN}"
    PROXY_PASS="http://${CT_IP}:${CT_PORT}"
    PROXY_REDIRECT="http://${CT_IP}:${CT_PORT} https://${SERVER_NAME}"
    dir_path="/etc/letsencrypt/live/${SERVER_NAME}"

    # deletes the file if already exists
    rm /etc/nginx/sites-available/$CT_NAME /etc/nginx/sites-enabled/$CT_NAME &> /dev/null

    # creates a file for this site
    touch /etc/nginx/sites-available/${CT_NAME} &> /dev/null

    # substitute placeholders with variable values in the template and create a new config file
    sed -e "s|server_name|server_name ${SERVER_NAME};|g" \
        -e "s|proxy_set_header Host|proxy_set_header Host ${SERVER_NAME};|g" \
        -e "s|proxy_pass|proxy_pass ${PROXY_PASS};|g" \
        -e "s|proxy_redirect|proxy_redirect ${PROXY_REDIRECT};|g" \
        -e "s|/etc/letsencrypt/live/|/etc/letsencrypt/live/${SERVER_NAME}/|g" \
        -e "s|if (\$host = )|if (\$host = ${SERVER_NAME})|g" \
        -e "/location \/ {/a deny all;" /root/cluster-setup-script/nginx/nginx-config > "/etc/nginx/sites-available/${CT_NAME}"

    # Add the allowed IPs
    ALLOWED_IPS="$(cat $ALLOWED_IPS_PATH)"
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

    if [ "$CT_NAME" = "chatwoot" ]; then
        sed -i '/add_header Strict-Transport-Security "max-age=15552000; includeSubDomains; preload";/a set $upstream 127.0.0.1:3000;' /etc/nginx/sites-available/chatwoot
    fi
    ln -s /etc/nginx/sites-available/${CT_NAME} /etc/nginx/sites-enabled/ &> /dev/null

    if [ -d "$dir_path" ]; then
        echo "There already is a certificate for that."
    else
        systemctl stop nginx

        certbot certonly --standalone -d ${SERVER_NAME} --email ${MAIL} --agree-tos --no-eff-email --noninteractive --force-renewal
        
        systemctl start nginx
    fi

    systemctl restart nginx.service

}
