# DezerX Spartan Installer

Installs, updates and maintains [DezerX Spartan](https://market.dezerx.com) on a Linux server: PHP with ionCube, Nginx, MariaDB or MySQL, Redis, Node.js, Laravel Octane, queue workers, the scheduler and SSL.

Version 2 replaces the whiptail dialogs of 1.x with a full-screen interface, adds automatic rollback for updates and fixes a long list of 1.x problems (see [CHANGELOG.md](CHANGELOG.md)). Paths, service names, `.env` keys, `script_options.json` and every 1.x command line flag stay the same, so existing servers update in place.

## Install

```bash
sudo bash -c "$(curl -fsSL https://github.com/dezerx-spartan/SPARTAN-INSTALLER-NEW/releases/latest/download/spartan_installer.sh)"
```

The wizard asks for the domain, license key, install folder, database, performance settings and SSL, shows a review screen, and only then changes the server. Run it inside `screen` or `tmux` if your SSH connection is unreliable (the installer keeps going if the connection drops, but you lose the view).

### Without prompts

```bash
sudo bash -c "$(curl -fsSL https://github.com/dezerx-spartan/SPARTAN-INSTALLER-NEW/releases/latest/download/spartan_installer.sh)" -- \
  --non-interactive --install --license=SPARTANPROFESSIONAL_XXXX --domain=dash.example.com --ssl-mode=install
```

`--license` and `--domain` are required; everything else has a default (Nginx, MariaDB or the database server that is already installed, a generated database password, Octane on, worker counts from CPU and RAM, Let's Encrypt).

### From a clone

```bash
git clone https://github.com/dezerx-spartan/SPARTAN-INSTALLER-NEW.git
cd SPARTAN-INSTALLER-NEW
sudo bash spartan_installer.sh
```

## Update

Run the same command and choose **Update**, or:

```bash
sudo bash spartan_installer.sh --non-interactive --update --app-dir /var/www/spartan
```

Spartan's built-in automatic updater (`php artisan app:update`) runs exactly this kind of command; it keeps working unchanged.

An update puts the site into maintenance mode, backs up the files, the database and the server configuration to `/var/backups/spartan`, installs the new release, upgrades PHP, Redis and Node.js, migrates and builds. If any step fails after the old version was removed, everything is restored from the backup automatically and the site comes back online.

What is kept is controlled by `script_options.json` in the application folder (same format as 1.x):

```json
{
    "keep":    { "nginx": false, "css": true, "themes": true, "portals": true, "emails": true, "favicon": true },
    "exclude": { "files": [], "folders": [] },
    "delete":  []
}
```

Choices made in the update wizard are written back to `keep`, so automatic updates respect them. Command line flags (`--keep-nginx`, `--no-keep-css`, ...) override the file.

## Requirements

| | |
|---|---|
| Systems | Ubuntu 22.04, 24.04, 26.04 · Debian 12, 13 · AlmaLinux, Rocky Linux, RHEL, Oracle Linux 8 and 9 (others are attempted with a warning) |
| CPU | x86_64 or aarch64 (ionCube) |
| Memory | 2 GB or more recommended; smaller servers get a swap file |
| Disk | 8 GB free recommended, 3 GB minimum |
| Access | root, systemd, outbound HTTPS |

## Actions and options

```text
--install | --update | --uninstall | --setup-perms | --ssl | --health
--restart-services | --support-bundle (alias --upload-logs)
--non-interactive        never prompt
--app-dir PATH           application folder (default /var/www/spartan)
--license KEY  --domain HOST  --email ADDRESS
--ssl-mode install|assume|later
--db-type mariadb|mysql  --db-host --db-port --db-name --db-user --db-pass --db-root-pass
--octane | --no-octane  --octane-workers N  --octane-port PORT  --queue-workers N
--keep-nginx|css|themes|portals|emails|favicon  (and --no-keep-*)
--options-file NAME  --backup-dir PATH  --add-swap [SIZE]  --ipv6 [true|false]
--skip-upgrade  --overwrite  --plain  --ascii  --no-color  --debug  --version  --help
```

`sudo bash spartan_installer.sh --help` describes each one.

## What ends up where

| | |
|---|---|
| Application | `/var/www/spartan` (or `--app-dir`), owned by the Nginx user |
| Nginx site | `/etc/nginx/sites-available/spartan.conf` or `/etc/nginx/conf.d/spartan.conf`, Octane upstream in `/etc/nginx/conf.d/spartan-octane.conf` |
| Services | `dezerx-octane.service`, `dezerx-queue@1..N.service` grouped by `dezerx.target` |
| Scheduler | root's crontab, `* * * * * cd /var/www/spartan && ... php artisan schedule:run` |
| PHP extras | ionCube in `/usr/local/ioncube`, OPcache for Octane, workers and cron in `/etc/dezerx/` |
| Backups | `/var/backups/spartan` (mode 700, the last 7 of each kind) |
| Log | `/var/log/spartan_installer.log` (mode 600, passwords and keys masked) |

## Tools

The **Tools** menu (or the matching flags) can repair ownership and permissions, issue or replace the SSL certificate, restart all services, run a health check (services, database, website, certificate expiry, disk) and write a redacted support bundle to `/root/spartan-support-<date>.tar.gz`.

## Troubleshooting

- Everything the installer runs, and its output, is in `/var/log/spartan_installer.log`. `--debug` also traces every shell command (including secrets).
- The site does not answer: `sudo bash spartan_installer.sh --health`, then `journalctl -u dezerx-octane -n 100` and `/var/log/nginx/dezerx.app-error.log`.
- Let's Encrypt failed during the install: point the domain's A record at the server, open port 80, then `sudo bash spartan_installer.sh --ssl`.
- To preview the interface without changing anything: `bash spartan_installer.sh --demo` (no root needed).

## Development

The installer is split into small modules under `src/` (see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)). From a clone, `spartan_installer.sh` runs the sources directly.

```bash
bash tests/run.sh          # unit tests (no root, nothing on the system changes)
bash tools/lint.sh         # bash -n and shellcheck
bash spartan_installer.sh --demo
bash tools/build.sh        # dist/: bootstrap + single-file bundle + checksum
```

Releasing is described in [docs/RELEASING.md](docs/RELEASING.md).
