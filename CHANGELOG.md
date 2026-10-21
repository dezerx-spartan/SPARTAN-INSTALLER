# Changelog

## 2.0.0-beta.10

### New

- PostgreSQL as a third database choice (`--db-type postgresql`, also `postgres` or `pgsql`; the wizard lists it next to MariaDB and MySQL). DezerX Spartan needs PostgreSQL 13 or newer: Debian and Ubuntu install the distribution's version, AlmaLinux/Rocky/RHEL 8 and 9 enable the newest `postgresql` module stream. The database is created with the `citext` extension, the PHP `pgsql` extension is installed, `.env` gets `DB_CONNECTION=pgsql` and the port defaults to 5432.
- Everything that handles the database works for PostgreSQL too: connection checks, tuning (`shared_buffers`, `effective_cache_size` and slow-query logging through `ALTER SYSTEM`), backups with `pg_dump`, the automatic restore on a failed update, the size check before backups, the health check, the support bundle and the uninstaller.
- On RHEL-family systems, `pg_hba.conf` is switched from `ident` to password logins for 127.0.0.1 and ::1 so the application can connect (a copy is kept as `pg_hba.conf.spartan.bak`).

### Changed

- The database server screen is shown for every install, so an existing MariaDB or MySQL server no longer rules out PostgreSQL. An installed server is preselected and reused. Without `--db-type`, non-interactive installs keep choosing the installed MariaDB/MySQL server, or MariaDB.

## 2.0.0-beta.9

### Changed

- Valkey replaces Redis. New installs get Valkey (Debian 12 from bookworm-backports); Ubuntu 22.04 has no Valkey package and keeps Redis.
- Updates switch a local Redis to Valkey: the queue workers stop, Redis saves a snapshot, Valkey loads it, the password is carried over and the redis-server package is removed (its data stays in /var/lib/redis). When Valkey cannot read the snapshot (Redis 8 on Debian 13), the keys are copied one by one through a temporary Redis. External Redis servers are left as they are.
- The frontend is installed and built with pnpm 10 instead of npm (npm-style hoisted node_modules; an existing package-lock.json is imported so the versions stay the same).

## 2.0.0-beta.8

### Changed

- No check marks anywhere: the final screen title, its summary lines, the health check, the DNS status and the line-mode task list print plain text (finished tasks use the blue dot); checkboxes show a dot.
- Code comments were removed from the sources and the release bundle.
- The repository moved to dezerx-spartan/SPARTAN-INSTALLER; the bootstrap and bundle download from there.

### Removed

- The docs/ and tests/ folders.

## 2.0.0-beta.7

### Changed

- Finished steps in the progress view show a blue dot instead of a check mark.
- Ubuntu 26.04 and newer get PHP 8.5.

## 2.0.0-beta.6

### Changed

- The system checks on the welcome screen no longer show a check mark for passing items.

## 2.0.0-beta.5

### Changed

- The header sits three rows higher above the dialog.

## 2.0.0-beta.4

### Changed

- The header now sits directly above the dialog instead of at the top of the screen.
- The progress bar no longer shows "Done" when finished.

## 2.0.0-beta.3

### Changed

- New header in place of the blue title bar: the DezerX logo (drawn from the official artwork; ASCII on consoles without UTF-8) with the name, version, website and Discord link beside it, and a progress bar that follows the wizard steps, then the installation or update, and ends green or red.
- A tab above each dialog shows which part of the installer it belongs to: Installer, Updater, Uninstaller or Tools.
- The progress view drops its own bar (the header shows the progress) and is two rows shorter, so more steps fit on small terminals.

## 2.0.0-beta.2

### Fixed

- Database backups failed with `mariadb-dump: unknown variable 'connect-timeout=10'` (also `mysqldump`). The installer's private credentials file set `connect-timeout` for all client tools; it now applies only to the `mysql`/`mariadb` client.

## 2.0.0-beta.1

First test build of 2.0.0. A rewrite of the 1.x installer (last release: 1.6.4 "Theme Fixes"). The behaviour of 1.x is kept unless listed here; existing installations are updated in place.

### New

- Full-screen interface in the DezerX colours: header with the step counter, centred dialogs, key hints, spinners and a progress view instead of scrolling command output. Falls back to line prompts on small terminals or with `--plain`, and to plain text output when there is no terminal (automatic updates).
- Review screen before anything changes; nothing on the server is touched while you go through the wizard.
- Automatic rollback when an update fails: application files, database, PHP/ionCube/Nginx settings, service units and the crontab are restored from the backup taken at the start of the update.
- Existing installations are detected (services, cron entry, Nginx site) and offered for update.
- Tools: health check, SSL certificate, restart services, support bundle (replaces the "upload logs" item that never worked).
- `--demo` (alias `--test`) shows every screen with simulated work, without root.
- New flags: `--db-host`, `--db-port`, `--db-name`, `--db-user`, `--db-pass`, `--db-root-pass`, `--email`, `--backup-dir`, `--no-keep-*`, `--skip-upgrade`, `--overwrite`, `--ssl`, `--health`, `--restart-services`, `--support-bundle`, `--plain`, `--ascii`, `--no-color`, `--debug`, `--version`.
- Firewall: ports 80 and 443 are opened in an active firewalld or ufw.
- SELinux (AlmaLinux, Rocky, RHEL, Fedora): Nginx may connect to Octane and PHP may write to `storage/`.
- The PHP IMAP extension is installed (Spartan's e-mail piping needs it).
- Single-instance lock, log rotation, secrets masked in the log.

### Fixed

- Installing into a folder that was not empty deleted everything in it (for example `/var/www`). System folders and non-empty folders are now refused; replacing an existing installation asks first and takes a backup.
- Cancelling an update after it started left the site in maintenance mode; so did a failing database check. Maintenance mode now starts after confirmation and is always lifted.
- Backups were written to `/tmp/spartan`: world-readable and cleared on reboot. They now live in `/var/backups/spartan` (mode 700); old ones are moved there.
- The database password appeared in the log and in the process list (`mysql -p...`). Credentials are passed through a private option file and secrets are masked in the log, which is now mode 600.
- A failed `mysqldump` still produced a "successful" backup (the pipe hid the error). Dumps are checked for completeness; `--no-tablespaces` avoids the MySQL 8 PROCESS privilege error that broke backups.
- Rolling back left tables created by the failed update in place; the database is emptied before the dump is restored.
- `.env` merging on update dropped every key that was not in `.env.example`. The existing file is now kept as it is and only new keys are appended.
- Let's Encrypt failures produced an HTTPS site pointing at missing certificates and Nginx went down. The site now stays on HTTP and `--ssl` retries later.
- Renewed certificates were never loaded because Nginx was not reloaded; a renewal hook now reloads it.
- `nginx -t` failures were ignored before restarting. A failing configuration is rolled back and the running site keeps working.
- The `.env` file was world-readable (`chmod -R 755`); it is now 640, and files no longer get the execute bit.
- `listen ... http2` (deprecated since Nginx 1.25.1) is replaced by `http2 on;` on current Nginx.
- The documented one-liner with appended flags failed in 1.6.x (the flags ended up after `fi`); the bootstrap now passes them through.
- Startup crashed when the GitHub API was rate limited (version lookup). The version is now part of the release.
- The whole system was upgraded before the menu appeared, even for "uninstall". Package work now happens after confirmation.
- apt could hang on a configuration file question or fail on a held dpkg lock; it now waits for the lock and keeps local configuration files.
- `curl` and `curl-minimal` conflicted on EL9; only missing tools are installed.
- A MySQL root password was never asked for when needed (inverted condition), and choosing MySQL on Debian failed (Debian only ships MariaDB). An installed database server is now reused instead of being replaced.
- Re-running the installer with an existing database user did not update its password.
- `CREATE USER` was created on the local server even for remote database hosts.
- Choosing Apache exited silently; it is rejected with an explanation.
- Disabling IPv6 (the 1.x default) could cut off IPv6-only servers, kill an SSH session connected over IPv6, or stop Nginx when other sites listen on IPv6. These cases are detected; the default is otherwise unchanged.
- `--add-swap` swallowed the next flag and treated plain numbers wrongly; plain numbers are megabytes.
- Swap files failed on btrfs and some XFS setups.
- Keep flags given on the command line were overridden by `script_options.json`, and choices from the wizard were never saved, so automatic updates ignored them.
- `delete` entries in `script_options.json` were removed from the old version just before it was wiped (no effect); they are now removed from the new version.
- Portals, themes and modules are moved instead of copied when they are set aside, which is much faster with large `storage/` folders.
- Rolling back rebuilt everything with Composer and npm, which failed for the same reasons the update had. The backup already contains `vendor/` and the built assets.
- Waiting for Octane required a `/up` route; any HTTP answer now counts.
- Octane picked a new port on every update when the port was not passed on the command line.
- NodeSource failures stopped the install even when the distribution's Node.js was new enough.
- The ionCube temporary folder could be deleted early by a leftover `RETURN` trap.
- Several PHP versions installed side by side: the `php` command now points to the one Spartan uses.
- Upgrading PHP to a new minor version left the new PHP-FPM pool running as the wrong user (502 errors); the pool user is set on every update.
- "setup perms" from the menu ignored the installation folder.
- apt output was parsed in the system language; the installer now runs with a neutral locale.

### Changed

- Backups: `/var/backups/spartan` instead of `/tmp/spartan` (use `--backup-dir` to choose).
- The release ships `spartan_installer.sh` (a small bootstrap) and `spartan_installer.bundle.sh` (the installer), plus its checksum. The bootstrap downloads the bundle of its own release and verifies it.
- `--webserver` only accepts `nginx`; `--ssl-mode`, `--webserver` and `--db-type` are optional for non-interactive installs.
- Uninstalling can also remove the database, backups and certificate (all off by default) and takes a final backup first.
