# shellcheck shell=bash
# Persistent settings and the registry of installed applications.

CONF_DIR=/etc/cluster-setup
CONF_FILE=${CONF_DIR}/cluster.conf
APPS_DIR=${CONF_DIR}/apps
SECRETS_DIR=${CONF_DIR}/credentials
DATA_DIR=/opt/cluster-setup
STACKS_DIR=${DATA_DIR}/stacks

# LXC bridges: name -> gateway/prefix. Kept identical to previous versions so
# existing allow-lists keep working.
declare -A BRIDGE_CIDR=([DMZ]=10.128.151.1/24 [DMZ2]=10.128.152.1/24)
BRIDGES=(DMZ DMZ2)

CONFIG_KEYS=(
    DOMAIN EMAIL PUBLIC_IP WAN_IFACE ALLOWED_IPS ADMIN_USER SSH_PORT
    CT_RELEASE DNS_SERVERS
    WG_ENABLED WG_PORT WG_SUBNET WG_ENDPOINT
)

config_defaults() {
    : "${ADMIN_USER:=devops}"
    : "${SSH_PORT:=6845}"
    : "${CT_RELEASE:=${HOST_CODENAME:-trixie}}"
    : "${DNS_SERVERS:=1.1.1.1 9.9.9.9}"
    : "${WG_ENABLED:=no}"
    : "${WG_PORT:=51820}"
    : "${WG_SUBNET:=10.66.66.0/24}"
    : "${ALLOWED_IPS:=}"
    : "${DOMAIN:=}"
    : "${EMAIL:=}"
    : "${PUBLIC_IP:=}"
    : "${WAN_IFACE:=}"
    : "${WG_ENDPOINT:=}"
}

config_load() {
    if [[ -f $CONF_FILE ]]; then
        # shellcheck disable=SC1090
        source "$CONF_FILE"
    fi
    config_defaults
}

config_save() {
    local key
    install -d -m 0700 "$CONF_DIR"
    {
        printf '# Managed by cluster-setup. Edit with care, then run: ./main.sh firewall\n'
        for key in "${CONFIG_KEYS[@]}"; do
            printf '%s=%q\n' "$key" "${!key-}"
        done
    } | write_file "$CONF_FILE" 0600
}

config_require() {
    [[ -n ${DOMAIN} && -f $CONF_FILE ]] || die "The host is not set up yet. Run: ./main.sh setup"
}

# Import the plain-text files written by the previous version of the scripts.
config_migrate_legacy() {
    [[ -f $CONF_FILE ]] && return 0
    [[ -f /root/domain.txt ]] || return 0
    info "Importing settings from the previous version (/root/*.txt)..."
    DOMAIN=$(awk '{print tolower($1); exit}' /root/domain.txt)
    [[ -f /root/mail.txt ]] && EMAIL=$(awk '{print $1; exit}' /root/mail.txt)
    [[ -f /root/allowed_ips.txt ]] && ALLOWED_IPS=$(tr -s '[:space:]' ' ' < /root/allowed_ips.txt | sed 's/ *$//')
}

# ---------------------------------------------------------------------------
# Application registry: one small env file per installed instance.
# ---------------------------------------------------------------------------
app_register() {
    # app_register <instance> <app> <kind> <host> <port> <fqdn> <access>
    install -d -m 0700 "$APPS_DIR"
    {
        printf 'APP_INSTANCE=%q\n' "$1"
        printf 'APP_NAME=%q\n' "$2"
        printf 'APP_KIND=%q\n' "$3"
        printf 'APP_HOST=%q\n' "$4"
        printf 'APP_PORT=%q\n' "$5"
        printf 'APP_FQDN=%q\n' "$6"
        printf 'APP_ACCESS=%q\n' "$7"
        printf 'APP_CREATED=%q\n' "$(date -Iseconds)"
    } | write_file "${APPS_DIR}/${1}.env" 0600
}

app_exists() { [[ -f ${APPS_DIR}/${1}.env ]]; }

app_load() {
    app_exists "$1" || die "Unknown instance: $1"
    # shellcheck disable=SC1090
    source "${APPS_DIR}/${1}.env"
}

app_set_access() {
    local file="${APPS_DIR}/${1}.env"
    sed -i "s/^APP_ACCESS=.*/APP_ACCESS=${2}/" "$file"
}

app_instances() {
    local f
    for f in "${APPS_DIR}"/*.env; do
        [[ -e $f ]] || continue
        basename "$f" .env
    done
}

app_port_taken() {
    local f
    for f in "${APPS_DIR}"/*.env; do
        [[ -e $f ]] || continue
        grep -qx "APP_PORT=${1}" "$f" && grep -qx 'APP_KIND=docker' "$f" && return 0
    done
    return 1
}
