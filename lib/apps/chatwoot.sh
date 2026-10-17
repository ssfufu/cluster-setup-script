# shellcheck shell=bash
# Chatwoot with PostgreSQL (pgvector, required since Chatwoot 4) and Redis.
# All secrets are generated. The first visitor creates the super admin, so the
# site stays restricted to the allow-list until you open it.

app_chatwoot_install() {
    local dir pg_password redis_password
    dir=$(stack_dir "$INSTANCE")
    pg_password=$(gen_secret 32)
    redis_password=$(gen_secret 32)

    stack_env "$INSTANCE" <<EOT
HOST_PORT=${HOST_PORT}
SECRET_KEY_BASE=$(openssl rand -hex 64)
FRONTEND_URL=https://${FQDN}
FORCE_SSL=false
ENABLE_ACCOUNT_SIGNUP=false
INSTALLATION_ENV=docker
RAILS_ENV=production
NODE_ENV=production
RAILS_LOG_TO_STDOUT=true
LOG_LEVEL=info
ACTIVE_STORAGE_SERVICE=local
POSTGRES_HOST=postgres
POSTGRES_DATABASE=chatwoot
POSTGRES_USERNAME=postgres
POSTGRES_PASSWORD=${pg_password}
REDIS_URL=redis://redis:6379
REDIS_PASSWORD=${redis_password}
MAILER_SENDER_EMAIL=Chatwoot <noreply@${DOMAIN}>
# Outgoing e-mail: fill in, then run: docker compose up -d (in this directory)
SMTP_ADDRESS=
SMTP_PORT=587
SMTP_DOMAIN=${DOMAIN}
SMTP_USERNAME=
SMTP_PASSWORD=
SMTP_AUTHENTICATION=login
SMTP_ENABLE_STARTTLS_AUTO=true
SMTP_OPENSSL_VERIFY_MODE=peer
EOT
    install -d -m 0750 "${dir}/storage"
    install -d -m 0700 "${dir}/postgres" "${dir}/redis"

    info "Preparing the database (this can take a few minutes)..."
    stack_compose "$INSTANCE" pull --quiet
    stack_compose "$INSTANCE" up -d --wait postgres redis
    stack_compose "$INSTANCE" run --rm rails bundle exec rails db:chatwoot_prepare
    stack_up "$INSTANCE"
    info "SMTP settings can be added later in $(stack_dir "$INSTANCE")/.env"
}
