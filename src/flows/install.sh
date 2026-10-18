INSTALL_EXISTING_SPARTAN=0

scr_install_welcome() {
    local text
    text="Welcome to the DezerX Spartan installer.

This installer will:
  - Install PHP ${PHP_VER} with ionCube, Nginx, MariaDB or MySQL, $(kv_target_name) and Node.js
  - Download DezerX Spartan with your license key
  - Set up Octane, queue workers and the scheduler
  - Secure your domain with a free Let's Encrypt certificate

Nothing changes on this server until you confirm on the review screen, and you can go back at any point before that.

$(preflight_summary)"
    if [[ -n "$PRE_BLOCKER" ]]; then
        ui_error "Cannot install" "$(tx "$PRE_BLOCKER")\n\n$(preflight_summary)" "${G_BACK} Back"
        return 1
    fi
    ui_nav "Welcome" "$text"
}

_validate_domain() {
    local d
    d="$(domain_normalize "${FORM_VALUES[0]}")"
    if [[ -z "$d" ]]; then
        FORM_ERROR="Enter a domain, for example dash.example.com."
        return 1
    fi
    if ! domain_valid "$d"; then
        FORM_ERROR="\"${d}\" is not a valid domain name."
        return 1
    fi
    FORM_VALUES[0]="$d"
}

scr_install_domain() {
    while :; do
        form_reset
        form_add "Domain" "${DOMAIN}" text "Without http:// - e.g. dash.example.com"
        FORM_VALIDATE=_validate_domain
        ui_form "Domain" "Which domain will DezerX Spartan run on? It is used for the Nginx site, APP_URL and the SSL certificate. Point its DNS A record to this server." || return $?
        DOMAIN="${FORM_VALUES[0]}"
        ui_busy "Checking DNS for ${DOMAIN}${G_ELLIPSIS}" dns_check "$DOMAIN"
        case "$DNS_STATUS" in
            ok | ip | unknown) return 0 ;;
            proxied)
                ui_confirm "DNS" "$(dns_status_text "$DOMAIN")\n\nCertificate validation usually works through the proxy. If it fails, switch the record to DNS only (grey cloud) while installing." \
                    "Continue" "${G_BACK} Back" yes && return 0
                ;;
            *)
                ui_confirm "DNS" "$(dns_status_text "$DOMAIN")\n\nYou can continue, but Let's Encrypt cannot issue a certificate until the domain points here. You can add SSL later with: {b}--ssl{/}" \
                    "Continue" "${G_BACK} Back" no && return 0
                ;;
        esac
    done
}

_validate_license() {
    local k
    k="$(trim "${FORM_VALUES[0]}")"
    if [[ -z "$k" ]]; then
        FORM_ERROR="Enter your DezerX Spartan license key."
        return 1
    fi
    if ! license_apply_key "$k"; then
        FORM_ERROR="That is not a Spartan license key (they start with SPARTAN...)."
        return 1
    fi
    if have curl; then
        if ! ui_busy "Verifying your license${G_ELLIPSIS}" license_verify; then
            FORM_ERROR="$(text_strip "$(tx "${LICENSE_MSG:-The license could not be verified.}")")"
            return 1
        fi
    fi
    return 0
}

scr_install_license() {
    form_reset
    form_add "License key" "$LICENSE_KEY" password "Your key from market.dezerx.com"
    FORM_VALIDATE=_validate_license
    ui_form "License" "Enter your DezerX Spartan license key. It is checked against ${DOMAIN} with the DezerX market." || return $?
    return 0
}

_validate_app_dir() {
    local d="${FORM_VALUES[0]%/}"
    [[ -n "$d" ]] || d="/"
    if [[ "$d" != /* ]]; then
        FORM_ERROR="Enter an absolute path, for example ${APP_DEFAULT_DIR}."
        return 1
    fi
    if [[ "$d" == *[[:space:]]* ]]; then
        FORM_ERROR="The path cannot contain spaces."
        return 1
    fi
    if path_is_protected "$d"; then
        FORM_ERROR="${d} is a system directory. Use a dedicated folder such as ${APP_DEFAULT_DIR}."
        return 1
    fi
    INSTALL_EXISTING_SPARTAN=0
    if ! dir_is_empty "$d"; then
        if app_looks_like_spartan "$d"; then
            INSTALL_EXISTING_SPARTAN=1
        else
            FORM_ERROR="${d} is not empty. Pick an empty or new directory."
            return 1
        fi
    fi
    FORM_VALUES[0]="$d"
}

scr_install_location() {
    while :; do
        form_reset
        form_add "Directory" "$APP_DIR" text "The web root will be <directory>/public"
        FORM_VALIDATE=_validate_app_dir
        ui_form "Location" "Where should DezerX Spartan be installed?" || return $?
        APP_DIR="${FORM_VALUES[0]}"
        if ((INSTALL_EXISTING_SPARTAN)); then
            if ui_confirm "Existing installation" "DezerX Spartan is already installed in {b}$(tx "$APP_DIR"){/}.\n\nTo keep its data, choose {b}Update{/} in the main menu instead. Replacing it backs up the directory to ${BACKUP_DIR} and installs from scratch (the database is kept)." \
                "Replace it" "${G_BACK} Back" no; then
                OVERWRITE=1
                return 0
            fi
            continue
        fi
        OVERWRITE=0
        return 0
    done
}

scr_install_db_engine_applies() { [[ -z "$EXISTING_DB_SERVER" ]] && db_is_local; }

scr_install_db_engine() {
    local -a items=(mariadb "MariaDB" "Recommended")
    if db_mysql_available 2>/dev/null; then
        items+=(mysql "MySQL" "Oracle MySQL server")
    fi
    ui_radio "Database server" "No database server is installed yet. Which one should be installed?" "${DB_ENGINE:-mariadb}" "${items[@]}" || return $?
    DB_ENGINE="$UI_RESULT"
}

_validate_db_form() {
    local host="${FORM_VALUES[0]}" port="${FORM_VALUES[1]}" name="${FORM_VALUES[2]}" user="${FORM_VALUES[3]}"
    local pass="${FORM_VALUES[4]}" pass2="${FORM_VALUES[5]}"
    [[ -n "$host" ]] || { FORM_ERROR="Enter the database host."; FORM_ERROR_FIELD=0; return 1; }
    port_valid "$port" || { FORM_ERROR="The port must be a number between 1 and 65535."; FORM_ERROR_FIELD=1; return 1; }
    db_ident_valid "$name" || { FORM_ERROR="Database names may contain letters, digits and _ only."; FORM_ERROR_FIELD=2; return 1; }
    db_ident_valid "$user" || { FORM_ERROR="User names may contain letters, digits and _ only."; FORM_ERROR_FIELD=3; return 1; }
    if [[ "$user" == root ]]; then
        FORM_ERROR="Use a dedicated user, not root."
        FORM_ERROR_FIELD=3
        return 1
    fi
    if [[ "$pass" != "$pass2" ]]; then
        FORM_ERROR="The passwords do not match."
        FORM_ERROR_FIELD=5
        return 1
    fi
    return 0
}

_validate_root_pw() {
    DB_ROOT_PASS="${FORM_VALUES[0]}"
    secret_add "$DB_ROOT_PASS"
    if ! ui_busy "Checking the root password${G_ELLIPSIS}" db_root_sql "SELECT 1;"; then
        FORM_ERROR="That password does not work for root."
        return 1
    fi
}

_db_remote_check() {
    have mysql || have mariadb || return 0
    if ! ui_busy "Connecting to ${DB_HOST}:${DB_PORT}${G_ELLIPSIS}" db_check_connection; then
        ui_error "Database" "Could not connect to {b}$(tx "${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME}"){/}.\n\nFor a remote database server the database and user must already exist and accept connections from this server." "${G_BACK} Back"
        return 1
    fi
}

scr_install_database() {
    while :; do
        local text="Database connection for DezerX Spartan. Leave the password empty to generate a strong one."
        if [[ -n "$EXISTING_DB_SERVER" ]]; then
            text="$(db_server_label) is installed and will be used.\n\n${text}"
        fi
        form_reset
        form_add "Host" "$DB_HOST" text "127.0.0.1 installs and configures a local server"
        form_add "Port" "$DB_PORT" number
        form_add "Database" "$DB_NAME" text
        form_add "User" "$DB_USER" text
        local pw=""
        ((DB_PASS_GENERATED)) || pw="$DB_PASS"
        form_add "Password" "$pw" password "Empty = generate a 32 character password"
        form_add "Confirm" "$pw" password
        FORM_VALIDATE=_validate_db_form
        ui_form "Database" "$text" || return $?
        DB_HOST="${FORM_VALUES[0]}" DB_PORT="${FORM_VALUES[1]}" DB_NAME="${FORM_VALUES[2]}" DB_USER="${FORM_VALUES[3]}"
        if [[ -z "${FORM_VALUES[4]}" ]]; then
            DB_PASS="$(random_password)"
            DB_PASS_GENERATED=1
        else
            DB_PASS="${FORM_VALUES[4]}"
            DB_PASS_GENERATED=0
        fi
        secret_add "$DB_PASS"

        if ! db_is_local; then
            _db_remote_check && return 0
            continue
        fi
        if [[ -n "$EXISTING_DB_SERVER" ]] && ! db_root_access_ok; then
            form_reset
            form_add "Root password" "" password
            FORM_VALIDATE=_validate_root_pw
            ui_form "Database" "Root cannot log in to $(db_server_label) through the local socket. Enter the database root password so the installer can create the database and user. It is not stored." || continue
        fi
        return 0
    done
}

_perf_on_change() {
    if [[ "${FORM_VALUES[0]}" == Enabled ]]; then FORM_DISABLED[1]=0; else FORM_DISABLED[1]=1; fi
}

_validate_perf() {
    if [[ "${FORM_VALUES[0]}" == Enabled ]]; then
        is_uint "${FORM_VALUES[1]}" && ((FORM_VALUES[1] >= 1 && FORM_VALUES[1] <= 64)) || {
            FORM_ERROR="HTTP workers: a number from 1 to 64."
            FORM_ERROR_FIELD=1
            return 1
        }
    fi
    is_uint "${FORM_VALUES[2]}" && ((FORM_VALUES[2] >= 1 && FORM_VALUES[2] <= 32)) || {
        FORM_ERROR="Queue workers: a number from 1 to 32."
        FORM_ERROR_FIELD=2
        return 1
    }
}

scr_performance() {
    detect_resources
    local rec_o rec_q cur_o cur_q
    rec_o="$(recommend_octane_workers)"
    rec_q="$(recommend_queue_workers)"
    cur_o="${OCTANE_WORKERS:-$rec_o}"
    cur_q="${QUEUE_WORKERS:-$rec_q}"
    local mem_gb
    mem_gb="$(awk -v m="$MEM_TOTAL_MB" 'BEGIN { printf "%.1f", m / 1024 }')"
    form_reset
    local oct="Enabled"
    octane_wanted || oct="Disabled"
    form_add "Laravel Octane" "$oct" choice "Enabled|Disabled" "Keeps the app in memory: typically 3-8x faster than PHP-FPM"
    form_add "HTTP workers" "$cur_o" number "Each uses about 100-150 MB of RAM"
    form_add "Queue workers" "$cur_q" number "Each uses about 150-200 MB of RAM"
    FORM_ON_CHANGE=_perf_on_change
    FORM_VALIDATE=_validate_perf
    _perf_on_change
    ui_form "Performance" "This server has ${CPU_CORES} CPU core(s) and ${mem_gb} GB RAM. Recommended: ${rec_o} HTTP workers and ${rec_q} queue workers." || return $?
    if [[ "${FORM_VALUES[0]}" == Enabled ]]; then
        OCTANE_ENABLED=1
        OCTANE_WORKERS="${FORM_VALUES[1]}"
    else
        OCTANE_ENABLED=0
    fi
    OCTANE_CHOICE="set"
    QUEUE_WORKERS="${FORM_VALUES[2]}"
    return 0
}

_ssl_on_change() {
    if [[ "${FORM_VALUES[0]}" == "Let's Encrypt" ]]; then FORM_DISABLED[1]=0; else FORM_DISABLED[1]=1; fi
}

_validate_ssl() {
    if [[ "${FORM_VALUES[0]}" == "Let's Encrypt" ]] && ! email_valid "${FORM_VALUES[1]}"; then
        FORM_ERROR="Enter a valid email address for Let's Encrypt."
        FORM_ERROR_FIELD=1
        return 1
    fi
}

scr_install_ssl() {
    local cur="Let's Encrypt"
    case "$SSL_MODE" in
        assume) cur="Self-signed" ;;
        later) cur="None (HTTP)" ;;
    esac
    domain_is_ip "$DOMAIN" && [[ "$cur" == "Let's Encrypt" ]] && cur="Self-signed"
    form_reset
    form_add "Certificate" "$cur" choice "Let's Encrypt|Self-signed|None (HTTP)" "Let's Encrypt is free and renews automatically"
    form_add "Email" "${SSL_EMAIL:-admin@${DOMAIN}}" text "Let's Encrypt sends account notices here"
    FORM_ON_CHANGE=_ssl_on_change
    FORM_VALIDATE=_validate_ssl
    _ssl_on_change
    ui_form "SSL" "How should ${DOMAIN} be secured?\n\n$(dns_status_text "$DOMAIN")" || return $?
    case "${FORM_VALUES[0]}" in
        "Let's Encrypt") SSL_MODE="install" SSL_EMAIL="${FORM_VALUES[1]}" ;;
        Self-signed) SSL_MODE="assume" ;;
        *) SSL_MODE="later" ;;
    esac
    return 0
}

install_review_text() {
    local db octane ssl t
    if db_is_local; then
        if [[ -n "$EXISTING_DB_SERVER" ]]; then db="$(db_server_label) (installed)"; else db="$(db_server_label "${DB_ENGINE:-mariadb}" "")"; fi
    else
        db="remote server"
    fi
    db+=", ${DB_NAME} on ${DB_HOST}:${DB_PORT} as ${DB_USER}"
    if octane_wanted; then octane="Octane, ${OCTANE_WORKERS} HTTP workers, ${QUEUE_WORKERS} queue workers"; else octane="PHP-FPM, ${QUEUE_WORKERS} queue workers"; fi
    case "$SSL_MODE" in
        install) ssl="Let's Encrypt (${SSL_EMAIL:-admin@${DOMAIN}})" ;;
        assume) ssl="Self-signed certificate" ;;
        *) ssl="None, HTTP only" ;;
    esac
    t="Review your settings. Nothing has been changed yet.\n\n"
    t+="  {d}Domain       {/}$(tx "$DOMAIN")\n"
    t+="  {d}License      {/}${PRODUCT_NAME} ($(license_masked))\n"
    t+="  {d}Location     {/}$(tx "$APP_DIR")\n"
    t+="  {d}Database     {/}$(tx "$db")\n"
    t+="  {d}Stack        {/}PHP ${PHP_VER}, ionCube, Nginx, $(kv_target_name), Node.js LTS\n"
    t+="  {d}Performance  {/}${octane}\n"
    t+="  {d}SSL          {/}${ssl}\n"
    t+="\nThe installer will also:\n"
    ((SKIP_UPGRADE)) || t+="  - Upgrade the system packages\n"
    ((OVERWRITE)) && t+="  - {w}Back up and replace the existing installation in $(tx "$APP_DIR"){/}\n"
    local p80
    p80="$(port_owner 80)"
    [[ "$p80" == apache2 || "$p80" == httpd ]] && t+="  - Stop and disable Apache (it holds port 80)\n"
    local swap
    swap="$(swap_needed_mb)"
    ((swap > 0)) && t+="  - Add a ${swap} MB swap file\n"
    if ((ENABLE_IPV6 == 0)) && [[ ! -f "$IPV6_SYSCTL" ]]; then
        t+="  - Disable IPv6 system-wide, like previous versions (--ipv6 keeps it)\n"
    fi
    case "$(firewall_kind)" in
        firewalld) t+="  - Open ports 80 and 443 in firewalld\n" ;;
        ufw) t+="  - Open ports 80 and 443 in ufw\n" ;;
    esac
    selinux_enforcing && t+="  - Add SELinux rules for Nginx and PHP\n"
    printf '%s' "${t%\\n}"
}

scr_install_review() {
    ui_nav "Review" "$(install_review_text)" "Install ${G_NEXT}"
}

ph_prepare() {
    task "Refreshing package lists" pkg_refresh || return 1
    if ((!SKIP_UPGRADE)); then
        task "Upgrading system packages" pkg_upgrade || return 1
    fi
    task "Installing required tools" install_essentials || return 1
    task_try "Synchronising the clock" time_sync
    if (($(swap_needed_mb) > 0)); then
        task_try "Adding a swap file" swap_ensure_permanent
    fi
    return 0
}

PRESERVED_APP_KEY=""

install_prepare_dir() {
    if [[ -e "$APP_DIR" ]] && ! dir_is_empty "$APP_DIR"; then
        ((OVERWRITE)) || { phase_fail "${APP_DIR} is not empty."; return 1; }
        app_looks_like_spartan "$APP_DIR" || [[ -n "${SPARTAN_FORCE_OVERWRITE:-}" ]] || {
            phase_fail "${APP_DIR} is not empty and does not contain DezerX Spartan."
            return 1
        }
        PRESERVED_APP_KEY="$(env_read_value APP_KEY)"
        secret_add "$PRESERVED_APP_KEY"
        backup_prepare_dir || return 1
        task "Backing up the existing installation" create_app_backup || return 1
        task "Stopping the old services" remove_spartan_services || true
        task "Removing the existing installation" safe_rm_rf "$APP_DIR" || return 1
    fi
    mkdir -p "$APP_DIR"
}

ph_download() {
    download_release || return 1
    task "Preparing ${APP_DIR}" install_prepare_dir || return 1
    task "Deploying the release" release_deploy || return 1
}

ph_php() {
    task "Adding the PHP repository" php_enable_repo || return 1
    task "Installing PHP ${PHP_VER} and extensions" php_install_packages || return 1
    php_octane_requirements >/dev/null || true
    install_ioncube || return 1
    task "Installing Composer" install_composer || return 1
}

ph_webserver() {
    task "Installing Nginx" install_nginx || return 1
    task "Making port 80 available" no_apache || true
}

ph_node() { install_nodejs; }

ph_database() {
    if db_is_local; then
        task "Installing the database server" install_db_engine || return 1
        task_try "Tuning the database" config_db_tuning
        task "Creating database ${DB_NAME} and user ${DB_USER}" db_create || return 1
    elif ! have mysql && ! have mariadb; then
        task "Installing the database client" pkg_install_any mariadb-client default-mysql-client mysql-client mariadb || return 1
    fi
    task "Testing the database connection" db_check_connection || {
        phase_fail "DezerX Spartan cannot connect to ${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME}."
        return 1
    }
}

ph_redis() { task "Installing $(kv_target_name)" install_valkey; }

ph_app() {
    detect_web_user_group
    task "Configuring PHP-FPM" config_php_fpm || return 1
    task "Configuring OPcache" config_opcache || return 1
    task_try "Applying network settings" config_network
    task "Writing the .env file" app_env_setup || return 1
    task "Choosing cache and queue drivers" configure_cache_queue_drivers || return 1
    task "Installing PHP dependencies (Composer)" app_composer_install || return 1
    task "Installing frontend dependencies (pnpm)" app_pnpm_install || return 1
    task "Building the dashboard" app_pnpm_build || return 1
    task "Entering maintenance mode" app_maintenance_on || true
    if [[ -n "$PRESERVED_APP_KEY" ]]; then
        env_write_value APP_KEY "$PRESERVED_APP_KEY"
    else
        task "Generating the application key" artisan key:generate --force || return 1
    fi
    task "Creating the database tables" artisan migrate --force || return 1
    task "Seeding the database" artisan db:seed --force || return 1
    task "Linking storage" app_storage_link || true
}

ph_services() {
    setup_octane || return 1
    task "Setting file permissions" apply_permissions || return 1
    task "Scheduling Laravel's task runner (cron)" setup_cron || return 1
    task "Starting ${QUEUE_WORKERS} queue worker(s)" setup_systemd_queue || return 1
    task "Configuring the Nginx site" configure_nginx http || return 1
    task_try "Opening ports 80 and 443" firewall_open_web
    if selinux_enforcing; then
        task_try "Applying SELinux rules" selinux_configure
    fi
    return 0
}

ph_ssl() { ssl_apply; }

ph_finish() {
    task "Writing ${OPTIONS_JSON_NAME}" opts_ensure || true
    task "Clearing caches" app_optimize_clear || true
    if octane_wanted; then
        task "Starting Octane" restart_octane || warn_add "Octane did not start; check: journalctl -u dezerx-octane -n 100"
    fi
    task "Leaving maintenance mode" app_maintenance_off || true
    task "Checking the database connection" db_check_connection || warn_add "The database connection test failed."
    task "Checking the website" smoke_test || warn_add "The website did not answer as expected; see /var/log/nginx/dezerx.app-error.log."
    return 0
}

install_plan() {
    plan_new "Installing DezerX Spartan"
    plan_add prepare "Preparing the system" 10 ph_prepare
    plan_add download "Downloading DezerX Spartan" 6 ph_download
    plan_add php "Installing PHP ${PHP_VER} and ionCube" 14 ph_php
    plan_add web "Installing Nginx" 5 ph_webserver
    plan_add node "Installing Node.js" 5 ph_node
    plan_add db "Setting up the database" 7 ph_database
    plan_add redis "Installing $(kv_target_name)" 3 ph_redis
    plan_add app "Building DezerX Spartan" 30 ph_app
    plan_add services "Configuring services" 8 ph_services
    plan_add ssl "Securing with SSL" 5 ph_ssl
    plan_add finish "Running self tests" 7 ph_finish
}

install_summary() {
    local scheme="http"
    [[ "$SSL_RESULT" == ok ]] && scheme="https"
    local url="${scheme}://${DOMAIN}"
    summary_reset "Installation complete" 1
    summary_add "DezerX Spartan is installed and running."
    summary_add ""
    summary_kv "Dashboard" "$url"
    summary_kv "Location" "$APP_DIR"
    summary_kv "Version" "${RELEASE_VERSION:-}"
    summary_kv "PHP" "$(php -r 'echo PHP_VERSION;' 2>/dev/null) with ionCube $(ioncube_installed_version)"
    if octane_wanted; then
        summary_kv "Octane" "${OCTANE_WORKERS} workers on ${OCTANE_HOST}:${OCTANE_PORT}"
    else
        summary_kv "Octane" "off (PHP-FPM)"
    fi
    summary_kv "Queue" "${QUEUE_WORKERS} worker(s), $(env_read_value QUEUE_CONNECTION)"
    summary_kv "Database" "${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
    ((DB_PASS_GENERATED)) && summary_kv "DB password" "generated, stored in ${APP_DIR}/.env"
    if [[ "$SSL_RESULT" != ok ]]; then
        summary_kv "SSL" "not enabled - run the installer with --ssl later"
    elif [[ "$SSL_MODE" == install ]]; then
        summary_kv "SSL" "Let's Encrypt, renews automatically"
    else
        summary_kv "SSL" "self-signed (${CERT_DIR})"
    fi
    summary_add ""
    summary_add "Next: open {a}$(tx "$url"){/} and create an account. The first account becomes the administrator."
    summary_add ""
    summary_add "{d}Useful commands:{/}"
    summary_add "  systemctl status dezerx.target 'dezerx-queue@*'"
    octane_wanted && summary_add "  systemctl reload dezerx-octane"
    summary_add "  tail -f ${APP_DIR}/storage/logs/laravel.log"
}

install_run() {
    install_plan
    if plan_run; then
        install_summary
        summary_show
        return 0
    fi
    task_try "Leaving maintenance mode" app_maintenance_off >/dev/null 2>&1
    show_failure "Installation failed" "The server may be partly set up. Fix the problem above and run the installer again; finished steps are skipped or repeated safely."
    summary_show
    return 1
}

flow_install() {
    [[ -n "$APP_DIR" ]] || APP_DIR="$APP_DEFAULT_DIR"
    [[ -n "$QUEUE_WORKERS" ]] || QUEUE_WORKERS="$(recommend_queue_workers)"
    [[ -n "$OCTANE_WORKERS" ]] || OCTANE_WORKERS="$(recommend_octane_workers)"
    wizard_run scr_install_welcome scr_install_domain scr_install_license scr_install_location \
        scr_install_db_engine scr_install_database scr_performance scr_install_ssl scr_install_review || return 1
    install_run
}

flow_install_noninteractive() {
    local -a errs=()
    [[ -n "$LICENSE_KEY" ]] || errs+=("--license is required")
    [[ -n "$DOMAIN" ]] || errs+=("--domain is required")
    [[ -z "$DOMAIN" ]] || domain_valid "$DOMAIN" || errs+=("--domain ${DOMAIN} is not a valid domain")
    if path_is_protected "$APP_DIR"; then
        errs+=("--app-dir ${APP_DIR} is a system directory")
    elif ! dir_is_empty "$APP_DIR" && ((!OVERWRITE)); then
        errs+=("${APP_DIR} is not empty (use --update, or --overwrite to replace the installation)")
    fi
    [[ -n "$PRE_BLOCKER" ]] && errs+=("$PRE_BLOCKER")
    if ((${#errs[@]})); then
        local e
        for e in "${errs[@]}"; do lp "Error: ${e}"; done
        return 1
    fi
    WEB="nginx"
    [[ -n "$SSL_MODE" ]] || SSL_MODE="install"
    [[ -n "$DB_ENGINE" ]] || DB_ENGINE="${EXISTING_DB_SERVER:-mariadb}"
    if [[ -z "$DB_PASS" ]]; then
        DB_PASS="$(random_password)"
        DB_PASS_GENERATED=1
        secret_add "$DB_PASS"
    fi
    [[ -n "$QUEUE_WORKERS" ]] || QUEUE_WORKERS="$(recommend_queue_workers)"
    [[ -n "$OCTANE_WORKERS" ]] || OCTANE_WORKERS="$(recommend_octane_workers)"
    install_run
}
