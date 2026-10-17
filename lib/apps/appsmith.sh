# shellcheck shell=bash
# Appsmith (community edition). Only reachable through nginx (the old setup
# published it directly on the Internet on port 7667).

app_appsmith_install() {
    local dir
    dir=$(stack_dir "$INSTANCE")
    printf 'HOST_PORT=%s\n' "$HOST_PORT" | stack_env "$INSTANCE"
    install -d -m 0750 "${dir}/stacks"
    stack_up "$INSTANCE"
}
