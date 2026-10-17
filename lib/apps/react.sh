# shellcheck shell=bash
# Static front-end built from a git repository with Node.js LTS (NodeSource
# signed repository), served by nginx inside the container.
# The build runs as an unprivileged user; redeploy with:
#   lxc-attach -n <instance> -- deploy-app

REACT_NODE_MAJOR=24

app_react_install() {
    local ct=$INSTANCE repo branch git_user token host
    ask repo "Git repository (https://...)" "" is_git_url
    ask branch "Branch" "main" is_git_ref

    ct_add_apt_repo "$ct" nodesource https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        "https://deb.nodesource.com/node_${REACT_NODE_MAJOR}.x" nodistro main
    ct_apt_install "$ct" nodejs git nginx rsync
    ct_exec "$ct" id app >/dev/null 2>&1 || ct_exec "$ct" useradd --system --create-home --home-dir /home/app --shell /usr/sbin/nologin app
    ct_exec "$ct" install -d -m 0755 -o app -g app /srv/app/src
    ct_exec "$ct" install -d -m 0755 /srv/app/www

    if confirm "Is it a private repository?" n; then
        ask git_user "Git username" "" is_identifier
        ask_secret token "Access token (read-only scope is enough)" 8
        host=${repo#https://}
        host=${host%%/*}
        # Stored for future deployments, readable by the build user only.
        printf 'https://%s:%s@%s\n' "$git_user" "$token" "$host" \
            | ct_write "$ct" /home/app/.git-credentials 0600 app:app
        ct_exec "$ct" runuser -u app -- env HOME=/home/app git config --global credential.helper store
    fi

    printf 'REPO_URL=%q\nBRANCH=%q\n' "$repo" "$branch" | ct_write "$ct" /srv/app/deploy.conf 0644
    ct_write "$ct" /usr/local/bin/deploy-app 0755 < "${TEMPLATES_DIR}/react/deploy-app"
    ct_write "$ct" /etc/nginx/sites-available/default 0644 < "${TEMPLATES_DIR}/react/nginx.conf"

    info "Building the application..."
    ct_exec "$ct" deploy-app
    ct_exec "$ct" systemctl reload nginx
    info "Redeploy after a push: lxc-attach -n ${ct} -- deploy-app"
}

is_git_ref() { [[ $1 =~ ^[A-Za-z0-9._/-]+$ && $1 != *..* ]]; }
