# shellcheck shell=bash
# Nginx reverse proxy, Let's Encrypt certificates (webroot, no downtime) and
# per-site access control (allow-list or public).

NGINX_SNIPPETS=/etc/nginx/snippets
ACME_ROOT=/var/www/letsencrypt

nginx_setup() {
    section "Nginx & Let's Encrypt"
    apt_install nginx certbot

    install -d -m 0755 "$ACME_ROOT" "$NGINX_SNIPPETS"
    install -m 0644 "${TEMPLATES_DIR}/nginx/cluster.conf" /etc/nginx/conf.d/cluster.conf
    install -m 0644 "${TEMPLATES_DIR}/nginx/cluster-ssl.conf" "${NGINX_SNIPPETS}/cluster-ssl.conf"
    install -m 0644 "${TEMPLATES_DIR}/nginx/cluster-proxy.conf" "${NGINX_SNIPPETS}/cluster-proxy.conf"
    install -m 0644 "${TEMPLATES_DIR}/nginx/cluster-acme.conf" "${NGINX_SNIPPETS}/cluster-acme.conf"
    nginx_write_allowlist

    # Catch-all default site (replaces Debian's welcome page).
    nginx_listen_vars
    render "${TEMPLATES_DIR}/nginx/default.conf" \
        "LISTEN6_80=${LISTEN6_80}" "LISTEN6_443=${LISTEN6_443}" \
        | write_file /etc/nginx/sites-available/cluster-default 0644
    rm -f /etc/nginx/sites-enabled/default
    ln -sfn /etc/nginx/sites-available/cluster-default /etc/nginx/sites-enabled/cluster-default

    # Reload nginx after each certificate renewal (certbot.timer handles renewals).
    write_file /etc/letsencrypt/renewal-hooks/deploy/reload-nginx 0755 <<'EOF'
#!/bin/sh
systemctl reload nginx
EOF

    nginx_reload
    systemctl enable --now nginx.service certbot.timer >/dev/null 2>&1
    ok "Nginx ready."
}

nginx_listen_vars() {
    local version
    if [[ -e /proc/net/if_inet6 ]]; then
        LISTEN6_80='listen [::]:80;'
        LISTEN6_443='listen [::]:443 ssl;'
    else
        LISTEN6_80='' LISTEN6_443=''
    fi
    # "http2 on;" exists since nginx 1.25.1 (Debian 13); older versions use the listen flag.
    version=$(nginx -v 2>&1 | sed -n 's|.*nginx/\([0-9.]*\).*|\1|p')
    if [[ -n $version ]] && [[ $(printf '%s\n1.25.1\n' "$version" | sort -V | head -n1) == 1.25.1 ]]; then
        HTTP2_LISTEN='' HTTP2_DIRECTIVE='http2 on;'
    else
        HTTP2_LISTEN=' http2' HTTP2_DIRECTIVE=''
    fi
}

nginx_reload() {
    if ! nginx -t 2>/dev/null; then
        nginx -t || true
        die "Nginx configuration test failed."
    fi
    if systemctl is-active --quiet nginx.service; then
        systemctl reload nginx.service
    else
        systemctl start nginx.service
    fi
}

# Addresses allowed on "restricted" sites: allow-list, VPN, the server itself.
nginx_write_allowlist() {
    local ip
    {
        echo "# Managed by cluster-setup — regenerated from ${CONF_FILE}"
        echo "allow 127.0.0.1;"
        echo "allow ::1;"
        [[ -n $PUBLIC_IP ]] && echo "allow ${PUBLIC_IP};"
        [[ $WG_ENABLED == yes ]] && echo "allow ${WG_SUBNET};"
        for ip in $ALLOWED_IPS; do echo "allow ${ip};"; done
    } | write_file "${NGINX_SNIPPETS}/cluster-allowlist.conf" 0644
}

nginx_write_access() {
    # nginx_write_access <name> <public|restricted>
    local name=$1 mode=$2
    case $mode in
        public)
            printf '# Managed by cluster-setup — public access\n' ;;
        restricted)
            printf '# Managed by cluster-setup — restricted to the allow-list\ninclude snippets/cluster-allowlist.conf;\ndeny all;\n' ;;
        *) die "Unknown access mode: ${mode}" ;;
    esac | write_file "${NGINX_SNIPPETS}/cluster-access-${name}.conf" 0644
}

# dns_points_here <fqdn> — true if the name resolves to the public IP
dns_points_here() {
    local addrs
    addrs=$(getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u || true)
    [[ -n $PUBLIC_IP ]] && grep -qxF "$PUBLIC_IP" <<<"$addrs"
}

cert_obtain() {
    local fqdn=$1
    if [[ -d /etc/letsencrypt/live/${fqdn} ]]; then
        info "A certificate for ${fqdn} already exists."
        return 0
    fi
    if ! dns_points_here "$fqdn"; then
        warn "${fqdn} does not resolve to ${PUBLIC_IP} (yet). Create the DNS record (A ${fqdn} -> ${PUBLIC_IP})."
        while ! dns_points_here "$fqdn"; do
            confirm "Check again? (n = try to get the certificate anyway)" y || break
        done
    fi
    info "Requesting a Let's Encrypt certificate for ${fqdn}..."
    certbot certonly --webroot -w "$ACME_ROOT" -d "$fqdn" \
        --email "$EMAIL" --agree-tos --no-eff-email --non-interactive \
        --key-type ecdsa \
        || die "Certificate request failed for ${fqdn}. Check DNS and that port 80 is reachable."
}

# nginx_site_create <name> <fqdn> <upstream-url> <public|restricted>
nginx_site_create() {
    local name=$1 fqdn=$2 upstream=$3 access=$4
    local avail="/etc/nginx/sites-available/cluster-${name}"
    cert_obtain "$fqdn"
    nginx_listen_vars
    nginx_write_access "$name" "$access"
    render "${TEMPLATES_DIR}/nginx/site.conf" \
        "NAME=${name}" "FQDN=${fqdn}" "UPSTREAM=${upstream}" \
        "LISTEN6_80=${LISTEN6_80}" "LISTEN6_443=${LISTEN6_443}" \
        "HTTP2_LISTEN=${HTTP2_LISTEN}" "HTTP2_DIRECTIVE=${HTTP2_DIRECTIVE}" \
        | write_file "$avail" 0644
    ln -sfn "$avail" "/etc/nginx/sites-enabled/cluster-${name}"
    if ! nginx -t 2>/dev/null; then
        rm -f "/etc/nginx/sites-enabled/cluster-${name}"
        nginx -t || true
        die "Nginx rejected the configuration for ${name}; the site was disabled."
    fi
    nginx_reload
    ok "https://${fqdn} -> ${upstream} (${access})"
}

nginx_site_set_access() {
    nginx_write_access "$1" "$2"
    nginx_reload
}

nginx_site_remove() {
    local name=$1 fqdn=${2-}
    rm -f "/etc/nginx/sites-enabled/cluster-${name}" "/etc/nginx/sites-available/cluster-${name}" \
        "${NGINX_SNIPPETS}/cluster-access-${name}.conf"
    if [[ -n $fqdn && -d /etc/letsencrypt/live/${fqdn} ]]; then
        certbot delete --cert-name "$fqdn" --non-interactive >/dev/null 2>&1 || true
    fi
}
