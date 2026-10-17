# shellcheck shell=bash
# Nextcloud on Apache + PHP from Debian (no third-party PHP repository),
# MariaDB, Redis (file locking), APCu (local cache) and systemd cron.
# Fully installed by the script: no web installer exposed to the Internet.

app_nextcloud_install() {
    local ct=$INSTANCE php db_password admin_user admin_password
    ct_apt_install "$ct" apache2 libapache2-mod-php mariadb-server redis-server \
        php-cli php-gd php-mysql php-curl php-mbstring php-intl php-xml php-zip \
        php-bcmath php-gmp php-bz2 php-apcu php-redis php-imagick bzip2

    php=$(ct_exec "$ct" php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
    info "PHP ${php} detected."
    ct_write "$ct" "/etc/php/${php}/apache2/conf.d/90-nextcloud.ini" 0644 < "${TEMPLATES_DIR}/nextcloud/php.ini"
    ct_write "$ct" "/etc/php/${php}/cli/conf.d/90-nextcloud.ini" 0644 < "${TEMPLATES_DIR}/nextcloud/php.ini"

    # Database (random password, only used by Nextcloud itself).
    db_password=$(gen_secret 32)
    printf "CREATE DATABASE IF NOT EXISTS nextcloud CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS 'nextcloud'@'localhost' IDENTIFIED BY '%s';
GRANT ALL PRIVILEGES ON nextcloud.* TO 'nextcloud'@'localhost';
FLUSH PRIVILEGES;\n" "$db_password" | ct_exec "$ct" mariadb

    # Download and verify the release.
    info "Downloading Nextcloud..."
    ct_sh "$ct" '
        cd /tmp
        curl -fsSLO --proto "=https" https://download.nextcloud.com/server/releases/latest.tar.bz2
        curl -fsSLO --proto "=https" https://download.nextcloud.com/server/releases/latest.tar.bz2.sha256
        sha256sum -c latest.tar.bz2.sha256
        tar -xjf latest.tar.bz2 -C /var/www
        rm -f latest.tar.bz2 latest.tar.bz2.sha256
        chown -R www-data:www-data /var/www/nextcloud
        install -d -m 0750 -o www-data -g www-data /srv/nextcloud-data
    '

    render "${TEMPLATES_DIR}/nextcloud/apache.conf" "FQDN=${FQDN}" \
        | ct_write "$ct" /etc/apache2/sites-available/nextcloud.conf 0644
    printf 'ServerName %s\n' "$INSTANCE" | ct_write "$ct" /etc/apache2/conf-available/servername.conf 0644
    ct_sh "$ct" '
        a2enmod -q rewrite headers env dir mime setenvif >/dev/null
        a2enconf -q servername >/dev/null
        a2dissite -q 000-default >/dev/null || true
        a2ensite -q nextcloud >/dev/null
        systemctl restart apache2
    '

    ask admin_user "Nextcloud admin login" "admin" is_username
    ask_secret admin_password "Nextcloud admin password" 12

    info "Running the Nextcloud installer..."
    ct_exec "$ct" runuser -u www-data -- php /var/www/nextcloud/occ maintenance:install \
        --database mysql --database-host localhost --database-name nextcloud \
        --database-user nextcloud --database-pass "$db_password" \
        --admin-user "$admin_user" --admin-pass "$admin_password" \
        --data-dir /srv/nextcloud-data >/dev/null

    # shellcheck disable=SC2016 # expanded inside the container
    ct_sh "$ct" '
        occ() { runuser -u www-data -- php /var/www/nextcloud/occ "$@" >/dev/null; }
        occ config:system:set trusted_domains 1 --value="$1"
        occ config:system:set overwrite.cli.url --value="https://$1"
        occ config:system:set overwriteprotocol --value=https
        occ config:system:set overwritehost --value="$1"
        occ config:system:set trusted_proxies 0 --value="$2"
        occ config:system:set memcache.local --value="\OC\Memcache\APCu"
        occ config:system:set memcache.locking --value="\OC\Memcache\Redis"
        occ config:system:set redis host --value=localhost
        occ config:system:set redis port --value=6379 --type=integer
        occ config:system:set maintenance_window_start --value=1 --type=integer
        occ config:system:set htaccess.RewriteBase --value=/
        occ maintenance:update:htaccess
        occ db:add-missing-indices
        occ background:cron
    ' "$FQDN" "$CT_GATEWAY"

    # Background jobs every 5 minutes.
    ct_write "$ct" /etc/systemd/system/nextcloud-cron.service 0644 <<'EOF'
[Unit]
Description=Nextcloud background jobs

[Service]
Type=oneshot
User=www-data
ExecStart=/usr/bin/php -f /var/www/nextcloud/cron.php
EOF
    ct_write "$ct" /etc/systemd/system/nextcloud-cron.timer 0644 <<'EOF'
[Unit]
Description=Run Nextcloud background jobs every 5 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF
    ct_exec "$ct" systemctl daemon-reload
    ct_exec "$ct" systemctl enable --now nextcloud-cron.timer >/dev/null 2>&1
    ct_exec "$ct" systemctl restart apache2

    save_credential "$INSTANCE" "Nextcloud user" "$admin_user"
    save_credential "$INSTANCE" "Nextcloud password" "$admin_password"
    save_credential "$INSTANCE" "MariaDB nextcloud password" "$db_password"
    info "Nextcloud upgrades: run 'occ update:check' and the updater from the admin panel."
}
