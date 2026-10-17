# shellcheck shell=bash
# n8n workflow automation. The first visitor creates the owner account, so the
# site stays restricted to the allow-list until you open it.

app_n8n_install() {
    local dir key
    dir=$(stack_dir "$INSTANCE")
    key=$(gen_secret 40)
    {
        printf 'HOST_PORT=%s\nFQDN=%s\nTZ=%s\n' "$HOST_PORT" "$FQDN" "$(host_timezone)"
        printf 'N8N_ENCRYPTION_KEY=%s\n' "$key"
    } | stack_env "$INSTANCE"
    install -d -m 0700 -o 1000 -g 1000 "${dir}/data"
    save_credential "$INSTANCE" "n8n encryption key (needed to restore credentials)" "$key"
    stack_up "$INSTANCE"
}
