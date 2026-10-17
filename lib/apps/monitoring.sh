# shellcheck shell=bash
# Prometheus (Debian package) + Grafana (official repository), provisioned
# with the host exporters and a Prometheus datasource.

app_monitoring_install() {
    local ct=$INSTANCE password
    ct_apt_install "$ct" prometheus
    render "${TEMPLATES_DIR}/monitoring/prometheus.yml" "GATEWAY=${CT_GATEWAY}" \
        | ct_write "$ct" /etc/prometheus/prometheus.yml 0644
    ct_exec "$ct" promtool check config /etc/prometheus/prometheus.yml >/dev/null
    ct_exec "$ct" systemctl restart prometheus

    ct_add_apt_repo "$ct" grafana https://apt.grafana.com/gpg.key https://apt.grafana.com stable main
    ct_apt_install "$ct" grafana
    ct_write "$ct" /etc/grafana/provisioning/datasources/cluster.yaml 0640 root:grafana \
        < "${TEMPLATES_DIR}/monitoring/grafana-datasource.yaml"
    printf '[Service]\nEnvironment=GF_SERVER_ROOT_URL=https://%s/\nEnvironment=GF_ANALYTICS_REPORTING_ENABLED=false\nEnvironment=GF_USERS_ALLOW_SIGN_UP=false\n' "$FQDN" \
        | ct_write "$ct" /etc/systemd/system/grafana-server.service.d/cluster.conf 0644
    ct_exec "$ct" systemctl daemon-reload
    ct_exec "$ct" systemctl enable --now grafana-server >/dev/null 2>&1
    wait_for 120 "Grafana" ct_exec "$ct" curl -fsS http://127.0.0.1:3000/api/health

    ask_secret password "Grafana admin password" 12
    printf '%s\n' "$password" | ct_exec "$ct" grafana cli --homepath /usr/share/grafana \
        --config /etc/grafana/grafana.ini admin reset-admin-password --password-from-stdin >/dev/null
    save_credential "$INSTANCE" "Grafana URL" "https://${FQDN}"
    save_credential "$INSTANCE" "Grafana user" "admin"
    save_credential "$INSTANCE" "Grafana password" "$password"
    ct_exec "$ct" chown -R grafana:grafana /var/lib/grafana
    info "Suggested Grafana dashboards: Node Exporter Full (ID 1860), NGINX exporter (ID 12708), plus any cAdvisor dashboard."
}
