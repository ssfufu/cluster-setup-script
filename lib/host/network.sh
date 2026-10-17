# shellcheck shell=bash
# LXC bridges (DMZ, DMZ2) managed by systemd-networkd. Replaces the LXD snap
# that was only used to create these two bridges.

bridge_gateway() { local c=${BRIDGE_CIDR[$1]}; printf '%s' "${c%/*}"; }
bridge_prefix()  { local g; g=$(bridge_gateway "$1"); printf '%s' "${g%.*}"; }
bridge_subnet()  { printf '%s.0/24' "$(bridge_prefix "$1")"; }

network_setup() {
    section "LXC bridges"
    local br networkd_was_enabled=no
    systemctl is-enabled --quiet systemd-networkd.service 2>/dev/null && networkd_was_enabled=yes

    for br in "${BRIDGES[@]}"; do
        write_file "/etc/systemd/network/60-cluster-${br}.netdev" 0644 <<EOF
# Managed by cluster-setup
[NetDev]
Name=${br}
Kind=bridge
EOF
        write_file "/etc/systemd/network/60-cluster-${br}.network" 0644 <<EOF
# Managed by cluster-setup
[Match]
Name=${br}

[Link]
RequiredForOnline=no

[Network]
Address=${BRIDGE_CIDR[$br]}
ConfigureWithoutCarrier=yes
IgnoreCarrierLoss=yes
LinkLocalAddressing=no
IPv6AcceptRA=no
EOF
    done

    systemctl enable --now systemd-networkd.service >/dev/null 2>&1
    if [[ $networkd_was_enabled == no ]]; then
        # The main interface is managed by something else (ifupdown, ...):
        # waiting for networkd links at boot would only add a 2 min timeout.
        systemctl disable systemd-networkd-wait-online.service >/dev/null 2>&1 || true
    fi
    networkctl reload

    for br in "${BRIDGES[@]}"; do
        wait_for 30 "bridge ${br}" bridge_has_address "$br"
        ok "Bridge ${br} up with ${BRIDGE_CIDR[$br]}"
    done
}

bridge_has_address() {
    local addrs
    addrs=$(ip -4 -o addr show dev "$1" 2>/dev/null || true)
    [[ $addrs == *" $(bridge_gateway "$1")/"* ]]
}

network_remove() {
    local br
    for br in "${BRIDGES[@]}"; do
        rm -f "/etc/systemd/network/60-cluster-${br}.netdev" "/etc/systemd/network/60-cluster-${br}.network"
        ip link delete "$br" 2>/dev/null || true
    done
    networkctl reload 2>/dev/null || true
}
