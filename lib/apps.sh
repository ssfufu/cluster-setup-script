# shellcheck shell=bash
# Application catalogue and the generic creation workflow.
#
# kind    : lxc (dedicated Debian container) or docker (compose stack)
# port    : port of the service (inside the container, or first host port tried)
# access  : initial nginx access mode
#             public     -> the app has its own login, admin created by the script
#             onboarding -> first visitor creates the admin account: the site
#                           stays restricted to the allow-list until you open it

declare -A CAT_KIND=(
    [monitoring]=lxc [nextcloud]=lxc [react]=lxc
    [n8n]=docker [appsmith]=docker [illa]=docker [tolgee]=docker
    [chatwoot]=docker [cube]=docker [ocis]=docker
)
declare -A CAT_PORT=(
    [monitoring]=3000 [nextcloud]=80 [react]=80
    [n8n]=5678 [appsmith]=7667 [illa]=2022 [tolgee]=8200
    [chatwoot]=3000 [cube]=4000 [ocis]=9200
)
declare -A CAT_ACCESS=(
    [monitoring]=public [nextcloud]=public [react]=public
    [n8n]=onboarding [appsmith]=onboarding [illa]=onboarding [tolgee]=public
    [chatwoot]=onboarding [cube]=public [ocis]=public
)
declare -A CAT_DESC=(
    [monitoring]="Prometheus + Grafana (LXC)"
    [nextcloud]="Nextcloud with MariaDB, Redis and APCu (LXC)"
    [react]="Static front-end (React, Vue, Vite...) built from a git repository (LXC)"
    [n8n]="n8n workflow automation (Docker)"
    [appsmith]="Appsmith internal tools builder (Docker)"
    [illa]="ILLA Builder low-code platform (Docker)"
    [tolgee]="Tolgee localization platform with PostgreSQL (Docker)"
    [chatwoot]="Chatwoot customer support with PostgreSQL/pgvector and Redis (Docker)"
    [cube]="Cube semantic layer / analytics API with Cube Store (Docker)"
    [ocis]="ownCloud Infinite Scale (replaces ownCloud 10, which needs PHP 7.4) (Docker)"
)
CAT_ORDER=(monitoring nextcloud react n8n appsmith illa tolgee chatwoot cube ocis)
declare -A CAT_ALIAS=([owncloud]=ocis [grafana]=monitoring [prometheus]=monitoring)

apps_print_catalogue() {
    local app
    printf 'Available applications:\n'
    for app in "${CAT_ORDER[@]}"; do
        printf '  %-11s %s\n' "$app" "${CAT_DESC[$app]}"
    done
}

apps_print_installed() {
    local inst found=0
    printf 'Installed instances:\n'
    for inst in $(app_instances); do
        found=1
        (
            app_load "$inst"
            printf '  %-14s %-11s %-6s https://%-35s %s\n' "$APP_INSTANCE" "$APP_NAME" "$APP_KIND" "$APP_FQDN" "$APP_ACCESS"
        )
    done
    (( found )) || printf '  (none)\n'
}

# Globals available to app installers:
#   INSTANCE  FQDN  CT_IP  CT_GATEWAY (lxc)  HOST_PORT (docker)
app_create() {
    local app=${1-} subdomain bridge access upstream host port
    INSTANCE=${2-}
    config_require

    if [[ -z $app ]]; then
        apps_print_catalogue
        ask app "Application" "" app_is_known
    fi
    app=${CAT_ALIAS[$app]:-$app}
    app_is_known "$app" || die "Unknown application: ${app}"

    if [[ -z $INSTANCE ]]; then
        ask INSTANCE "Instance name (container / stack name)" "$app" is_label
    fi
    is_label "$INSTANCE" || die "Invalid instance name: ${INSTANCE}"
    app_exists "$INSTANCE" && die "An instance named ${INSTANCE} already exists."

    ask subdomain "Sub-domain" "$INSTANCE" is_label
    FQDN="${subdomain}.${DOMAIN}"

    section "Installing ${app} as ${INSTANCE} (https://${FQDN})"
    if [[ ${CAT_KIND[$app]} == lxc ]]; then
        command -v lxc-create >/dev/null || die "LXC is not installed. Run ./main.sh setup first."
        choose bridge "Network for the container:" "${BRIDGES[@]}"
        lxc_create "$INSTANCE" "$bridge"
        host=$CT_IP
        port=${CAT_PORT[$app]}
    else
        command -v docker >/dev/null || die "Docker is not installed. Run ./main.sh setup first."
        HOST_PORT=$(free_port "${CAT_PORT[$app]}")
        stack_init "$INSTANCE" "$app"
        host=127.0.0.1
        port=$HOST_PORT
    fi

    "app_${app}_install"

    access=public
    [[ ${CAT_ACCESS[$app]} == onboarding ]] && access=restricted
    upstream="http://${host}:${port}"
    nginx_site_create "$INSTANCE" "$FQDN" "$upstream" "$access"
    app_register "$INSTANCE" "$app" "${CAT_KIND[$app]}" "$host" "$port" "$FQDN" "$access"

    section "Done"
    ok "${app} is available at https://${FQDN}"
    [[ -f ${SECRETS_DIR}/${INSTANCE}.txt ]] && info "Credentials: ${SECRETS_DIR}/${INSTANCE}.txt (root only)"
    info "Services can take a minute or two to finish starting."

    if [[ $access == restricted ]]; then
        warn "The site only accepts the allow-list for now: open it, create the admin account, then make it public."
        if confirm "Have you created the admin account at https://${FQDN} ?" n; then
            site_set_access "$INSTANCE" public
        else
            info "Later, run: ./main.sh site open ${INSTANCE}"
        fi
    fi
}

app_is_known() { [[ -n ${CAT_KIND[${CAT_ALIAS[$1]:-$1}]-} ]]; }

site_set_access() {
    local inst=$1 mode=$2
    app_load "$inst"
    nginx_site_set_access "$inst" "$mode"
    app_set_access "$inst" "$mode"
    ok "https://${APP_FQDN} is now ${mode}."
}

app_remove() {
    local inst=$1
    app_load "$inst"
    warn "This permanently deletes ${inst} (${APP_NAME}) and ALL its data."
    confirm "Delete ${inst}?" n || return 0
    if [[ $APP_KIND == lxc ]]; then
        lxc_destroy "$inst"
    else
        stack_remove "$inst"
    fi
    nginx_site_remove "$inst" "$APP_FQDN"
    nginx_reload
    rm -f "${APPS_DIR}/${inst}.env" "${SECRETS_DIR}/${inst}.txt"
    ok "${inst} removed."
}

# Load every installer.
for _app_file in "${LIB_DIR}"/apps/*.sh; do
    # shellcheck disable=SC1090
    source "$_app_file"
done
unset _app_file
