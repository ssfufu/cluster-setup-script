# shellcheck shell=bash
# Host metrics for the "monitoring" container: node exporter, nginx exporter
# (Debian packages, updated by unattended-upgrades) and cAdvisor (Docker).

CADVISOR_VERSION=v0.53.0

exporters_setup() {
    section "Host metrics"
    apt_install prometheus-node-exporter prometheus-nginx-exporter

    write_file /etc/default/prometheus-nginx-exporter 0644 <<'EOT'
# Managed by cluster-setup
ARGS="--nginx.scrape-uri=http://127.0.0.1:8080/stub_status"
EOT
    systemctl enable prometheus-node-exporter.service prometheus-nginx-exporter.service >/dev/null 2>&1
    systemctl restart prometheus-node-exporter.service prometheus-nginx-exporter.service

    if [[ ! -d $(stack_dir cadvisor) ]]; then
        stack_init cadvisor cadvisor
        printf 'CADVISOR_VERSION=%s\n' "$CADVISOR_VERSION" | stack_env cadvisor
    fi
    stack_up cadvisor

    if ! app_exists cadvisor && confirm "Publish the cAdvisor dashboard at https://cadvisor.${DOMAIN} (allow-list only)?" y; then
        nginx_site_create cadvisor "cadvisor.${DOMAIN}" "http://127.0.0.1:8899" restricted
        app_register cadvisor cadvisor docker 127.0.0.1 8899 "cadvisor.${DOMAIN}" restricted
    fi
    ok "Exporters ready: node :9100, nginx :9113, cAdvisor :8899 (reachable from the LXC bridges only)."
}
