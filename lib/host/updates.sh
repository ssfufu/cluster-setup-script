# shellcheck shell=bash
# Automatic updates:
#   - host and containers: Debian security updates via unattended-upgrades
#   - Docker stacks: weekly image pull + recreate (systemd timer)

updates_setup() {
    section "Automatic updates"
    install -m 0755 "${SCRIPT_DIR}/bin/cluster-docker-update" /usr/local/sbin/cluster-docker-update
    install -m 0644 "${TEMPLATES_DIR}/systemd/cluster-docker-update.service" /etc/systemd/system/
    install -m 0644 "${TEMPLATES_DIR}/systemd/cluster-docker-update.timer" /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable --now cluster-docker-update.timer >/dev/null
    ok "Docker stacks are updated every Sunday (touch <stack>/.no-auto-update to opt out)."
}

# Manual full update: host, every LXC container, every Docker stack.
update_all() {
    section "Updating the host"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y -o Dpkg::Options::=--force-confold

    local ct
    if command -v lxc-ls >/dev/null; then
        for ct in $(lxc-ls --running); do
            section "Updating container ${ct}"
            ct_exec "$ct" apt-get update -qq
            ct_exec "$ct" apt-get full-upgrade -y -o Dpkg::Options::=--force-confold
        done
    fi

    if [[ -x /usr/local/sbin/cluster-docker-update ]]; then
        section "Updating Docker stacks"
        /usr/local/sbin/cluster-docker-update || warn "Some stacks could not be updated."
    fi
    [[ -f /run/reboot-required ]] && warn "A reboot is required to finish the update."
    return 0
}
