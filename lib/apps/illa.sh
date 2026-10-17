# shellcheck shell=bash
# ILLA Builder.

app_illa_install() {
    local dir
    dir=$(stack_dir "$INSTANCE")
    printf 'HOST_PORT=%s\n' "$HOST_PORT" | stack_env "$INSTANCE"
    install -d -m 0750 "${dir}/database" "${dir}/drive"
    stack_up "$INSTANCE"
}
