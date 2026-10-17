# shellcheck shell=bash
# ownCloud Infinite Scale (oCIS). ownCloud 10 needs PHP 7.4, which is not
# available on current Debian releases; oCIS is its maintained successor.

app_ocis_install() {
    local dir password
    dir=$(stack_dir "$INSTANCE")
    ask_secret password "oCIS admin password (user: admin)" 12
    {
        printf 'HOST_PORT=%s\nFQDN=%s\n' "$HOST_PORT" "$FQDN"
        env_kv OCIS_ADMIN_PASSWORD "$password"
    } | stack_env "$INSTANCE"
    # The image runs as UID 1000.
    install -d -m 0700 -o 1000 -g 1000 "${dir}/config" "${dir}/data"
    save_credential "$INSTANCE" "oCIS user" "admin"
    save_credential "$INSTANCE" "oCIS password" "$password"
    stack_up "$INSTANCE"
    info "oCIS checks its own URL at start-up: it becomes fully usable once https://${FQDN} has its certificate."
}
