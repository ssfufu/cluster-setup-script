# shellcheck shell=bash
# WireGuard VPN, configured natively (no third-party installer script).
# Clients are managed with: ./main.sh vpn add|remove|list|show <name>

WG_DIR=/etc/wireguard
WG_CONF=${WG_DIR}/wg0.conf

wireguard_setup() {
    section "WireGuard VPN"
    apt_install wireguard-tools qrencode

    if [[ -f $WG_CONF ]]; then
        warn "${WG_CONF} already exists; keeping it."
        WG_PORT=$(awk -F' *= *' '$1=="ListenPort"{print $2; exit}' "$WG_CONF")
        WG_ENABLED=yes
        [[ -n $WG_ENDPOINT ]] || WG_ENDPOINT=$PUBLIC_IP
        config_save
        install -m 0755 "${SCRIPT_DIR}/bin/cluster-wg" /usr/local/sbin/cluster-wg
        systemctl enable --now wg-quick@wg0.service >/dev/null 2>&1 || true
        return 0
    fi

    ask WG_PORT "WireGuard UDP port" "$WG_PORT" is_port
    ask WG_SUBNET "VPN subnet (/24)" "$WG_SUBNET" is_vpn_subnet
    ask WG_ENDPOINT "Public address clients connect to" "${WG_ENDPOINT:-$PUBLIC_IP}" is_host

    local prefix=${WG_SUBNET%.*} key
    install -d -m 0700 "$WG_DIR" "${WG_DIR}/clients"
    key=$(wg genkey)
    ( umask 077
      printf '%s\n' "$key" > "${WG_DIR}/server.key"
      wg pubkey <<<"$key" > "${WG_DIR}/server.pub"
      printf '# Managed by cluster-setup — clients are added with: ./main.sh vpn add <name>\n[Interface]\nAddress = %s.1/24\nListenPort = %s\nPrivateKey = %s\n' \
          "$prefix" "$WG_PORT" "$key" > "$WG_CONF" )
    unset key

    WG_ENABLED=yes
    config_save
    install -m 0755 "${SCRIPT_DIR}/bin/cluster-wg" /usr/local/sbin/cluster-wg
    systemctl enable --now wg-quick@wg0.service >/dev/null
    ok "WireGuard listening on UDP ${WG_PORT}, VPN subnet ${WG_SUBNET}."

    local client
    ask client "Name of the first VPN client (e.g. laptop)" "admin" is_label
    /usr/local/sbin/cluster-wg add "$client"
}

is_vpn_subnet() { [[ $1 =~ ^[0-9.]+\.0/24$ ]] && is_ipv4_cidr "$1"; }

wireguard_remove() {
    systemctl disable --now wg-quick@wg0.service >/dev/null 2>&1 || true
    rm -rf -- "${WG_DIR}/clients" "$WG_CONF" "${WG_DIR}/server.key" "${WG_DIR}/server.pub"
    rm -f /usr/local/sbin/cluster-wg
}
