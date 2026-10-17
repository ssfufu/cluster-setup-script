# shellcheck shell=bash
# Tolgee from the official image (the old setup needed Java 11, which is no
# longer packaged by Debian). Bundled PostgreSQL or an existing server.

app_tolgee_install() {
    local dir admin_user admin_password db_host=db db_port=5432 db_name=tolgee db_user=tolgee db_password profile=localdb
    dir=$(stack_dir "$INSTANCE")

    if confirm "Use a bundled PostgreSQL database? (n = existing server)" y; then
        db_password=$(gen_secret 32)
    else
        profile=''
        info "Use host.docker.internal to reach a database running on this host."
        ask db_host "Database host" "" is_host_or_docker
        ask db_port "Database port" "5432" is_port
        ask db_name "Database name" "tolgee" is_identifier
        ask db_user "Database user" "tolgee" is_identifier
        ask_secret db_password "Database password" 1
    fi
    ask admin_user "Tolgee admin login" "admin" is_username
    ask_secret admin_password "Tolgee admin password" 12

    {
        printf 'HOST_PORT=%s\nFQDN=%s\n' "$HOST_PORT" "$FQDN"
        printf 'COMPOSE_PROFILES=%s\n' "$profile"
        printf 'DB_HOST=%s\nDB_PORT=%s\nDB_NAME=%s\nDB_USER=%s\n' "$db_host" "$db_port" "$db_name" "$db_user"
        env_kv DB_PASSWORD "$db_password"
        printf 'TOLGEE_ADMIN_USER=%s\n' "$admin_user"
        env_kv TOLGEE_ADMIN_PASSWORD "$admin_password"
        printf 'TOLGEE_JWT_SECRET=%s\n' "$(gen_secret 64)"
    } | stack_env "$INSTANCE"
    install -d -m 0750 "${dir}/data"
    [[ -n $profile ]] && install -d -m 0700 "${dir}/postgres"

    save_credential "$INSTANCE" "Tolgee user" "$admin_user"
    save_credential "$INSTANCE" "Tolgee password" "$admin_password"
    stack_up "$INSTANCE"
}

is_host_or_docker() { [[ $1 == host.docker.internal ]] || is_host "$1"; }
