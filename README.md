# 🛠️ cluster-setup

> Turn a fresh Debian server into a small self-hosting platform: LXC containers
> and Docker stacks behind an Nginx reverse proxy with Let's Encrypt, a
> firewall, a WireGuard VPN, encrypted backups and automatic updates.
>
> Supported: **Debian 13 (trixie)** and **Debian 12 (bookworm)**.

## 📖 Table of contents

- [Overview](#-overview)
- [Applications](#-applications)
- [Requirements](#-requirements)
- [Usage](#-usage)
- [Security model](#-security-model)
- [Backups and restore](#-backups-and-restore)
- [Updates](#-updates)
- [Files and layout](#-files-and-layout)
- [Upgrading from 1.x](#-upgrading-from-1x)
- [Disclaimer](#️-disclaimer)

## 📝 Overview

`./main.sh setup` prepares the host:

| Component | What is configured |
|-----------|--------------------|
| Admin account | `devops` (configurable), sudo, SSH key |
| SSH | Custom port, no root login, key-only login when a key is present, allow-list |
| Firewall | nftables (own table, compatible with Docker), default deny |
| Network | `DMZ` (10.128.151.0/24) and `DMZ2` (10.128.152.0/24) bridges, isolated from each other |
| LXC | Unprivileged containers, one UID range per container, autostart |
| Docker | Official repository (signing key fingerprint checked), log rotation |
| Nginx | Reverse proxy, TLS 1.2/1.3, HTTP/2, HSTS, certificates without downtime (webroot) |
| Metrics | node exporter, nginx exporter, cAdvisor (reachable from the containers only) |
| VPN | WireGuard, native configuration, clients with QR codes (optional) |
| Backups | restic to SFTP / S3 / REST server / disk, daily, with retention and checks |
| Updates | Debian security updates everywhere, weekly Docker image updates |

Every new site gets its own sub-domain (`<name>.<domain>`) and certificate.

## 🚀 Applications

| App | Runs in | Notes |
|-----|---------|-------|
| `monitoring` | LXC | Prometheus + Grafana, pre-wired to the host exporters |
| `nextcloud` | LXC | Apache, PHP from Debian, MariaDB, Redis, APCu, cron; fully installed by the script |
| `react` | LXC | Any static front-end (React, Vue, Vite…) built from git with Node.js LTS, served by nginx |
| `n8n` | Docker | Workflow automation |
| `appsmith` | Docker | Internal tools builder |
| `illa` | Docker | ILLA Builder |
| `tolgee` | Docker | Localization platform, bundled PostgreSQL or existing server |
| `chatwoot` | Docker | Customer support, PostgreSQL (pgvector) + Redis |
| `cube` | Docker | Cube semantic layer + Cube Store |
| `ocis` | Docker | ownCloud Infinite Scale (replaces ownCloud 10, alias `owncloud`) |

Several instances of the same app can coexist (`./main.sh create react shop`).

Apps whose first visitor creates the admin account (n8n, Appsmith, ILLA,
Chatwoot) start **restricted to the allow-list**. Create the account, then run
`./main.sh site open <instance>`.

## 📋 Requirements

- A fresh Debian 12 or 13 server with a public IPv4 address, run as root.
- A domain, with a DNS record for each sub-domain (or a wildcard
  `*.example.com`) pointing to the server.
- Ports 80 and 443 reachable from the Internet (Let's Encrypt HTTP-01).

## 💻 Usage

```bash
git clone https://github.com/<you>/cluster-setup-script.git
cd cluster-setup-script
sudo ./main.sh            # interactive menu
```

Or directly:

```bash
sudo ./main.sh setup                      # prepare the server (safe to re-run)
sudo ./main.sh create nextcloud           # install an app
sudo ./main.sh create react blog          # second instance named "blog"
sudo ./main.sh list                       # catalogue + installed instances
sudo ./main.sh site open n8n              # make a restricted site public
sudo ./main.sh allow 203.0.113.7          # add an IP to the allow-list
sudo ./main.sh vpn add phone full         # VPN client, all traffic through the VPN
sudo ./main.sh backup run                 # backup now
sudo ./main.sh update                     # upgrade host, containers and stacks
sudo ./main.sh status
sudo ./main.sh help
```

Generated passwords and secrets are stored in
`/etc/cluster-setup/credentials/<instance>.txt` (root only).
Everything the script prints is logged to `/var/log/cluster-setup.log`
(secrets are never printed to it).

> ⚠️ At the end of `setup`, SSH moves to the chosen port (6845 by default) and
> only accepts the allow-list and the VPN. **Check that you can log in from a
> new terminal before closing your session.**

## 🔒 Security model

- **Inputs** are validated (domains, IPs, ports, names) and never interpolated
  into `sed`, SQL or shell code; templates are filled with plain string
  substitution.
- **Secrets** are generated randomly when left empty, read without echo, stored
  in `0600` files, and passed to containers through files or stdin rather than
  command lines when possible. Commands run in LXC containers with a clean
  environment.
- **SSH**: drop-in config (`/etc/ssh/sshd_config.d/10-cluster-setup.conf`),
  validated with `sshd -t` before restart; only members of `sshusers` can log in.
- **Firewall** (`/etc/cluster-setup/firewall.nft`, service `cluster-firewall`):
  inbound traffic dropped except HTTP(S), SSH from the allow-list, WireGuard;
  exporters only from the LXC bridges; no inbound connection into the bridges
  from the Internet; DMZ and DMZ2 cannot reach each other.
- **Docker apps** only listen on `127.0.0.1` and are published through Nginx.
- **LXC containers** are unprivileged, each with its own UID/GID range.
- **Downloads**: packages come from signed APT repositories; Nextcloud
  archives are checked against their SHA-256; no `curl | bash`.
- **Restricted sites** (`./main.sh site restrict <instance>`) only accept the
  allow-list, the VPN and the server itself.

## 💾 Backups and restore

`./main.sh backup setup` configures [restic](https://restic.net). Supported
targets: any SSH/SFTP server (key generated and installed for you), S3-compatible
storage, restic REST server, local path, or any restic repository string
(for example `rclone:` remotes for FTP).

Daily at 02:00, the backup stops the containers, snapshots `/etc`, `/root`,
`/home`, `/opt/cluster-setup`, `/var/lib/lxc`, `/var/lib/docker/volumes` and
`/var/www`, restarts everything, then applies the retention policy. A partial
integrity check runs every Sunday.

> 🔑 The repository password is in `/etc/cluster-setup/restic.password`.
> **Keep a copy outside the server**: backups cannot be restored without it.

Restore example:

```bash
set -a; source /etc/cluster-setup/backup.env; set +a
restic snapshots
restic restore latest --target /tmp/restore --include /opt/cluster-setup/stacks/n8n
```

## 🔄 Updates

- Host and containers: Debian security updates are installed daily by
  `unattended-upgrades`.
- Docker stacks: images are pulled and containers recreated every Sunday by
  `cluster-docker-update.timer`. Create a file named `.no-auto-update` in a
  stack directory to skip it, and pin versions in the stack's `.env`
  (e.g. `N8N_VERSION=1.x.y`).
- Everything at once: `sudo ./main.sh update`.
- Nextcloud: use the built-in updater (admin panel).
- `react` apps: `lxc-attach -n <instance> -- deploy-app` after a push.

## 🗂️ Files and layout

```
main.sh                  entry point (menu + sub-commands)
lib/common.sh            output, prompts, validation, helpers
lib/config.sh            settings and application registry
lib/host/*.sh            host components (ssh, firewall, nginx, lxc, docker, ...)
lib/apps.sh              application catalogue and creation workflow
lib/apps/*.sh            one installer per application
templates/               nginx, ssh, systemd, compose and app templates
bin/                     tools installed in /usr/local/sbin
```

On the server:

```
/etc/cluster-setup/cluster.conf       settings
/etc/cluster-setup/apps/*.env         installed instances
/etc/cluster-setup/credentials/       generated passwords (root only)
/opt/cluster-setup/stacks/<instance>  Docker stacks (compose.yaml, .env, data)
/var/lib/lxc/<instance>               LXC containers
```

## ⬆️ Upgrading from 1.x

Version 2 is a rewrite. Settings from `/root/domain.txt`, `/root/mail.txt`
and `/root/allowed_ips.txt` are imported by `./main.sh setup`, but containers
and sites created by 1.x are not managed by 2.x. The recommended path is a
fresh server and a data migration. Notable changes:

- LXD (snap) is no longer used; the bridges are created by systemd-networkd.
- `hosts.allow`/`hosts.deny` are replaced by the nftables firewall.
- watchtower is replaced by a systemd timer; ownCloud 10 by oCIS; the FTP
  backup script by restic; the third-party WireGuard installer by a native setup.

See [CHANGELOG.md](CHANGELOG.md).

## ⚠️ Disclaimer

This tool runs as root and changes SSH, firewall and network settings. Read
it before using it, try it on a test server first, and keep backups.
