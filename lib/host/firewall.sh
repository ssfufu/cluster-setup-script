# shellcheck shell=bash
# nftables firewall in its own table, so Docker's rules are never flushed.
#
# input   : default drop; web open; SSH only from the allow-list and the VPN;
#           exporters (node, nginx, cAdvisor) only from the LXC bridges.
# forward : no new connection from outside into the LXC bridges, and no
#           traffic between the two bridges (DMZ and DMZ2 stay isolated).
# nat     : masquerade LXC bridges and VPN clients behind the public interface.

FW_FILE=${CONF_DIR}/firewall.nft
FW_UNIT=/etc/systemd/system/cluster-firewall.service
EXPORTER_PORTS="9100, 9113, 8899"

_nft_elements() {
    # _nft_elements <4|6> <list...> — comma-separated addresses of one family
    local family=$1 item out=()
    shift
    for item in "$@"; do
        if [[ $family == 4 ]] && is_ipv4_cidr "$item"; then out+=("$item"); fi
        if [[ $family == 6 ]] && is_ipv6_cidr "$item"; then out+=("$item"); fi
    done
    local IFS=,
    printf '%s' "${out[*]}"
}

_nft_set_elements() {
    if [[ -n $1 ]]; then printf '        elements = { %s }\n' "$1"; fi
}

_nft_wg_rules() {
    if [[ $WG_ENABLED == yes ]]; then
        printf '        udp dport %s accept\n' "$WG_PORT"
        printf '        iifname "wg0" accept\n'
    fi
}

firewall_render() {
    local admin4 admin6 br subnets=() bridges_q=() wan=${WAN_IFACE}
    # shellcheck disable=SC2086
    admin4=$(_nft_elements 4 $ALLOWED_IPS)
    # shellcheck disable=SC2086
    admin6=$(_nft_elements 6 $ALLOWED_IPS)
    for br in "${BRIDGES[@]}"; do
        subnets+=("$(bridge_subnet "$br")")
        bridges_q+=("\"${br}\"")
    done
    [[ $WG_ENABLED == yes ]] && subnets+=("$WG_SUBNET")
    local IFS=,
    local subnet_list="${subnets[*]}" bridge_list="${bridges_q[*]}"
    unset IFS

    cat <<EOF
#!/usr/sbin/nft -f
# Managed by cluster-setup — regenerate with: ./main.sh firewall
table inet cluster_fw {}
delete table inet cluster_fw

table inet cluster_fw {
    set admin_v4 {
        type ipv4_addr
        flags interval
        auto-merge
$(_nft_set_elements "$admin4")
    }
    set admin_v6 {
        type ipv6_addr
        flags interval
        auto-merge
$(_nft_set_elements "$admin6")
    }

    chain input {
        type filter hook input priority filter; policy drop;
        ct state established,related accept
        ct state invalid drop
        iif "lo" accept
        meta l4proto icmp accept
        meta l4proto ipv6-icmp accept
        udp dport 546 ip6 saddr fe80::/10 accept
        tcp dport { 80, 443 } accept
        tcp dport ${SSH_PORT} ip saddr @admin_v4 accept
        tcp dport ${SSH_PORT} ip6 saddr @admin_v6 accept
$(_nft_wg_rules)
        iifname { ${bridge_list} } tcp dport { ${EXPORTER_PORTS} } accept
    }

    chain forward {
        type filter hook forward priority filter; policy accept;
$( for br in "${BRIDGES[@]}"; do
    printf '        oifname "%s" ct state new iifname != { "%s", "wg0" } drop\n' "$br" "$br"
done )
    }

    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oifname "${wan}" ip saddr { ${subnet_list} } masquerade
    }
}
EOF
}

firewall_apply() {
    section "Firewall"
    [[ -n $WAN_IFACE ]] || WAN_IFACE=$(detect_wan_iface)
    [[ -n $WAN_IFACE ]] || die "Could not detect the public network interface."

    local client tmp
    client=$(current_ssh_client_ip)
    if [[ -n $client ]] && ! ip_in_list "$client" "$ALLOWED_IPS"; then
        warn "Your current SSH client (${client}) is not in the allow-list (${ALLOWED_IPS})."
        warn "Your current session stays open, but new SSH connections from it will be refused."
        confirm "Apply the firewall anyway?" n || die "Aborted. Add your IP with: ./main.sh allow ${client}"
    fi

    install -d -m 0700 "$CONF_DIR"
    tmp=$(mktemp)
    firewall_render > "$tmp"
    if ! nft -c -f "$tmp"; then
        rm -f "$tmp"
        die "The generated firewall rules are invalid; nothing was changed."
    fi
    install -m 0600 "$tmp" "$FW_FILE"
    rm -f "$tmp"

    write_file "$FW_UNIT" 0644 <<EOF
[Unit]
Description=cluster-setup firewall (nftables table inet cluster_fw)
DefaultDependencies=no
Before=network-pre.target
Wants=network-pre.target
After=nftables.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f ${FW_FILE}
ExecReload=/usr/sbin/nft -f ${FW_FILE}
ExecStop=/usr/sbin/nft delete table inet cluster_fw

[Install]
WantedBy=sysinit.target
EOF
    systemctl daemon-reload
    systemctl enable cluster-firewall.service >/dev/null 2>&1
    systemctl restart cluster-firewall.service

    if systemctl is-enabled --quiet nftables.service 2>/dev/null && grep -q 'flush ruleset' /etc/nftables.conf 2>/dev/null; then
        warn "nftables.service is enabled and /etc/nftables.conf contains 'flush ruleset'."
        warn "Restarting it would wipe Docker's rules; consider: systemctl disable nftables"
    fi
    local from=$ALLOWED_IPS
    [[ $WG_ENABLED == yes ]] && from+=" + VPN"
    ok "Firewall applied (SSH port ${SSH_PORT} allowed from: ${from})."
}

firewall_remove() {
    systemctl disable --now cluster-firewall.service >/dev/null 2>&1 || true
    nft delete table inet cluster_fw 2>/dev/null || true
    rm -f "$FW_UNIT" "$FW_FILE"
    systemctl daemon-reload
}

# ip_in_list <ip> <list> — exact match or IPv4 CIDR containment
ip_in_list() {
    local ip=$1 item
    for item in $2; do
        [[ $ip == "$item" ]] && return 0
        if [[ $item == */* ]] && is_ipv4 "$ip" && is_ipv4_cidr "$item"; then
            ipv4_in_cidr "$ip" "$item" && return 0
        fi
    done
    return 1
}

ipv4_to_int() {
    local a b c d
    IFS=. read -r a b c d <<<"$1"
    printf '%d' "$(( (a << 24) | (b << 16) | (c << 8) | d ))"
}

ipv4_in_cidr() {
    local ip net mask bits=${2#*/}
    ip=$(ipv4_to_int "$1")
    net=$(ipv4_to_int "${2%/*}")
    mask=$(( bits == 0 ? 0 : (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
    (( (ip & mask) == (net & mask) ))
}
