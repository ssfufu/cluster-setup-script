# shellcheck shell=bash
# Base packages, admin account, kernel settings and automatic security updates.

base_setup() {
    section "Base system"
    apt_install ca-certificates curl gnupg jq openssl iproute2 nftables sudo git \
        unattended-upgrades apt-listchanges bzip2 rsync

    admin_user_setup

    info "Applying kernel network settings..."
    write_file /etc/sysctl.d/90-cluster-setup.conf 0644 <<'EOF'
# Managed by cluster-setup
# Routing for LXC bridges and WireGuard (must be set before Docker starts so
# Docker keeps the FORWARD policy untouched).
net.ipv4.ip_forward = 1
# Hardening
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
fs.protected_symlinks = 1
fs.protected_hardlinks = 1
EOF
    sysctl -q --system

    auto_upgrades_setup
    ok "Base system ready."
}

admin_user_setup() {
    local password
    if id "$ADMIN_USER" >/dev/null 2>&1; then
        info "User ${ADMIN_USER} already exists."
    else
        info "Creating administrator account ${ADMIN_USER}..."
        useradd --create-home --shell /bin/bash "$ADMIN_USER"
        ask_secret password "Password for ${ADMIN_USER} (used for sudo)" 12
        printf '%s:%s\n' "$ADMIN_USER" "$password" | chpasswd
        save_credential host "${ADMIN_USER} password" "$password"
        unset password
    fi
    usermod -aG sudo "$ADMIN_USER"
    groupadd -f sshusers
    usermod -aG sshusers "$ADMIN_USER"
}

auto_upgrades_setup() {
    info "Enabling automatic security updates (unattended-upgrades)..."
    write_file /etc/apt/apt.conf.d/20auto-upgrades 0644 <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
    systemctl enable --now unattended-upgrades.service >/dev/null 2>&1 || true
}

detect_public_ip() {
    local ip=''
    ip=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
    if ! is_ipv4 "$ip"; then
        ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<NF;i++) if ($i=="src") {print $(i+1); exit}}')
    fi
    printf '%s' "$ip"
}

detect_wan_iface() {
    ip -4 route show default 2>/dev/null | awk '{for (i=1;i<NF;i++) if ($i=="dev") {print $(i+1); exit}}'
}

# IP of the machine the current SSH session comes from, if any.
current_ssh_client_ip() {
    local client=${SSH_CONNECTION-${SSH_CLIENT-}}
    client=${client%% *}
    # sudo drops SSH_CONNECTION: fall back to the login record of this tty
    if [[ -z $client ]]; then
        client=$(who -m 2>/dev/null | sed -n 's/.*(\(.*\)).*/\1/p' || true)
    fi
    is_ip_or_cidr "$client" && printf '%s' "$client"
    return 0
}
