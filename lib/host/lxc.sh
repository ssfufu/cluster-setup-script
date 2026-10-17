# shellcheck shell=bash
# LXC: unprivileged system containers (each one gets its own UID/GID range),
# static addressing on the DMZ bridges, and helpers to run commands inside.

LXC_PATH=/var/lib/lxc
LXC_IDMAP_BASE=1000000
LXC_IDMAP_SIZE=65536
LXC_IDMAP_SLOTS=64

lxc_setup() {
    section "LXC"
    apt_install lxc uidmap wget xz-utils
    # Range delegated to root for unprivileged containers.
    local range="root:${LXC_IDMAP_BASE}:$((LXC_IDMAP_SIZE * LXC_IDMAP_SLOTS))" f
    for f in /etc/subuid /etc/subgid; do
        touch "$f"
        grep -qxF "$range" "$f" || printf '%s\n' "$range" >> "$f"
    done
    # lxc.service starts containers flagged with lxc.start.auto at boot.
    systemctl enable lxc.service >/dev/null 2>&1 || true
    ok "LXC ready (unprivileged containers, autostart enabled)."
}

lxc_next_idmap_base() {
    local used slot base
    used=$(cat "$LXC_PATH"/*/config 2>/dev/null | awk '$1=="lxc.idmap" && $3=="u" {print $5}' || true)
    for (( slot = 0; slot < LXC_IDMAP_SLOTS; slot++ )); do
        base=$(( LXC_IDMAP_BASE + slot * LXC_IDMAP_SIZE ))
        if ! grep -qx "$base" <<<"$used"; then
            printf '%s' "$base"
            return 0
        fi
    done
    die "No free UID range left for a new container."
}

lxc_next_ip() {
    local br=$1 prefix used i ip
    prefix=$(bridge_prefix "$br")
    used=$(cat "$LXC_PATH"/*/config 2>/dev/null | awk '$1=="lxc.net.0.ipv4.address" {split($3, a, "/"); print a[1]}' || true)
    for (( i = 2; i <= 254; i++ )); do
        ip="${prefix}.${i}"
        grep -qxF "$ip" <<<"$used" && continue
        ping -c 1 -W 1 "$ip" >/dev/null 2>&1 && continue
        printf '%s' "$ip"
        return 0
    done
    die "No free IP address left on bridge ${br}."
}

# ct_exec <ct> <cmd...> — runs a command in the container with a clean
# environment (host variables, secrets included, are not leaked).
ct_exec() {
    local ct=$1
    shift
    lxc-attach -n "$ct" --clear-env \
        --set-var PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        --set-var HOME=/root --set-var LANG=C.UTF-8 \
        --set-var DEBIAN_FRONTEND=noninteractive -- "$@"
}

# ct_sh <ct> <script> [args...] — runs a bash snippet with strict mode
ct_sh() {
    local ct=$1 script=$2
    shift 2
    ct_exec "$ct" bash -Eeuo pipefail -c "$script" bash "$@"
}

# ct_write <ct> <path> [mode] [owner] — writes stdin to a file in the container
ct_write() {
    local ct=$1 path=$2 mode=${3:-0644} owner=${4:-root:root}
    # shellcheck disable=SC2016 # expanded inside the container
    ct_exec "$ct" sh -c 'umask 077; mkdir -p "$(dirname "$1")"; cat > "$1.tmp" && chmod "$2" "$1.tmp" && chown "$3" "$1.tmp" && mv -f "$1.tmp" "$1"' \
        sh "$path" "$mode" "$owner"
}

ct_apt_install() {
    local ct=$1
    shift
    info "Installing in ${ct}: $*"
    ct_exec "$ct" apt-get install -y -qq --no-install-recommends \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@" >/dev/null
}

ct_has_network() { ct_exec "$1" getent hosts deb.debian.org; }

# lxc_create <name> <bridge> — creates, configures and starts a container.
# Sets CT_IP and CT_GATEWAY.
lxc_create() {
    local name=$1 br=$2 base conf rootfs arch dns
    [[ -e ${LXC_PATH}/${name} ]] && die "Container ${name} already exists."

    CT_IP=$(lxc_next_ip "$br")
    CT_GATEWAY=$(bridge_gateway "$br")
    base=$(lxc_next_idmap_base)
    arch=$(dpkg --print-architecture)

    section "Creating container ${name} (${CT_IP} on ${br}, Debian ${CT_RELEASE})"
    conf=$(mktemp)
    {
        echo "lxc.net.0.type = veth"
        echo "lxc.net.0.link = ${br}"
        echo "lxc.net.0.flags = up"
        echo "lxc.net.0.name = eth0"
        echo "lxc.net.0.ipv4.address = ${CT_IP}/24"
        echo "lxc.net.0.ipv4.gateway = ${CT_GATEWAY}"
        echo "lxc.idmap = u 0 ${base} ${LXC_IDMAP_SIZE}"
        echo "lxc.idmap = g 0 ${base} ${LXC_IDMAP_SIZE}"
        echo "lxc.start.auto = 1"
        echo "lxc.start.delay = 5"
        if [[ -d /sys/kernel/security/apparmor ]]; then
            echo "lxc.apparmor.profile = generated"
            echo "lxc.apparmor.allow_nesting = 0"
        fi
    } > "$conf"

    lxc-create -n "$name" -f "$conf" -t download -- \
        --dist debian --release "$CT_RELEASE" --arch "$arch" >/dev/null
    rm -f "$conf"

    # Static network configuration, written before the first boot.
    rootfs="${LXC_PATH}/${name}/rootfs"
    rm -f "${rootfs}"/etc/systemd/network/eth0.network
    install -d "${rootfs}/etc/systemd/network"
    printf '[Match]\nName=eth0\n\n[Network]\nAddress=%s/24\nGateway=%s\n' "$CT_IP" "$CT_GATEWAY" \
        > "${rootfs}/etc/systemd/network/10-eth0.network"
    if [[ -f ${rootfs}/etc/network/interfaces ]]; then
        sed -i 's/^iface eth0 inet dhcp/iface eth0 inet manual/' "${rootfs}/etc/network/interfaces"
    fi
    rm -f "${rootfs}/etc/resolv.conf"
    : > "${rootfs}/etc/resolv.conf"
    for dns in $DNS_SERVERS; do printf 'nameserver %s\n' "$dns" >> "${rootfs}/etc/resolv.conf"; done
    printf '%s\n' "$name" > "${rootfs}/etc/hostname"
    printf '127.0.0.1 localhost\n127.0.1.1 %s\n::1 localhost ip6-localhost ip6-loopback\n' "$name" > "${rootfs}/etc/hosts"
    chown "${base}:${base}" "${rootfs}/etc/systemd/network/10-eth0.network" \
        "${rootfs}/etc/resolv.conf" "${rootfs}/etc/hostname" "${rootfs}/etc/hosts"

    lxc-start -n "$name"
    lxc-wait -n "$name" -s RUNNING -t 30
    ct_exec "$name" timeout 120 systemctl is-system-running --wait >/dev/null 2>&1 || true
    wait_for 90 "network in container ${name}" ct_has_network "$name"

    ct_bootstrap "$name"
    ok "Container ${name} is running."
}

# Base packages and automatic security updates inside a new container.
ct_bootstrap() {
    local ct=$1
    info "Updating container ${ct}..."
    ct_exec "$ct" apt-get update -qq
    ct_exec "$ct" apt-get full-upgrade -y -qq -o Dpkg::Options::=--force-confold >/dev/null
    ct_apt_install "$ct" ca-certificates curl gnupg unattended-upgrades
    ct_write "$ct" /etc/apt/apt.conf.d/20auto-upgrades 0644 <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
}

# ct_add_apt_repo <ct> <name> <key_url> <uri> <suite> <components>
ct_add_apt_repo() {
    local ct=$1 name=$2 key_url=$3 uri=$4 suite=$5 components=$6
    # shellcheck disable=SC2016 # expanded inside the container
    ct_sh "$ct" 'install -d -m 0755 /etc/apt/keyrings; curl -fsSL --proto "=https" "$1" -o "/etc/apt/keyrings/$2.asc"; chmod 0644 "/etc/apt/keyrings/$2.asc"' "$key_url" "$name"
    printf 'Types: deb\nURIs: %s\nSuites: %s\nComponents: %s\nSigned-By: /etc/apt/keyrings/%s.asc\n' \
        "$uri" "$suite" "$components" "$name" | ct_write "$ct" "/etc/apt/sources.list.d/${name}.sources" 0644
    ct_exec "$ct" apt-get update -qq
}

lxc_destroy() {
    local name=$1
    [[ -d ${LXC_PATH}/${name} ]] || return 0
    lxc-stop -n "$name" -k 2>/dev/null || true
    lxc-destroy -n "$name"
}
