# shellcheck shell=bash
# Docker Engine from the official repository + helpers for compose stacks.

DOCKER_KEY_FPR=9DC858229FC7DD38854AE2D88D81803C0EBFCD88

docker_setup() {
    section "Docker"
    local pkg codename arch
    for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
        if pkg_installed "$pkg"; then
            DEBIAN_FRONTEND=noninteractive apt-get remove -y -qq "$pkg" >/dev/null
        fi
    done

    codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
    arch=$(dpkg --print-architecture)
    fetch_key https://download.docker.com/linux/debian/gpg /etc/apt/keyrings/docker.asc "$DOCKER_KEY_FPR"
    write_file /etc/apt/sources.list.d/docker.sources 0644 <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${codename}
Components: stable
Architectures: ${arch}
Signed-By: /etc/apt/keyrings/docker.asc
EOF
    rm -f /etc/apt/sources.list.d/docker.list
    APT_UPDATED=0
    apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    if [[ ! -f /etc/docker/daemon.json ]]; then
        write_file /etc/docker/daemon.json 0644 <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true
}
EOF
    fi
    systemctl enable docker.service containerd.service >/dev/null 2>&1
    systemctl restart docker.service
    install -d -m 0750 "$STACKS_DIR"
    ok "Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null) installed."
    info "Note: ${ADMIN_USER} is not added to the docker group (it would be root-equivalent); use sudo."
}

stack_dir() { printf '%s/%s' "$STACKS_DIR" "$1"; }

# stack_init <instance> <template-name> — copies the compose file in place
stack_init() {
    local dir
    dir=$(stack_dir "$1")
    [[ -e $dir ]] && die "Stack directory ${dir} already exists."
    install -d -m 0750 "$dir"
    install -m 0644 "${TEMPLATES_DIR}/compose/${2}/compose.yaml" "${dir}/compose.yaml"
}

# stack_env <instance> — writes stdin to the stack's .env (root only)
stack_env() { write_file "$(stack_dir "$1")/.env" 0600; }

stack_compose() {
    local dir
    dir=$(stack_dir "$1")
    shift
    docker compose --project-directory "$dir" -f "${dir}/compose.yaml" -p "$(basename "$dir")" "$@"
}

stack_up() {
    info "Starting stack $1..."
    stack_compose "$1" up -d --pull missing --remove-orphans
}

stack_remove() {
    local dir
    dir=$(stack_dir "$1")
    [[ -d $dir ]] || return 0
    stack_compose "$1" down --volumes --remove-orphans || true
    rm -rf -- "$dir"
}
