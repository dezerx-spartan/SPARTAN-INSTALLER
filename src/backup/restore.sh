restore_app_backup() {
    [[ -n "$APP_BACKUP_FILE" && -f "$APP_BACKUP_FILE" ]] || { echo "No application backup."; return 1; }
    path_is_protected "$APP_DIR" && { echo "Refusing to restore into ${APP_DIR}."; return 1; }
    mkdir -p "$APP_DIR"
    find "$APP_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    tar -xzf "$APP_BACKUP_FILE" -C "$(dirname "$APP_DIR")" || return 1
    echo "Application files restored from $(basename "$APP_BACKUP_FILE")."
}

restore_db_backup() {
    [[ -n "$DB_BACKUP_FILE" && -f "$DB_BACKUP_FILE" ]] || { echo "No database backup."; return 1; }
    db_restore "$DB_BACKUP_FILE" || return 1
    echo "Database restored from $(basename "$DB_BACKUP_FILE")."
}

restore_configs() {
    local f
    for f in "$PHP_BACKUP_FILE" "$IONCUBE_BACKUP_FILE" "$SYS_BACKUP_FILE"; do
        [[ -n "$f" && -f "$f" ]] || continue
        tar -xzf "$f" -C / && echo "Restored $(basename "$f")"
    done
    if [[ -n "$NGINX_BACKUP_FILE" && -f "$NGINX_BACKUP_FILE" && -n "$NGINX_RESTORE_PATH" ]]; then
        install -m 644 "$NGINX_BACKUP_FILE" "$NGINX_RESTORE_PATH"
        if [[ "$NGINX_MODE" == debian ]]; then
            ln -sf "$NGINX_RESTORE_PATH" "/etc/nginx/sites-enabled/$(basename "$NGINX_RESTORE_PATH")"
            if [[ "$NGINX_RESTORE_PATH" != "$NGINX_CONF_PATH" ]]; then
                rm -f "$NGINX_CONF_PATH" "/etc/nginx/sites-enabled/spartan.conf"
            fi
        elif [[ "$NGINX_RESTORE_PATH" != "$NGINX_CONF_PATH" ]]; then
            rm -f "$NGINX_CONF_PATH"
        fi
        echo "Nginx vhost restored."
    fi
    if [[ -f /etc/dezerx/crontab.root.bak ]] && have crontab; then
        crontab /etc/dezerx/crontab.root.bak && echo "Root crontab restored."
    fi
    systemctl daemon-reload
    return 0
}

restore_services() {
    php_fpm_restart || true
    if [[ -f "$OCTANE_SERVICE" ]]; then
        systemctl restart dezerx-octane.service || true
    fi
    restart_queue_workers || true
    nginx_restart || return 1
}

rollback_phase_files() { task "Restoring the application files" restore_app_backup; }
rollback_phase_db() { task "Restoring the database" restore_db_backup; }
rollback_phase_configs() { task "Restoring PHP, ionCube, Nginx and service settings" restore_configs; }
rollback_phase_services() { task "Restarting services" restore_services; }
rollback_phase_online() {
    task "Clearing caches" app_optimize_clear || true
    task "Leaving maintenance mode" app_maintenance_off
}
rollback_phase_verify() {
    task "Checking the database connection" db_check_connection || warn_add "The database connection test failed after the rollback."
    task "Checking the website" smoke_test || warn_add "The website did not answer as expected after the rollback."
    return 0
}

run_rollback() {
    rm -f "$ABORT_FILE"
    trap '' INT
    local saved_warnings=("${WARNINGS[@]}")
    WARNINGS=()
    plan_new "Restoring the previous version"
    plan_add files "Restoring the application files" 30 rollback_phase_files
    plan_add db "Restoring the database" 30 rollback_phase_db
    plan_add configs "Restoring configuration" 10 rollback_phase_configs
    plan_add services "Restarting services" 10 rollback_phase_services
    plan_add online "Bringing the site back online" 10 rollback_phase_online
    plan_add verify "Checking the site" 10 rollback_phase_verify
    PROG_HINTS="Restoring your previous version${G_ELLIPSIS} please wait"
    local rc=0
    plan_run || rc=1
    PROG_HINTS=""
    trap - INT
    ROLLBACK_WARNINGS=("${WARNINGS[@]}")
    WARNINGS=("${saved_warnings[@]}")
    if ((rc == 0)); then UPDATE_ROLLED_BACK="ok"; else UPDATE_ROLLED_BACK="failed"; fi
    return "$rc"
}
