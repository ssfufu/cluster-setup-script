#!/usr/bin/env bash
# cluster-setup — prepare a Debian server for LXC containers and Docker apps
# behind an Nginx reverse proxy with Let's Encrypt.
set -Eeuo pipefail
shopt -s inherit_errexit
# Bash >= 5.2: "&" in a replacement string must stay literal (see render()).
shopt -u patsub_replacement 2>/dev/null || true
umask 022

SCRIPT_DIR=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)
LIB_DIR=${SCRIPT_DIR}/lib
TEMPLATES_DIR=${SCRIPT_DIR}/templates
LOG_FILE=/var/log/cluster-setup.log
CS_VERSION=2.0.0

# shellcheck source=lib/common.sh
source "${LIB_DIR}/common.sh"
# shellcheck source=lib/config.sh
source "${LIB_DIR}/config.sh"
for _f in "${LIB_DIR}"/host/*.sh; do
    # shellcheck disable=SC1090
    source "$_f"
done
unset _f
# shellcheck source=lib/apps.sh
source "${LIB_DIR}/apps.sh"

usage() {
    cat <<EOF
cluster-setup ${CS_VERSION}

Usage: sudo ./main.sh [command]

Without a command, an interactive menu is shown.

Host
  setup                        Prepare the server (safe to run again)
  ssh                          Re-apply the SSH hardening (e.g. after adding a key)
  firewall                     Re-apply the firewall from the saved settings
  allow <ip|cidr>...           Add addresses to the allow-list
  deny <ip|cidr>...            Remove addresses from the allow-list
  update                       Upgrade the host, every container and Docker stack
  status                       Show settings and installed applications
  reset                        Remove everything created by this tool

Applications
  list                         Available applications and installed instances
  create [app] [instance]      Install an application
  remove <instance>            Delete an instance and its data
  site open|restrict <inst>    Make a site public or allow-list only

VPN (WireGuard)
  vpn setup                    Install the VPN
  vpn add <name> [split|full]  Add a client (split: VPN + containers, full: all traffic)
  vpn remove|show <name>       Remove a client / show its config and QR code
  vpn list                     List clients

Backups (restic)
  backup setup                 Configure the repository and the daily schedule
  backup run                   Run a backup now
  backup snapshots             List snapshots
EOF
}

banner() {
    cat <<'EOF'

   ┌─────────────────────────────────────────────┐
   │   cluster-setup — LXC · Docker · Nginx      │
   └─────────────────────────────────────────────┘
EOF
}

menu() {
    banner
    local choice
    choose choice "What would you like to do?" \
        "Set up the system" \
        "Create an application" \
        "Configure backups" \
        "Manage the VPN" \
        "Show status" \
        "Update everything" \
        "Reset the server" \
        "Quit"
    case $choice in
        "Set up the system")     setup_host ;;
        "Create an application") app_create ;;
        "Configure backups")     config_require; backup_setup ;;
        "Manage the VPN")        vpn_menu ;;
        "Show status")           show_status ;;
        "Update everything")     update_all ;;
        "Reset the server")      reset_server ;;
        *) exit 0 ;;
    esac
}

vpn_menu() {
    config_require
    if [[ $WG_ENABLED != yes ]]; then
        confirm "The VPN is not installed. Install it now?" y || return 0
        vpn_enable
        return 0
    fi
    local action name
    choose action "VPN:" "Add a client" "Remove a client" "Show a client" "List clients"
    case $action in
        "Add a client")    ask name "Client name" "" is_label; cluster-wg add "$name" ;;
        "Remove a client") ask name "Client name" "" is_label; cluster-wg remove "$name" ;;
        "Show a client")   ask name "Client name" "" is_label; cluster-wg show "$name" ;;
        *)                 cluster-wg list ;;
    esac
}

vpn_enable() {
    wireguard_setup
    nginx_write_allowlist
    nginx_reload
    firewall_apply
}

show_status() {
    config_require
    section "Settings (${CONF_FILE})"
    printf '  Domain        %s\n  Public IP     %s (%s)\n  Allow-list    %s\n  Admin user    %s\n  SSH port      %s\n  VPN           %s\n' \
        "$DOMAIN" "$PUBLIC_IP" "$WAN_IFACE" "$ALLOWED_IPS" "$ADMIN_USER" "$SSH_PORT" \
        "$([[ $WG_ENABLED == yes ]] && echo "udp/${WG_PORT}, ${WG_SUBNET}" || echo disabled)"
    section "Applications"
    apps_print_installed
    if command -v lxc-ls >/dev/null; then
        section "LXC containers"
        lxc-ls --fancy -F NAME,STATE,AUTOSTART,IPV4 || true
    fi
    section "Timers"
    systemctl list-timers --no-pager 'cluster-*' 2>/dev/null || true
}

main() {
    case ${1-} in
        -h|--help|help) usage; return 0 ;;
        -v|--version)   echo "$CS_VERSION"; return 0 ;;
        *) ;;
    esac
    require_root
    touch "$LOG_FILE" && chmod 0600 "$LOG_FILE"
    # Everything is logged (prompts included, secrets are never echoed).
    exec > >(tee -a "$LOG_FILE") 2>&1
    trap 'on_error $? $LINENO "$BASH_COMMAND" "${BASH_SOURCE[0]##*/}"' ERR

    exec 8>/run/cluster-setup.lock
    flock -n 8 || die "Another instance of cluster-setup is running."

    require_debian
    config_load

    local cmd=${1-}
    shift || true
    case $cmd in
        '')         menu ;;
        setup)      setup_host ;;
        ssh)        config_require; ssh_setup ;;
        firewall)   config_require; firewall_apply ;;
        allow)      [[ $# -gt 0 ]] || die "Usage: ./main.sh allow <ip|cidr>..."; allowlist_add "$@" ;;
        deny)       [[ $# -gt 0 ]] || die "Usage: ./main.sh deny <ip|cidr>..."; allowlist_remove "$@" ;;
        update)     update_all ;;
        status)     show_status ;;
        reset)      reset_server ;;
        list)       apps_print_catalogue; echo; apps_print_installed ;;
        create)     app_create "${1-}" "${2-}" ;;
        remove)     [[ $# -eq 1 ]] || die "Usage: ./main.sh remove <instance>"; app_remove "$1" ;;
        site)
            [[ $# -eq 2 ]] || die "Usage: ./main.sh site open|restrict <instance>"
            case $1 in
                open)     site_set_access "$2" public ;;
                restrict) site_set_access "$2" restricted ;;
                *) die "Usage: ./main.sh site open|restrict <instance>" ;;
            esac ;;
        vpn)
            config_require
            case ${1-} in
                setup) vpn_enable ;;
                add|remove|show|list)
                    [[ $WG_ENABLED == yes ]] || die "The VPN is not installed: ./main.sh vpn setup"
                    cluster-wg "$@" ;;
                *) vpn_menu ;;
            esac ;;
        backup)
            config_require
            case ${1-setup} in
                setup)     backup_setup ;;
                run)       systemctl start cluster-backup.service && ok "Backup finished (journalctl -u cluster-backup)." ;;
                snapshots) backup_restic snapshots ;;
                *) die "Usage: ./main.sh backup setup|run|snapshots" ;;
            esac ;;
        -h|--help|help) usage ;;
        -v|--version) echo "$CS_VERSION" ;;
        *) usage; exit 1 ;;
    esac
}

main "$@"
