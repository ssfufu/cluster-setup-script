# shellcheck shell=bash
# Backups with restic: encrypted, deduplicated, verified, with retention.
# Replaces the old tar + plain FTP script (password stored in clear text).

BACKUP_ENV=${CONF_DIR}/backup.env
RESTIC_PASS_FILE=${CONF_DIR}/restic.password
BACKUP_SSH_KEY=/root/.ssh/cluster-backup_ed25519

backup_setup() {
    section "Backups (restic)"
    apt_install restic openssh-client

    if [[ -f $BACKUP_ENV ]] && ! confirm "A backup configuration already exists. Replace it?" n; then
        return 0
    fi

    local kind repo host user port path endpoint bucket key_id secret
    local -a extra=()
    choose kind "Where should backups be stored?" \
        "SFTP server (any SSH server)" \
        "S3-compatible object storage" \
        "restic REST server" \
        "Local path or mounted disk" \
        "Other restic repository (rclone:..., etc.)"

    case $kind in
        SFTP*)
            ask host "SFTP host" "" is_host
            ask user "SFTP user" "" is_username
            ask port "SSH port" "22" is_port
            ask path "Remote directory" "backups/$(hostname)"
            backup_ssh_setup "$host" "$user" "$port"
            repo="sftp:cluster-backup:${path}"
            ;;
        S3*)
            ask endpoint "Endpoint URL (e.g. https://s3.eu-west-3.amazonaws.com)" ""
            ask bucket "Bucket and optional prefix (e.g. my-bucket/server1)" ""
            ask key_id "Access key ID" ""
            ask_secret secret "Secret access key" 1
            repo="s3:${endpoint%/}/${bucket}"
            extra+=("AWS_ACCESS_KEY_ID=${key_id}" "AWS_SECRET_ACCESS_KEY=${secret}")
            ;;
        restic*)
            ask repo "REST URL (e.g. rest:https://user:pass@backup.example.com:8000/server1)" ""
            ;;
        Local*)
            ask path "Absolute path" "/mnt/backup/restic"
            install -d -m 0700 "$path"
            repo=$path
            ;;
        *)
            ask repo "restic repository string" ""
            ;;
    esac

    local keep_daily keep_weekly keep_monthly stop=yes
    ask keep_daily "Daily snapshots to keep" "7" is_uint
    ask keep_weekly "Weekly snapshots to keep" "4" is_uint
    ask keep_monthly "Monthly snapshots to keep" "6" is_uint
    confirm "Stop containers during the backup (consistent databases, a few minutes of downtime)?" y || stop=no

    if [[ ! -s $RESTIC_PASS_FILE ]]; then
        gen_secret 40 | write_file "$RESTIC_PASS_FILE" 0600
    fi

    {
        printf '# Managed by cluster-setup\n'
        printf 'RESTIC_REPOSITORY=%q\n' "$repo"
        printf 'RESTIC_PASSWORD_FILE=%q\n' "$RESTIC_PASS_FILE"
        printf 'KEEP_DAILY=%q\nKEEP_WEEKLY=%q\nKEEP_MONTHLY=%q\n' "$keep_daily" "$keep_weekly" "$keep_monthly"
        printf 'BACKUP_STOP_SERVICES=%q\n' "$stop"
        local kv
        for kv in "${extra[@]}"; do printf '%s=%q\n' "${kv%%=*}" "${kv#*=}"; done
    } | write_file "$BACKUP_ENV" 0600

    info "Initialising the repository..."
    if ! backup_restic snapshots >/dev/null 2>&1; then
        backup_restic init
    fi

    install -m 0755 "${SCRIPT_DIR}/bin/cluster-backup" /usr/local/sbin/cluster-backup
    install -m 0644 "${TEMPLATES_DIR}/systemd/cluster-backup.service" /etc/systemd/system/
    install -m 0644 "${TEMPLATES_DIR}/systemd/cluster-backup.timer" /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable --now cluster-backup.timer >/dev/null
    ok "Daily backup scheduled at 02:00 (systemctl list-timers cluster-backup.timer)."

    warn "The repository encryption password is in ${RESTIC_PASS_FILE}."
    warn "Without it, backups CANNOT be restored: keep a copy somewhere else (password manager)."
    if confirm "Display it now?" n; then
        # Written to the terminal only, so it never lands in the log file.
        printf '\n    %s\n\n' "$(<"$RESTIC_PASS_FILE")" > /dev/tty
    fi
    if confirm "Run a first backup now?" n; then
        systemctl start cluster-backup.service
        ok "Backup done. Logs: journalctl -u cluster-backup"
    fi
}

backup_ssh_setup() {
    local host=$1 user=$2 port=$3
    install -d -m 0700 /root/.ssh
    if [[ ! -f $BACKUP_SSH_KEY ]]; then
        ssh-keygen -q -t ed25519 -N '' -C "cluster-backup@$(hostname)" -f "$BACKUP_SSH_KEY"
    fi
    # Dedicated host alias so restic and the key never mix with other SSH usage.
    touch /root/.ssh/config
    chmod 0600 /root/.ssh/config
    sed -i '/^# BEGIN cluster-backup$/,/^# END cluster-backup$/d' /root/.ssh/config
    printf '# BEGIN cluster-backup\nHost cluster-backup\n    HostName %s\n    User %s\n    Port %s\n    IdentityFile %s\n    IdentitiesOnly yes\n    ServerAliveInterval 60\n# END cluster-backup\n' \
        "$host" "$user" "$port" "$BACKUP_SSH_KEY" >> /root/.ssh/config

    info "Public key to authorise on ${host}:"
    printf '\n    %s\n\n' "$(<"${BACKUP_SSH_KEY}.pub")" >&2
    if confirm "Copy it now with ssh-copy-id (asks for ${user}'s password once)?" y; then
        ssh-copy-id -o StrictHostKeyChecking=accept-new -i "${BACKUP_SSH_KEY}.pub" -p "$port" "${user}@${host}"
    else
        info "Add it to ~${user}/.ssh/authorized_keys on ${host}, then press Enter."
        read -r _ || true
    fi
    ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new cluster-backup true \
        || die "Key-based SSH login to ${host} failed."
}

backup_restic() {
    ( set -a
      # shellcheck disable=SC1090
      source "$BACKUP_ENV"
      set +a
      restic "$@" )
}
