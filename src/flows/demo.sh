demo_work() {
    local secs="${1:-1}" steps i
    steps=$((${secs%.*} * 4 + 2))
    for ((i = 1; i <= steps; i++)); do
        printf 'Processing step %d of %d (%s)\n' "$i" "$steps" "${DEMO_LINE:-working}"
        sleep 0.25
    done
}

demo_t() {
    local desc="$1" secs="${2:-1}"
    DEMO_LINE="$desc"
    task "$desc" demo_work "$secs"
}

demo_ph_prepare() { demo_t "Refreshing package lists" 1 && demo_t "Upgrading system packages" 2 && demo_t "Installing required tools" 1; }
demo_ph_download() { demo_t "Verifying your license" 1 && demo_t "Downloading DezerX Spartan 6.0.3" 2 && demo_t "Unpacking the release" 1; }
demo_ph_php() { demo_t "Adding the PHP repository" 1 && demo_t "Installing PHP 8.4 and extensions" 3 && demo_t "Downloading the ionCube loader" 1 && demo_t "Installing Composer" 1; }
demo_ph_web() { demo_t "Installing Nginx" 2; }
demo_ph_node() { demo_t "Adding the NodeSource LTS repository" 1 && demo_t "Installing Node.js" 2; }
demo_ph_db() { demo_t "Installing the database server" 2 && demo_t "Creating database dezerx and user dezer" 1; }
demo_ph_redis() { demo_t "Installing Valkey" 1; }
demo_ph_app() {
    demo_t "Installing PHP dependencies (Composer)" 2 && demo_t "Installing frontend dependencies (pnpm)" 3 &&
        demo_t "Building the dashboard" 4 && demo_t "Creating the database tables" 2
}
demo_ph_services() { demo_t "Creating the Octane service" 1 && demo_t "Starting 4 queue worker(s)" 1 && demo_t "Configuring the Nginx site" 1; }
demo_ph_ssl() { demo_t "Requesting a Let's Encrypt certificate" 2 && warn_add "Demo warning: this is how a non-fatal problem is reported."; }
demo_ph_finish() { demo_t "Starting Octane" 1 && demo_t "Checking the website" 1; }
demo_ph_backup() { demo_t "Backing up the application files" 2 && demo_t "Backing up the database" 1; }

demo_overrides() {
    preflight_run() {
        PRE_STATE=(ok ok ok ok ok)
        PRE_LABEL=(System Services Resources Disk Network)
        PRE_DETAIL=("Ubuntu 24.04.3 LTS (x86_64)" "systemd" "4 CPU, 7.8 GB RAM" "61.2 GB free" "github.com and market.dezerx.com reachable")
        PRE_BLOCKER=""
        CPU_CORES=4 MEM_TOTAL_MB=7987
    }
    startup_checks() {
        sleep 0.8
        preflight_run
        EXISTING_DB_SERVER=""
        if [[ -n "${SPARTAN_DEMO_INSTALLED:-}" ]]; then
            DETECTED_APP_DIR="/var/www/spartan" DETECTED_DOMAIN="dash.example.com" DETECTED_VERSION="6.0.2"
        fi
    }
    detect_resources() { CPU_CORES=4 MEM_TOTAL_MB=7987; }
    dns_check() { sleep 0.7; DNS_STATUS="ok"; PUBLIC_IPV4="203.0.113.10"; DNS_RESOLVED="203.0.113.10"; }
    license_verify() {
        sleep 1
        if [[ "$LICENSE_KEY" == SPARTAN* ]]; then AVAILABLE_VERSION="6.0.3"; return 0; fi
        LICENSE_MSG="License not found."
        return 1
    }
    db_mysql_available() { return 0; }
    db_root_access_ok() { return 0; }
    db_check_connection() { sleep 0.4; return 0; }
    port_owner() { :; }
    swap_needed_mb() { echo 0; }
    firewall_kind() { echo ufw; }
    selinux_enforcing() { return 1; }
    have() { [[ "$1" == curl ]] && return 0; command -v "$1" >/dev/null 2>&1; }
    app_looks_like_spartan() { [[ -n "${SPARTAN_DEMO_INSTALLED:-}" && "${1%/}" == /var/www/spartan ]]; }
    dir_is_empty() { [[ -z "${SPARTAN_DEMO_INSTALLED:-}" || "${1%/}" != /var/www/spartan ]]; }
    app_get_var() {
        DOMAIN="dash.example.com" LICENSE_KEY="SPARTANPROFESSIONAL_DEMO1234" PRODUCT_ID=5 PRODUCT_NAME="Spartan Professional"
        DB_HOST=127.0.0.1 DB_PORT=3306 DB_NAME=dezerx DB_USER=dezer DB_PASS=demo INSTALLED_VERSION="6.0.2"
        return 0
    }
    update_load_install() { app_get_var; QUEUE_WORKERS=4 OCTANE_WORKERS=8 OCTANE_ENABLED=1; }
    env_read_value() { :; }
    nginx_layout_detect() { :; }
    install_plan() {
        plan_new "Installing DezerX Spartan"
        plan_add prepare "Preparing the system" 10 demo_ph_prepare
        plan_add download "Downloading DezerX Spartan" 6 demo_ph_download
        plan_add php "Installing PHP 8.4 and ionCube" 14 demo_ph_php
        plan_add web "Installing Nginx" 5 demo_ph_web
        plan_add node "Installing Node.js" 5 demo_ph_node
        plan_add db "Setting up the database" 7 demo_ph_db
        plan_add redis "Installing Valkey" 3 demo_ph_redis
        plan_add app "Building DezerX Spartan" 30 demo_ph_app
        plan_add services "Configuring services" 8 demo_ph_services
        plan_add ssl "Securing with SSL" 5 demo_ph_ssl
        plan_add finish "Running self tests" 7 demo_ph_finish
    }
    update_plan() {
        plan_new "Updating DezerX Spartan"
        plan_add prepare "Preparing the system" 8 demo_ph_prepare
        plan_add backup "Creating backups" 10 demo_ph_backup
        plan_add download "Downloading DezerX Spartan 6.0.3" 6 demo_ph_download
        plan_add app "Migrating and building" 34 demo_ph_app
        plan_add services "Configuring services" 10 demo_ph_services
        plan_add finish "Finishing up" 10 demo_ph_finish
    }
    install_summary() {
        summary_reset "Installation complete" 1
        summary_add "DezerX Spartan is installed and running."
        summary_add ""
        summary_kv "Dashboard" "https://${DOMAIN:-dash.example.com}"
        summary_kv "Location" "$APP_DIR"
        summary_kv "Version" "6.0.3"
        summary_kv "PHP" "8.4.13 with ionCube 14.4.0"
        summary_kv "Octane" "${OCTANE_WORKERS} workers on 127.0.0.1:8000"
        summary_kv "Queue" "${QUEUE_WORKERS} worker(s), redis"
        summary_add ""
        summary_add "Next: open {a}https://${DOMAIN:-dash.example.com}{/} and create an account. The first account becomes the administrator."
    }
    update_summary_ok() {
        summary_reset "Update complete" 1
        summary_add "DezerX Spartan was updated (6.0.2 ${G_NEXT} 6.0.3)."
        summary_add ""
        summary_kv "Dashboard" "https://dash.example.com"
        summary_kv "Backups in" "$BACKUP_DIR"
    }
    uninstall_run() {
        plan_new "Uninstalling DezerX Spartan"
        plan_add backup "Creating a final backup" 40 demo_ph_backup
        plan_add remove "Removing DezerX Spartan" 60 demo_ph_services
        plan_run
        summary_reset "Uninstalled" 1
        summary_add "(demo) Nothing was removed."
        summary_show
    }
    health_collect() {
        sleep 1
        HEALTH_FAILS=0
        HEALTH_ROWS=()
        _health_row ok "Nginx" "running 1.29.1"
        _health_row ok "PHP-FPM" "php8.4-fpm running"
        _health_row ok "Octane" "running on port 8000"
        _health_row ok "Queue" "4 worker(s) running"
        _health_row warn "Certificate" "expires in 12 days"
    }
    tool_perms_run() { plan_new "Repairing permissions"; plan_add p "Repairing permissions" 100 demo_ph_web; plan_run; summary_reset "Permissions repaired" 1; summary_add "(demo)"; summary_show; }
    tool_ssl_run() { plan_new "Securing ${DOMAIN}"; plan_add s "Issuing the certificate" 100 demo_ph_ssl; plan_run; summary_reset "SSL enabled" 1; summary_add "(demo)"; summary_show; }
    tool_restart() { plan_new "Restarting services"; plan_add r "Restarting services" 100 demo_ph_redis; plan_run; summary_reset "Services restarted" 1; summary_add "(demo)"; summary_show; }
    tool_bundle_run() { plan_new "Creating a support bundle"; plan_add b "Collecting diagnostics" 100 demo_ph_redis; plan_run; summary_reset "Support bundle ready" 1; summary_add "(demo)"; summary_show; }
}

demo_main() {
    RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/spartan-demo.XXXXXX")"
    LOG="${RUN_DIR}/demo.log"
    BACKUP_DIR="/var/backups/spartan"
    ticker_files_init
    log_init >/dev/null 2>&1
    exec >>"$LOG" 2>&1
    trap 'spartan_on_exit $?' EXIT
    trap spartan_on_hup HUP
    OS_FAMILY="debian" OS_BASE="ubuntu" DISTRO_NAME="Ubuntu 24.04.3 LTS" ARCH="x86_64" OS_SUPPORT="supported"
    demo_overrides
    ui_start
    if ((NONINTERACTIVE)); then
        startup_checks
        DOMAIN="${DOMAIN:-dash.example.com}"
        install_plan
        plan_run
        install_summary
        summary_show
        summary_print_plain
        rm -rf "$RUN_DIR"
        spartan_exit 0
    fi
    main_interactive
    rm -rf "$RUN_DIR"
}
