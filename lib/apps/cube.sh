# shellcheck shell=bash
# Cube (semantic layer / analytics API) from the official image, with Cube
# Store. Replaces the deprecated "cubejs create" CLI workflow.

app_cube_install() {
    local dir db_type db_host db_port db_name db_user db_password secret token
    dir=$(stack_dir "$INSTANCE")
    info "Use host.docker.internal to reach a database running on this host."
    ask db_type "Database type (postgres, mysql, clickhouse, ...)" "postgres" is_identifier
    ask db_host "Database host" "" is_host_or_docker
    ask db_port "Database port" "5432" is_port
    ask db_name "Database name" "" is_identifier
    ask db_user "Database user" "" is_identifier
    ask_secret db_password "Database password" 1
    secret=$(openssl rand -hex 32)

    {
        printf 'HOST_PORT=%s\n' "$HOST_PORT"
        printf 'CUBEJS_DB_TYPE=%s\nCUBEJS_DB_HOST=%s\nCUBEJS_DB_PORT=%s\nCUBEJS_DB_NAME=%s\nCUBEJS_DB_USER=%s\n' \
            "$db_type" "$db_host" "$db_port" "$db_name" "$db_user"
        env_kv CUBEJS_DB_PASS "$db_password"
        printf 'CUBEJS_API_SECRET=%s\n' "$secret"
    } | stack_env "$INSTANCE"
    install -d -m 0755 "${dir}/conf/model/cubes" "${dir}/conf/model/views"
    install -d -m 0750 "${dir}/cubestore"
    stack_up "$INSTANCE"

    token=$(jwt_hs256 "$secret" $((30 * 24 * 3600)))
    save_credential "$INSTANCE" "Cube API secret" "$secret"
    save_credential "$INSTANCE" "Cube API token (30 days)" "$token"
    info "Put your data model in ${dir}/conf/model (cubes/ and views/), then restart the stack."
    info "An API token valid 30 days was saved in ${SECRETS_DIR}/${INSTANCE}.txt"
}

# jwt_hs256 <secret> <ttl-seconds> — signed token for the Cube REST API
jwt_hs256() {
    local secret=$1 ttl=$2 now header payload sig
    now=$(date +%s)
    b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
    header=$(printf '{"alg":"HS256","typ":"JWT"}' | b64url)
    payload=$(printf '{"iat":%d,"exp":%d}' "$now" $((now + ttl)) | b64url)
    sig=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -hmac "$secret" -binary | b64url)
    printf '%s.%s.%s' "$header" "$payload" "$sig"
}
