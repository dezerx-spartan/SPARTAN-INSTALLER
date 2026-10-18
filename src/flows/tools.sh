# shellcheck shell=bash
# Tools for an existing installation (the 1.x "debug" menu, extended).

flow_tools() {
    while :; do
        UI_STEP=""
        UI_LIST_BACK="${G_BACK} Back" UI_LIST_NEXT="Select ${G_NEXT}"
        ui_menu "Tools" "Maintenance tools for an existing installation." "perms" \
            perms "Repair permissions" "Ownership, file modes and the PHP-FPM user" \
            ssl "SSL certificate" "Issue or replace the certificate for the site" \
            restart "Restart services" "PHP-FPM, Nginx, Octane, queue workers, Redis" \
            health "Health check" "Services, database, website and certificate" \
            bundle "Support bundle" "Collect redacted logs for DezerX support"
        local rc=$?
        UI_LIST_BACK="" UI_LIST_NEXT=""
        ((rc == 0)) || return 1
        case "$UI_RESULT" in
            perms) tool_perms && return 0 ;;
            ssl) tool_ssl && return 0 ;;
            restart) tool_restart && return 0 ;;
            health) tool_health ;;
            bundle) tool_bundle && return 0 ;;
        esac
        ((PLAN_EXECUTED)) && return 0
    done
}

# ---------------------------------------------------------------------------
# Repair permissions (1.x "setup perms")
# ---------------------------------------------------------------------------

tp_run() {
    detect_web_user_group
    task "Setting ownership and permissions" apply_permissions || return 1
    task "Configuring PHP-FPM for ${APP_USER}" config_php_fpm || true
    if selinux_enforcing; then task_try "Applying SELinux rules" selinux_configure; fi
    if [[ -f "$OCTANE_SERVICE" ]]; then task_try "Restarting Octane" systemctl restart dezerx-octane.service; fi
    task_try "Restarting queue workers" restart_queue_workers
    return 0
}

tool_perms_run() {
    plan_new "Repairing permissions"
    plan_add perms "Repairing permissions" 100 tp_run
    if plan_run; then
        summary_reset "Permissions repaired" 1
        summary_add "{ok}${G_OK}{/} $(tx "$APP_DIR") is owned by ${APP_USER}:${APP_GROUP}."
    else
        show_failure "Repair failed" ""
    fi
    summary_show
}

tool_perms() {
    PICK_TITLE="Repair permissions"
    screen_pick_install || return 1
    ui_confirm "Repair permissions" "Set the owner of {b}$(tx "$APP_DIR"){/} to the web server user, fix file modes and restart the workers?" "Repair" "${G_BACK} Back" yes || return 1
    tool_perms_run
}

# ---------------------------------------------------------------------------
# SSL certificate
# ---------------------------------------------------------------------------

ts_run() {
    detect_web_user_group
    nginx_layout_detect
    ssl_apply
    local rc=$?
    ((rc == 3)) && return 3
    [[ "$SSL_RESULT" == ok ]] || return 1
    task "Clearing caches" app_optimize_clear || true
    if octane_wanted && [[ -f "$OCTANE_SERVICE" ]]; then
        task_try "Restarting Octane" restart_octane
    fi
    return 0
}

tool_ssl_run() {
    [[ "$(env_read_value OCTANE_ENABLED)" == false ]] && OCTANE_ENABLED=0
    plan_new "Securing ${DOMAIN}"
    plan_add prepare "Preparing" 10 ph_ssl_prepare
    plan_add ssl "Issuing the certificate" 90 ts_run
    if plan_run && [[ "$SSL_RESULT" == ok ]]; then
        summary_reset "SSL enabled" 1
        summary_add "{ok}${G_OK}{/} https://$(tx "$DOMAIN") is live."
        summary_kv "Certificate" "$CERT_DIR"
    else
        [[ -z "$PHASE_FAIL_MSG" && "${#WARNINGS[@]}" -gt 0 ]] && PHASE_FAIL_MSG="${WARNINGS[-1]}"
        show_failure "SSL not enabled" "The site keeps working over HTTP."
    fi
    summary_show
}

ph_ssl_prepare() {
    task "Refreshing package lists" pkg_refresh || true
    return 0
}

tool_ssl() {
    PICK_TITLE="SSL certificate"
    screen_pick_install || return 1
    app_get_var || { ui_error "SSL certificate" "$(tx "$PHASE_FAIL_MSG")" "${G_BACK} Back"; return 1; }
    ui_busy "Checking DNS for ${DOMAIN}${G_ELLIPSIS}" dns_check "$DOMAIN"
    scr_install_ssl || return 1
    [[ "$SSL_MODE" == later ]] && return 1
    tool_ssl_run
}

# ---------------------------------------------------------------------------
# Restart services
# ---------------------------------------------------------------------------

tr_run() {
    local svc
    svc="$(php_fpm_service)"
    [[ -n "$svc" ]] && task "Restarting ${svc}" systemctl restart "$svc"
    have nginx && task "Restarting Nginx" nginx_restart
    [[ -f "$OCTANE_SERVICE" ]] && task "Restarting Octane" systemctl restart dezerx-octane.service
    task "Restarting queue workers" restart_queue_workers
    local r
    r="$(redis_service_name)"
    svc_exists "$r" && task "Restarting Redis" systemctl restart "$r"
    return 0
}

tool_restart() {
    plan_new "Restarting services"
    plan_add restart "Restarting services" 100 tr_run
    if plan_run; then
        summary_reset "Services restarted" 1
        summary_add "{ok}${G_OK}{/} All DezerX Spartan services were restarted."
    else
        show_failure "Restart failed" ""
    fi
    summary_show
}

# ---------------------------------------------------------------------------
# Health check
# ---------------------------------------------------------------------------

declare -a HEALTH_ROWS=()

_health_row() {
    local icon
    case "$1" in
        ok) icon="{ok}${G_OK}{/}" ;;
        warn) icon="{w}${G_WARN}{/}" ;;
        *) icon="{e}${G_FAIL}{/}" ;;
    esac
    local pad
    printf -v pad '%-14s' "$2"
    HEALTH_ROWS+=("  ${icon} {d}${pad}{/}$(tx "$3")")
    [[ "$1" == fail ]] && HEALTH_FAILS=$((HEALTH_FAILS + 1))
    return 0
}

health_collect() {
    HEALTH_ROWS=()
    HEALTH_FAILS=0
    app_get_var >/dev/null 2>&1
    if svc_active nginx; then _health_row ok "Nginx" "running $(nginx_version)"; else _health_row fail "Nginx" "not running"; fi
    local fpm
    fpm="$(php_fpm_service)"
    if [[ -n "$fpm" ]] && svc_active "$fpm"; then _health_row ok "PHP-FPM" "$fpm running"; else _health_row fail "PHP-FPM" "${fpm:-php-fpm} not running"; fi
    local iv
    iv="$(ioncube_installed_version)"
    if [[ "$iv" != 0 ]]; then _health_row ok "ionCube" "loader ${iv} (PHP $(php_minor))"; else _health_row fail "ionCube" "not loaded by PHP $(php_minor)"; fi
    if [[ -f "$OCTANE_SERVICE" ]]; then
        if svc_active dezerx-octane; then _health_row ok "Octane" "running on port $(env_read_value OCTANE_PORT)"; else _health_row fail "Octane" "dezerx-octane is not running"; fi
    else
        _health_row ok "Octane" "not used (PHP-FPM)"
    fi
    local want have_n=0 u
    want="$(env_read_value QUEUE_WORKERS)"
    while read -r u; do [[ -n "$u" ]] && svc_active "$u" && have_n=$((have_n + 1)); done < <(systemctl list-units --all --plain --no-legend 'dezerx-queue@*.service' 2>/dev/null | awk '{ print $1 }')
    if ((have_n > 0)) && [[ -z "$want" || "$have_n" -ge "$want" ]]; then _health_row ok "Queue" "${have_n} worker(s) running"; else _health_row fail "Queue" "${have_n}/${want:-?} workers running"; fi
    if crontab -l 2>/dev/null | grep -qE "$(cron_match_regex)"; then _health_row ok "Scheduler" "cron entry present"; else _health_row fail "Scheduler" "no cron entry for ${APP_DIR}"; fi
    if db_check_connection 2>/dev/null; then _health_row ok "Database" "${DB_NAME} reachable"; else _health_row fail "Database" "cannot connect as ${DB_USER}"; fi
    if [[ "$(env_read_value CACHE_STORE)" == redis ]]; then
        if redis_is_up; then _health_row ok "Redis" "answering"; else _health_row fail "Redis" "cache uses Redis but it does not answer"; fi
    fi
    local out
    if out="$(smoke_test 2>&1)"; then _health_row ok "Website" "$(tail -n1 <<<"$out")"; else _health_row fail "Website" "$(tail -n1 <<<"$out")"; fi
    if [[ "$(site_scheme)" == https ]]; then
        local end days
        end="$(echo | timeout 10 openssl s_client -connect 127.0.0.1:443 -servername "$DOMAIN" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)"
        if [[ -n "$end" ]]; then
            days=$((($(date -d "$end" +%s 2>/dev/null || echo 0) - $(now)) / 86400))
            if ((days > 14)); then _health_row ok "Certificate" "valid for ${days} more days"
            elif ((days >= 0)); then _health_row warn "Certificate" "expires in ${days} days"
            else _health_row fail "Certificate" "expired"; fi
        else
            _health_row fail "Certificate" "could not read the certificate"
        fi
    fi
    local free
    free="$(free_mb "$APP_DIR")"
    if ((free > 2048)); then _health_row ok "Disk" "$((free / 1024)) GB free"; else _health_row warn "Disk" "${free} MB free"; fi
    return 0
}

tool_health() {
    PICK_TITLE="Health check"
    screen_pick_install || return 1
    ui_busy "Checking ${APP_DIR}${G_ELLIPSIS}" health_collect
    local text
    text="$(printf '%s\n' "${HEALTH_ROWS[@]}")"
    if ((HEALTH_FAILS)); then
        ui_msgbox "Health check" "{w}${HEALTH_FAILS} problem(s) found.{/} Restart services or repair permissions from the Tools menu, or see ${LOG}.\n\n${text}" "${G_BACK} Back"
    else
        ui_msgbox "Health check" "{ok}Everything looks good.{/}\n\n${text}" "${G_BACK} Back"
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Support bundle (replaces 1.x "upload logs", which never worked). Written
# locally; nothing is uploaded.
# ---------------------------------------------------------------------------

BUNDLE_FILE=""

_redact_env() {
    sed -E 's/^([A-Z0-9_]*(PASS|PASSWORD|SECRET|KEY|TOKEN|LICENSE|DSN|AUTH)[A-Z0-9_]*)=.*/\1=****/' "$1"
}

collect_bundle() {
    work_dir bundle || return 1
    local d="${REPLY}/spartan-support"
    mkdir -p "$d"
    {
        echo "Installer: ${SPARTAN_VERSION}"
        echo "Date: $(date -u)"
        uname -a
        cat /etc/os-release 2>/dev/null
        echo
        free -m
        df -h
        echo
        php -v 2>&1
        php -m 2>&1 | tr '\n' ' '
        echo
        nginx -v 2>&1
        "$(db_client)" --version 2>&1
        node -v 2>&1
        echo "App: ${APP_DIR} version $(app_version_of "$APP_DIR")"
    } >"${d}/system.txt" 2>&1
    systemctl --no-pager status nginx "$(php_fpm_service)" dezerx-octane dezerx.target 'dezerx-queue@*' >"${d}/services.txt" 2>&1
    journalctl -u dezerx-octane -n 300 --no-pager >"${d}/octane.journal.txt" 2>&1
    journalctl -u 'dezerx-queue@*' -n 300 --no-pager >"${d}/queue.journal.txt" 2>&1
    [[ -f "$LOG" ]] && tail -n 5000 "$LOG" >"${d}/installer.log"
    [[ -f "${APP_DIR}/.env" ]] && _redact_env "${APP_DIR}/.env" >"${d}/env.redacted"
    local f
    for f in $(ls -1t "${APP_DIR}"/storage/logs/*.log 2>/dev/null | head -n 3); do
        tail -n 1000 "$f" >"${d}/laravel-$(basename "$f")"
    done
    for f in /var/log/nginx/dezerx.app-error.log "$NGINX_CONF_PATH" "$NGINX_UPSTREAM_CONF"; do
        [[ -n "$f" && -f "$f" ]] && tail -n 2000 "$f" >"${d}/$(basename "$f")"
    done
    BUNDLE_FILE="${SUPPORT_DIR}/spartan-support-$(date +%Y%m%d-%H%M%S).tar.gz"
    (umask 077 && tar -czf "$BUNDLE_FILE" -C "$REPLY" spartan-support) || return 1
    echo "Support bundle: ${BUNDLE_FILE}"
}

tb_run() {
    nginx_layout_detect
    task "Collecting logs and system information" collect_bundle
}

tool_bundle_run() {
    plan_new "Creating a support bundle"
    plan_add bundle "Collecting diagnostics" 100 tb_run
    if plan_run; then
        summary_reset "Support bundle ready" 1
        summary_add "{ok}${G_OK}{/} Saved to {b}${BUNDLE_FILE}{/}"
        summary_add "Passwords, keys and tokens in .env are replaced with ****. Review the archive before sharing it."
    else
        show_failure "Support bundle failed" ""
    fi
    summary_show
}

tool_bundle() {
    PICK_TITLE="Support bundle"
    if [[ -n "$DETECTED_APP_DIR" || "$USED_APP_DIR" == 1 ]]; then
        screen_pick_install || return 1
    fi
    tool_bundle_run
}

# ---------------------------------------------------------------------------
# Non-interactive variants
# ---------------------------------------------------------------------------

tool_pick_noninteractive() {
    app_looks_like_spartan "$APP_DIR" && return 0
    if [[ -n "$DETECTED_APP_DIR" && "$USED_APP_DIR" == 0 ]]; then
        APP_DIR="$DETECTED_APP_DIR"
        return 0
    fi
    lp "Error: no DezerX Spartan installation in ${APP_DIR} (use --app-dir)."
    return 1
}
