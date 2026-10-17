# shellcheck shell=bash
# SSH hardening through a drop-in file (the distribution's sshd_config is kept).

SSH_DROPIN=/etc/ssh/sshd_config.d/10-cluster-setup.conf

ssh_setup() {
    section "SSH"
    local home keyfile key password_auth=no
    home=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
    keyfile="${home}/.ssh/authorized_keys"
    install -d -m 0700 -o "$ADMIN_USER" -g "$ADMIN_USER" "${home}/.ssh"

    if [[ ! -s $keyfile ]]; then
        if [[ -s /root/.ssh/authorized_keys ]] && confirm "Copy root's authorized SSH keys to ${ADMIN_USER}?" y; then
            install -m 0600 -o "$ADMIN_USER" -g "$ADMIN_USER" /root/.ssh/authorized_keys "$keyfile"
        else
            while true; do
                ask_optional key "Paste a public SSH key for ${ADMIN_USER} (empty to skip)"
                [[ -z $key ]] && break
                if ssh-keygen -l -f /dev/stdin <<<"$key" >/dev/null 2>&1; then
                    printf '%s\n' "$key" >> "$keyfile"
                    chown "$ADMIN_USER:$ADMIN_USER" "$keyfile"
                    chmod 0600 "$keyfile"
                    break
                fi
                warn "This does not look like a valid public key."
            done
        fi
    fi

    if [[ ! -s $keyfile ]]; then
        warn "No SSH key for ${ADMIN_USER}: password login stays enabled."
        warn "Add a key later to ${keyfile}, then run ./main.sh setup-ssh to disable passwords."
        password_auth=yes
    fi

    render "${TEMPLATES_DIR}/ssh/10-cluster-setup.conf" \
        "SSH_PORT=${SSH_PORT}" "PASSWORD_AUTH=${password_auth}" \
        | write_file "$SSH_DROPIN" 0644

    if ! sshd -t; then
        rm -f "$SSH_DROPIN"
        die "The generated SSH configuration is invalid; it was removed and SSH was left unchanged."
    fi

    # Socket activation would ignore the Port directive.
    if systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
        systemctl disable --now ssh.socket >/dev/null 2>&1 || true
        systemctl enable ssh.service >/dev/null 2>&1 || true
    fi
    systemctl restart ssh.service
    ok "SSH now listens on port ${SSH_PORT} (root login disabled, password login: ${password_auth})."
}
