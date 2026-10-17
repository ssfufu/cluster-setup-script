# shellcheck shell=bash
# Full host setup. Safe to run again: existing settings are offered as defaults.

setup_host() {
    section "System setup"
    config_migrate_legacy

    local client vpn_default=n
    ask DOMAIN "Main domain (apps will be <name>.<domain>)" "$DOMAIN" is_domain
    DOMAIN=${DOMAIN,,}
    ask EMAIL "E-mail for Let's Encrypt notices" "$EMAIL" is_email

    [[ -n $PUBLIC_IP ]] || PUBLIC_IP=$(detect_public_ip)
    ask PUBLIC_IP "Public IPv4 address of this server" "$PUBLIC_IP" is_ipv4
    WAN_IFACE=$(detect_wan_iface)
    [[ -n $WAN_IFACE ]] || ask WAN_IFACE "Public network interface" "" is_identifier

    client=$(current_ssh_client_ip)
    if [[ -z $ALLOWED_IPS && -n $client ]]; then
        ALLOWED_IPS=$client
        info "Your current IP (${client}) is suggested for the allow-list."
    fi
    info "The allow-list grants SSH access and access to restricted sites (IPs or CIDR, space separated)."
    ask ALLOWED_IPS "Allowed IPs" "$ALLOWED_IPS" is_ip_list

    ask ADMIN_USER "Administrator account" "$ADMIN_USER" is_username
    ask SSH_PORT "SSH port" "$SSH_PORT" is_port
    ask CT_RELEASE "Debian release for new LXC containers (bookworm/trixie)" "$CT_RELEASE" is_debian_release

    [[ $WG_ENABLED == yes ]] && vpn_default=y
    local want_vpn=no
    confirm "Set up a WireGuard VPN?" "$vpn_default" && want_vpn=yes

    config_save

    base_setup
    network_setup
    lxc_setup
    docker_setup
    nginx_setup
    exporters_setup
    if [[ $want_vpn == yes ]]; then
        wireguard_setup
        nginx_write_allowlist
        nginx_reload
    fi
    ssh_setup
    firewall_apply
    updates_setup

    if [[ -f $BACKUP_ENV ]] || confirm "Configure backups now?" y; then
        backup_setup
    fi

    section "Setup complete"
    local home
    home=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
    warn "Before closing this session, check in a NEW terminal that this works:"
    printf '\n    ssh -p %s %s@%s\n\n' "$SSH_PORT" "$ADMIN_USER" "$PUBLIC_IP" >&2
    [[ $WG_ENABLED == yes ]] && info "Through the VPN: ssh -p ${SSH_PORT} ${ADMIN_USER}@${WG_SUBNET%.*}.1"
    [[ -s ${home}/.ssh/authorized_keys ]] || warn "No SSH key installed for ${ADMIN_USER}: password login is still enabled."
    app_exists cadvisor && info "cAdvisor: https://cadvisor.${DOMAIN} (allow-list only)"
    info "Next step: ./main.sh create   (list of applications: ./main.sh list)"
}

is_debian_release() { [[ $1 =~ ^(bookworm|trixie|forky)$ ]]; }

# allow-list management
allowlist_add() {
    local ip
    config_require
    for ip in "$@"; do
        is_ip_or_cidr "$ip" || die "Invalid address: ${ip}"
        ip_in_list "$ip" "$ALLOWED_IPS" && continue
        ALLOWED_IPS="${ALLOWED_IPS:+$ALLOWED_IPS }${ip}"
    done
    allowlist_apply
}

allowlist_remove() {
    local ip new='' item
    config_require
    for item in $ALLOWED_IPS; do
        for ip in "$@"; do [[ $item == "$ip" ]] && continue 2; done
        new="${new:+$new }${item}"
    done
    [[ -n $new || $WG_ENABLED == yes ]] || die "Refusing to empty the allow-list without a VPN (you would lose SSH access)."
    ALLOWED_IPS=$new
    allowlist_apply
}

allowlist_apply() {
    config_save
    nginx_write_allowlist
    nginx_reload
    firewall_apply
    ok "Allow-list: ${ALLOWED_IPS:-(empty)}"
}
