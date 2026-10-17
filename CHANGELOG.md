# Changelog

## 2.0.0

Complete rewrite.

### Added
- Command-line interface (`./main.sh setup|create|list|site|allow|deny|vpn|backup|update|status|reset`)
  in addition to the interactive menu.
- Debian 13 (trixie) support; Debian 12 remains supported.
- nftables firewall in its own table (default deny, SSH allow-list, bridge isolation).
- Native WireGuard setup with client management and QR codes (`./main.sh vpn`).
- restic backups (SFTP, S3, REST, local, rclone) with retention and integrity checks.
- Unattended security upgrades on the host and in every container.
- Weekly Docker stack updates through a systemd timer.
- Per-site access control (allow-list or public) and multiple instances per app.
- Grafana provisioned with a Prometheus datasource and the host exporters.
- Nextcloud fully installed (MariaDB, Redis, APCu, cron), Tolgee, Chatwoot and
  Cube through their official images, ownCloud Infinite Scale.
- Logging to `/var/log/cluster-setup.log`, lock against concurrent runs.
- ShellCheck workflow.

### Changed
- Unprivileged LXC containers with a dedicated UID range each.
- Bridges managed by systemd-networkd instead of LXD (snap).
- SSH hardening in a validated drop-in file; key-only login when a key is present.
- TLS 1.2/1.3 only, HTTP/2, certificates obtained without stopping Nginx.
- Docker apps bound to `127.0.0.1` only.
- Settings stored in `/etc/cluster-setup` (root only) instead of `/root/*.txt`.
- cAdvisor image moved to `ghcr.io/google/cadvisor`.

### Removed
- Debian 11 support (end of life).
- watchtower (archived upstream, incompatible with Docker 29).
- ownCloud 10 (requires PHP 7.4), FTP backup script, `hosts.allow`/`hosts.deny`,
  third-party WireGuard installer, `curl | bash` installs.

### Fixed
- Many bugs of 1.x, including: watchtower never started (wrong file name),
  `docker compose-f` typo, invalid `[ a && b ]` test in the backup script,
  Prometheus scraping unreachable targets, prompts printing errors into
  captured values, password injection into SQL and shell commands.
