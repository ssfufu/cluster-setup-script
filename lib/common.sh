# shellcheck shell=bash
# Shared helpers: output, prompts, validation, files, packages.

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
if [[ -t 1 && -z ${NO_COLOR-} ]]; then
    C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m' C_BOLD=$'\e[1m' C_RESET=$'\e[0m'
else
    C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_BOLD='' C_RESET=''
fi

info()    { printf '%s[*]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()      { printf '%s[ok]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()    { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
error()   { printf '%s[x]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()     { error "$*"; exit 1; }
section() { printf '\n%s==== %s ====%s\n\n' "$C_BOLD" "$*" "$C_RESET"; }

on_error() {
    local status=$1 line=$2 cmd=$3 src=${4:-?}
    error "Command failed (exit ${status}) at ${src}:${line}: ${cmd}"
    error "See ${LOG_FILE:-the log} for details."
}

# ---------------------------------------------------------------------------
# Prompts
# All prompts write to stderr and store the answer in the variable whose name
# is given as first argument, so they never pollute captured output.
# ---------------------------------------------------------------------------
_read_line() {
    local __prompt=$1 __reply
    IFS= read -r -p "$__prompt" __reply || die "Input closed, aborting."
    # trim surrounding whitespace
    __reply="${__reply#"${__reply%%[![:space:]]*}"}"
    __reply="${__reply%"${__reply##*[![:space:]]}"}"
    printf '%s' "$__reply"
}

# ask <var> <prompt> [default] [validator]
ask() {
    local __var=$1 __prompt=$2 __default=${3-} __validator=${4-} __reply
    while true; do
        if [[ -n $__default ]]; then
            __reply=$(_read_line "${__prompt} [${__default}]: ")
            __reply=${__reply:-$__default}
        else
            __reply=$(_read_line "${__prompt}: ")
        fi
        if [[ -z $__reply ]]; then
            warn "A value is required."
            continue
        fi
        if [[ -n $__validator ]] && ! "$__validator" "$__reply"; then
            warn "Invalid value: ${__reply}"
            continue
        fi
        printf -v "$__var" '%s' "$__reply"
        return 0
    done
}

# ask_optional <var> <prompt> [validator] — empty answer allowed
ask_optional() {
    local __var=$1 __prompt=$2 __validator=${3-} __reply
    while true; do
        __reply=$(_read_line "${__prompt}: ")
        if [[ -n $__reply && -n $__validator ]] && ! "$__validator" "$__reply"; then
            warn "Invalid value: ${__reply}"
            continue
        fi
        printf -v "$__var" '%s' "$__reply"
        return 0
    done
}

# ask_secret <var> <prompt> [min_length]
# Empty answer generates a random secret. The answer is never echoed.
ask_secret() {
    local __var=$1 __prompt=$2 __min=${3:-12} __a __b
    while true; do
        IFS= read -r -s -p "${__prompt} (empty = generate one): " __a || die "Input closed, aborting."
        printf '\n' >&2
        if [[ -z $__a ]]; then
            __a=$(gen_secret 24)
            info "A random value was generated, it will be saved in the credentials file."
            printf -v "$__var" '%s' "$__a"
            return 0
        fi
        if [[ $__a == *"'"* ]]; then
            warn "Single quotes (') are not supported in this value."
            continue
        fi
        if (( ${#__a} < __min )); then
            warn "Must be at least ${__min} characters."
            continue
        fi
        IFS= read -r -s -p "Confirm: " __b || die "Input closed, aborting."
        printf '\n' >&2
        if [[ $__a != "$__b" ]]; then
            warn "Values do not match."
            continue
        fi
        printf -v "$__var" '%s' "$__a"
        return 0
    done
}

# confirm <prompt> [default y|n]
confirm() {
    local prompt=$1 default=${2:-n} hint reply
    [[ $default == y ]] && hint='Y/n' || hint='y/N'
    while true; do
        reply=$(_read_line "${prompt} [${hint}]: ")
        reply=${reply:-$default}
        case ${reply,,} in
            y|yes|o|oui) return 0 ;;
            n|no|non)    return 1 ;;
            *) warn "Please answer y or n." ;;
        esac
    done
}

# choose <var> <prompt> <option>... — numbered menu, stores the chosen option
choose() {
    local __var=$1 __prompt=$2 __reply i
    shift 2
    local -a __opts=("$@")
    while true; do
        printf '%s\n' "$__prompt" >&2
        for i in "${!__opts[@]}"; do
            printf '  %d) %s\n' "$((i + 1))" "${__opts[i]}" >&2
        done
        __reply=$(_read_line "Choice: ")
        if [[ $__reply =~ ^[0-9]+$ ]] && (( __reply >= 1 && __reply <= ${#__opts[@]} )); then
            printf -v "$__var" '%s' "${__opts[__reply - 1]}"
            return 0
        fi
        warn "Invalid choice."
    done
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
is_ipv4() {
    local ip=$1 octet
    [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for octet in "${BASH_REMATCH[@]:1}"; do
        [[ $octet =~ ^(0|[1-9][0-9]*)$ ]] && (( octet <= 255 )) || return 1
    done
}
is_ipv4_cidr() {
    local addr=${1%/*} mask
    if [[ $1 == */* ]]; then
        mask=${1#*/}
        [[ $mask =~ ^[0-9]{1,2}$ ]] && (( mask <= 32 )) || return 1
    fi
    is_ipv4 "$addr"
}
is_ipv6_cidr() {
    local addr=${1%/*} mask
    if [[ $1 == */* ]]; then
        mask=${1#*/}
        [[ $mask =~ ^[0-9]{1,3}$ ]] && (( mask <= 128 )) || return 1
    fi
    [[ $addr == *:* && $addr =~ ^[0-9A-Fa-f:.]+$ ]]
}
is_ip_or_cidr() { is_ipv4_cidr "$1" || is_ipv6_cidr "$1"; }
is_ip_list() {
    local item
    [[ -n $1 ]] || return 1
    for item in $1; do is_ip_or_cidr "$item" || return 1; done
}
is_domain() {
    local d=${1,,}
    [[ ${#d} -le 253 && $d =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]
}
is_label() { [[ $1 =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; }
is_email() { [[ $1 =~ ^[A-Za-z0-9._%+-]+@([A-Za-z0-9-]+\.)+[A-Za-z]{2,63}$ ]]; }
is_port()  { [[ $1 =~ ^[0-9]{1,5}$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
is_uint()  { [[ $1 =~ ^[0-9]+$ ]]; }
is_username() { [[ $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }
is_identifier() { [[ $1 =~ ^[A-Za-z0-9_.-]{1,64}$ ]]; }
is_host() { is_domain "$1" || is_ipv4 "$1" || [[ $1 =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; }
is_git_url() {
    [[ $1 =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/[A-Za-z0-9._~/-]+$ ]]
}

# ---------------------------------------------------------------------------
# Secrets & files
# ---------------------------------------------------------------------------
# gen_secret [length] — alphanumeric random string (no pipes: safe with pipefail)
gen_secret() {
    local len=${1:-32} out=''
    while (( ${#out} < len )); do
        local chunk
        chunk=$(openssl rand -base64 96)
        out+=${chunk//[^A-Za-z0-9]/}
    done
    printf '%s' "${out:0:len}"
}

# write_file <dest> [mode] [owner] — atomically writes stdin to dest
write_file() {
    local dst=$1 mode=${2:-0644} owner=${3-} tmp
    mkdir -p "$(dirname "$dst")"
    tmp=$(mktemp "${dst}.XXXXXX")
    cat > "$tmp"
    chmod "$mode" "$tmp"
    [[ -n $owner ]] && chown "$owner" "$tmp"
    mv -f "$tmp" "$dst"
}

# env_kv <key> <value> — one line for a Docker Compose .env file. Single
# quotes keep the value literal (no ${...} interpolation by Compose).
env_kv() {
    [[ $2 != *"'"* && $2 != *$'\n'* ]] || die "Unsupported character in value of $1"
    printf "%s='%s'\n" "$1" "$2"
}

# render <template> KEY=VALUE... — prints the template with {{KEY}} replaced.
# Pure bash substitution: values are never interpreted (no sed injection).
render() {
    local tpl=$1 content pair key value
    shift
    [[ -f $tpl ]] || die "Template not found: ${tpl}"
    content=$(<"$tpl")
    for pair in "$@"; do
        key=${pair%%=*}
        value=${pair#*=}
        content=${content//"{{${key}}}"/"$value"}
    done
    if [[ $content =~ \{\{[A-Z0-9_]+\}\} ]]; then
        die "Template ${tpl} has an unfilled placeholder: ${BASH_REMATCH[0]}"
    fi
    printf '%s\n' "$content"
}

# ---------------------------------------------------------------------------
# System
# ---------------------------------------------------------------------------
require_root() {
    [[ ${EUID} -eq 0 ]] || die "This script must be run as root (sudo ./main.sh)."
}

require_debian() {
    local id='' version_id='' codename=''
    # shellcheck disable=SC1091
    [[ -r /etc/os-release ]] && { id=$(. /etc/os-release; echo "${ID-}"); version_id=$(. /etc/os-release; echo "${VERSION_ID-}"); codename=$(. /etc/os-release; echo "${VERSION_CODENAME-}"); }
    HOST_CODENAME=$codename
    if [[ $id != debian || ! $version_id =~ ^(12|13)$ ]]; then
        warn "Supported systems: Debian 12 (bookworm) and Debian 13 (trixie). Detected: ${id:-unknown} ${version_id}."
        confirm "Continue anyway?" n || exit 1
    fi
}

APT_UPDATED=0
apt_update() {
    if (( APT_UPDATED == 0 )); then
        info "Refreshing package lists..."
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
        APT_UPDATED=1
    fi
}
apt_install() {
    apt_update
    info "Installing: $*"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@" >/dev/null
}
pkg_installed() { [[ $(dpkg-query -W -f='${Status}' "$1" 2>/dev/null || true) == *'install ok installed'* ]]; }

# fetch_key <url> <dest> [fingerprint] — downloads an APT signing key and
# optionally checks its fingerprint before trusting it.
fetch_key() {
    local url=$1 dst=$2 fpr=${3-} tmp
    install -d -m 0755 "$(dirname "$dst")"
    tmp=$(mktemp)
    curl -fsSL --proto '=https' --tlsv1.2 "$url" -o "$tmp"
    if [[ -n $fpr ]]; then
        local fprs
        fprs=$(gpg --show-keys --with-colons "$tmp" 2>/dev/null | awk -F: '$1=="fpr"{print $10}' || true)
        if ! grep -qxF "$fpr" <<<"$fprs"; then
            rm -f "$tmp"
            die "Fingerprint mismatch for key ${url}"
        fi
    fi
    install -m 0644 "$tmp" "$dst"
    rm -f "$tmp"
}

# free_port <start> — first TCP port >= start that nothing listens on and that
# is not already assigned to a registered app.
free_port() {
    local port=$1
    while [[ -n $(ss -Hltn "sport = :${port}") ]] || app_port_taken "$port"; do
        port=$((port + 1))
    done
    printf '%s' "$port"
}

wait_for() {
    # wait_for <seconds> <description> <command...>
    local timeout=$1 what=$2 i
    shift 2
    for (( i = 0; i < timeout; i += 2 )); do
        if "$@" >/dev/null 2>&1; then return 0; fi
        sleep 2
    done
    die "Timed out waiting for ${what}."
}

host_timezone() {
    local tz=''
    tz=$(timedatectl show -p Timezone --value 2>/dev/null || true)
    [[ -z $tz && -r /etc/timezone ]] && tz=$(</etc/timezone)
    printf '%s' "${tz:-UTC}"
}

# save_credential <instance> <label> <value> — stored in a root-only file
save_credential() {
    local instance=$1 label=$2 value=$3
    local file="${SECRETS_DIR}/${instance}.txt"
    install -d -m 0700 "$SECRETS_DIR"
    ( umask 077; printf '%s: %s\n' "$label" "$value" >> "$file" )
}
