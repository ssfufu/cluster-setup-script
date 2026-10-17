# shellcheck shell=bash
# Removes everything this project created. Installed packages are kept.

reset_server() {
    section "Reset"
    warn "This will permanently delete:"
    warn "  - every instance created with this tool (LXC containers, Docker stacks) and THEIR DATA"
    warn "  - nginx sites and certificates, firewall, SSH hardening, LXC bridges"
    warn "  - the VPN (optional), backup schedule and settings in ${CONF_DIR}"
    warn "Packages stay installed. Remote backups are not touched."
    local answer
    answer=$(_read_line "Type RESET to continue: ")
    [[ $answer == RESET ]] || { info "Aborted."; return 0; }

    if [[ -f ${CONF_DIR}/restic.password ]]; then
        warn "The backup encryption password is about to be deleted: ${CONF_DIR}/restic.password"
        warn "Existing backups can only be restored with it."
        confirm "Have you kept a copy of it?" n || { info "Copy it, then run the reset again."; return 0; }
    fi

    local inst
    for inst in $(app_instances); do
        (
            app_load "$inst"
            info "Removing ${inst}..."
            if [[ $APP_KIND == lxc ]]; then lxc_destroy "$inst"; else stack_remove "$inst"; fi
            nginx_site_remove "$inst" "$APP_FQDN"
        )
    done
    command -v docker >/dev/null && stack_remove cadvisor

    info "Removing nginx configuration..."
    rm -f /etc/nginx/conf.d/cluster.conf /etc/nginx/snippets/cluster-*.conf \
        /etc/nginx/sites-enabled/cluster-default /etc/nginx/sites-available/cluster-default \
        /etc/letsencrypt/renewal-hooks/deploy/reload-nginx
    if [[ -f /etc/nginx/sites-available/default ]]; then
        ln -sfn /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
    fi
    if command -v nginx >/dev/null && nginx -t 2>/dev/null; then systemctl reload nginx || true; fi

    info "Removing timers..."
    local unit
    for unit in cluster-backup cluster-docker-update; do
        systemctl disable --now "${unit}.timer" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/${unit}.timer" "/etc/systemd/system/${unit}.service" "/usr/local/sbin/${unit}"
    done

    if [[ -f /etc/wireguard/wg0.conf ]] && confirm "Remove the WireGuard VPN and all client configurations?" y; then
        wireguard_remove
    fi

    info "Restoring default SSH settings (port 22, password login)..."
    rm -f "$SSH_DROPIN"
    if sshd -t; then systemctl restart ssh.service; fi

    info "Removing firewall, bridges and kernel settings..."
    firewall_remove
    network_remove
    rm -f /etc/sysctl.d/90-cluster-setup.conf
    sysctl -q --system || true

    rm -rf -- "$CONF_DIR" "$DATA_DIR"
    systemctl daemon-reload

    ok "Reset done. SSH is back on port 22. Run ./main.sh setup to start again."
}
