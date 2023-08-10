#!/bin/bash
function user_ct_setup () {

    local subdomain="$1"
    local dom="$(cat /root/domain.txt)"

    echo ""
    echo "You can create a user at the site by going to https://${subdomain}.$dom"
    echo ""
    echo ""
    echo "------------------------------------------------------------"
    read -p "Have you created a user at the site? (y/n) " user_created
    echo "------------------------------------------------------------"
    echo ""
    if [ "$user_created" == "n" ]; then
        echo "You can create a user at the site by going to https://${subdomain}.$dom"
    else
        sed -i 's/deny all/allow all/g' /etc/nginx/sites-available/${subdomain}
        rm /etc/nginx/sites-enabled/${subdomain}
        ln -s /etc/nginx/sites-available/${subdomain} /etc/nginx/sites-enabled/
        systemctl restart nginx.service
        sleep 2
    fi
}