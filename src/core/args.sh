declare -a ARG_WARNINGS=()
SPARTAN_ARGS_TEXT=""

arg_error() {
    printf '%s\n' "$*" >&2
    printf 'Run with --help to see all options.\n' >&2
    return 1
}

swap_size_to_mb() {
    local v="${1,,}"
    case "$v" in
        *g) is_uint "${v%g}" && { echo $((${v%g} * 1024)); return 0; } ;;
        *m) is_uint "${v%m}" && { echo "${v%m}"; return 0; } ;;
        *) is_uint "$v" && { echo "$v"; return 0; } ;;
    esac
    return 1
}

parse_args() {
    local -a a=("$@")
    local n=${#a[@]} i=0 opt val has
    SPARTAN_ARGS_TEXT="${*:-}"

    while ((i < n)); do
        opt="${a[i]}"
        i=$((i + 1))
        has=0
        val=""
        if [[ "$opt" == --*=* ]]; then
            val="${opt#*=}"
            opt="${opt%%=*}"
            has=1
        fi

        case "$opt" in
            --app-dir | --license | --domain | --webserver | --db-type | --ssl-mode | --octane-workers | \
                --octane-port | --queue-workers | --options-file | --db-host | --db-port | --db-name | \
                --db-user | --db-pass | --db-root-pass | --email | --backup-dir)
                if ((!has)) && ((i < n)) && [[ "${a[i]}" != --* ]]; then
                    val="${a[i]}"
                    i=$((i + 1))
                    has=1
                fi
                if ((!has)) || [[ -z "$val" ]]; then
                    arg_error "Missing argument for ${opt}"
                    return 1
                fi
                ;;
        esac

        case "$opt" in
            --) ;;
            -h | --help) SHOW_HELP=1 ;;
            -v | --version) SHOW_VERSION=1 ;;
            --non-interactive) NONINTERACTIVE=1 ;;

            --install) ACTION="install" ;;
            --update) ACTION="update" ;;
            --delete | --uninstall) ACTION="uninstall" ;;
            --setup-perms | --repair-perms) ACTION="setup_perms" ;;
            --upload-logs | --support-bundle) ACTION="support_bundle" ;;
            --ssl | --issue-ssl) ACTION="ssl" ;;
            --health | --health-check) ACTION="health" ;;
            --restart-services) ACTION="restart" ;;
            --test | --demo) DEMO=1 ;;

            --app-dir)
                APP_DIR="${val%/}"
                [[ -n "$APP_DIR" ]] || APP_DIR="/"
                USED_APP_DIR=1
                ;;
            --license)
                license_apply_key "$val" || {
                    arg_error "Invalid license key. Spartan keys start with SPARTANSTARTER_, SPARTANPROFESSIONAL_, SPARTANULTIMATE_ or SPARTANDEV_."
                    return 1
                }
                ;;
            --domain) DOMAIN="$(domain_normalize "$val")" ;;
            --webserver)
                case "${val,,}" in
                    nginx) WEB="nginx" ;;
                    apache)
                        arg_error "Apache is not supported. DezerX Spartan runs behind Nginx (--webserver=nginx)."
                        return 1
                        ;;
                    *)
                        arg_error "Unknown/unsupported webserver: ${val}"
                        return 1
                        ;;
                esac
                ;;
            --db-type)
                case "${val,,}" in
                    mariadb | mysql) DB_ENGINE="${val,,}" ;;
                    *)
                        arg_error "Unknown/unsupported database type: ${val} (use mariadb or mysql)"
                        return 1
                        ;;
                esac
                ;;
            --ssl-mode)
                case "${val,,}" in
                    install | letsencrypt) SSL_MODE="install" ;;
                    assume | self-signed | selfsigned) SSL_MODE="assume" ;;
                    later | none | off) SSL_MODE="later" ;;
                    *)
                        arg_error "Invalid ssl mode: ${val} (use install, assume or later)"
                        return 1
                        ;;
                esac
                ;;
            --email)
                email_valid "$val" || { arg_error "Invalid email address: ${val}"; return 1; }
                SSL_EMAIL="$val"
                ;;
            --ipv6)
                if ((!has)) && ((i < n)); then
                    case "${a[i],,}" in
                        true | enable | false | disable | yes | no | on | off | 1 | 0)
                            val="${a[i]}"
                            i=$((i + 1))
                            has=1
                            ;;
                    esac
                fi
                case "${val,,}" in
                    "" | true | enable | yes | on | 1) ENABLE_IPV6=1 ;;
                    false | disable | no | off | 0) ENABLE_IPV6=0 ;;
                    *) ARG_WARNINGS+=("Unsupported value for --ipv6 (${val}), keeping IPv6 enabled.") && ENABLE_IPV6=1 ;;
                esac
                IPV6_FROM_CLI=1
                ;;
            --octane)
                if ((has)); then
                    case "${val,,}" in
                        yes | true | enable | on | 1) OCTANE_CHOICE="yes" OCTANE_ENABLED=1 ;;
                        no | false | disable | off | 0) OCTANE_CHOICE="no" OCTANE_ENABLED=0 ;;
                        *) ARG_WARNINGS+=("Unsupported value for --octane (${val}), enabling Octane.") && OCTANE_CHOICE="yes" OCTANE_ENABLED=1 ;;
                    esac
                else
                    OCTANE_CHOICE="yes"
                    OCTANE_ENABLED=1
                fi
                ;;
            --no-octane) OCTANE_CHOICE="no" OCTANE_ENABLED=0 ;;
            --octane-workers | --queue-workers)
                if ! is_uint "$val" || ((val < 1)); then
                    arg_error "Invalid ${opt#--} count: '${val}'. Expected a positive integer."
                    return 1
                fi
                if [[ "$opt" == --octane-workers ]]; then OCTANE_WORKERS="$val"; else QUEUE_WORKERS="$val"; fi
                ;;
            --octane-port)
                if ! is_uint "$val" || ((val < 2000 || val > 65535)); then
                    arg_error "Invalid Octane port: '${val}'. Expected a number between 2000 and 65535."
                    return 1
                fi
                OCTANE_PORT="$val"
                ;;
            --keep-nginx | --keep-css | --keep-themes | --keep-portals | --keep-emails | --keep-favicon)
                local k="${opt#--keep-}"
                k="${k^^}"
                printf -v "KEEP_${k}" '%s' 1
                KEEP_FROM_CLI[$k]=1
                ;;
            --no-keep-nginx | --no-keep-css | --no-keep-themes | --no-keep-portals | --no-keep-emails | --no-keep-favicon)
                local k="${opt#--no-keep-}"
                k="${k^^}"
                printf -v "KEEP_${k}" '%s' 0
                KEEP_FROM_CLI[$k]=1
                ;;
            --options-file) OPTIONS_JSON_NAME="$val" ;;
            --add-swap)
                if ((!has)) && ((i < n)) && [[ "${a[i]}" =~ ^[0-9]+[MmGg]?$ ]]; then
                    val="${a[i]}"
                    i=$((i + 1))
                    has=1
                fi
                if ((has)); then
                    SWAP_SIZE_MB="$(swap_size_to_mb "$val")" || {
                        arg_error "Invalid swap size: ${val} (examples: 2048, 2048M, 2G)"
                        return 1
                    }
                fi
                FORCE_SWAP=1
                ;;

            --db-host) DB_HOST="$val" ;;
            --db-port)
                port_valid "$val" || { arg_error "Invalid database port: ${val}"; return 1; }
                DB_PORT="$val"
                ;;
            --db-name)
                db_ident_valid "$val" || { arg_error "Invalid database name: ${val} (letters, digits and _ only)"; return 1; }
                DB_NAME="$val"
                ;;
            --db-user)
                db_ident_valid "$val" || { arg_error "Invalid database user: ${val} (letters, digits and _ only)"; return 1; }
                DB_USER="$val"
                ;;
            --db-pass) DB_PASS="$val" ;;
            --db-root-pass) DB_ROOT_PASS="$val" ;;
            --backup-dir) BACKUP_DIR="${val%/}" ;;
            --skip-upgrade | --no-upgrade) SKIP_UPGRADE=1 ;;
            --overwrite) OVERWRITE=1 ;;
            --plain | --no-tui) FORCE_PLAIN=1 ;;
            --ascii) FORCE_ASCII=1 ;;
            --no-color) UI_NO_COLOR=1 ;;
            --debug) DEBUG=1 ;;
            *) ARG_WARNINGS+=("Unknown option: ${opt}") ;;
        esac
    done

    secret_add "$LICENSE_KEY" "$DB_PASS" "$DB_ROOT_PASS"
    SPARTAN_ARGS_TEXT="$(mask "$SPARTAN_ARGS_TEXT")"
    return 0
}

show_help() {
    cat <<EOF
${TITLE} ${SPARTAN_VERSION}

Usage: spartan_installer.sh [ACTION] [OPTIONS]

Run without options for the interactive installer.

Actions:
  --install                 Install DezerX Spartan
  --update                  Update an existing installation
  --uninstall, --delete     Remove an installation (interactive only)
  --setup-perms             Repair file ownership and permissions
  --ssl                     Issue a Let's Encrypt certificate for an installation
  --health                  Check services, database, HTTP and certificate
  --restart-services        Restart PHP-FPM, Nginx, Octane, queue workers and Redis
  --support-bundle          Write a redacted diagnostics archive (alias: --upload-logs)

General:
  --non-interactive         Never prompt; use flags and defaults (one-line installs,
                            automatic updates)
  --app-dir PATH            Application directory (default ${APP_DEFAULT_DIR})
  --plain                   Line-by-line output instead of the full-screen interface
  --ascii, --no-color       Plain characters / no colours
  --skip-upgrade            Do not upgrade the operating system packages
  --debug                   Trace every command into the log (includes secrets)
  -v, --version             Print the installer version
  -h, --help                Show this help

Install:
  --license KEY             DezerX Spartan license key (required)
  --domain HOST             Domain for the site, APP_URL and SSL (required)
  --ssl-mode MODE           install (Let's Encrypt, default), assume (self-signed)
                            or later (HTTP only)
  --email ADDRESS           Let's Encrypt account email (default admin@DOMAIN)
  --db-type ENGINE          mariadb (default) or mysql; an existing server is reused
  --db-host, --db-port, --db-name, --db-user, --db-pass
                            Database settings (defaults 127.0.0.1, 3306, dezerx,
                            dezer, random password)
  --db-root-pass PASS       Root password when root cannot log in through the socket
  --webserver nginx         Accepted for compatibility; Nginx is the only option
  --overwrite               Replace an existing installation in --app-dir (a backup
                            is taken first)

Performance:
  --octane, --no-octane     Laravel Octane (RoadRunner) on or off (default on)
  --octane-workers N        Octane HTTP workers (default: from CPU and RAM)
  --octane-port PORT        Port Octane listens on (default: first free from 8000)
  --queue-workers N         Queue workers, run as dezerx-queue@1..N (default: auto)
  --add-swap [SIZE]         Create a permanent swap file (default 2048M; 2G also works)
  --ipv6 [true|false]       Keep IPv6 enabled. Without it IPv6 is disabled system-wide,
                            as in 1.x (never on IPv6-only servers)

Update:
  --keep-nginx, --keep-css, --keep-themes, --keep-portals, --keep-emails,
  --keep-favicon            Keep these customisations (--no-keep-* to drop them)
  --options-file NAME       Options file inside the app directory
                            (default ${OPTIONS_JSON_NAME})
  --backup-dir PATH         Where backups go (default ${BACKUP_DIR}, 7 kept per type)

Examples:
  sudo bash spartan_installer.sh
  sudo bash spartan_installer.sh --non-interactive --install --license KEY \\
       --domain dash.example.com --ssl-mode install
  sudo bash spartan_installer.sh --non-interactive --update --app-dir /var/www/spartan

Log file: ${LOG}
EOF
}
