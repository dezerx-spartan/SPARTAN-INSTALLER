UPDATE_LICENSE_CHECKED=0

workers_defaults_from_env() {
    local q o
    q="$(env_read_value QUEUE_WORKERS)"
    o="$(env_read_value OCTANE_WORKERS)"
    if [[ -z "$QUEUE_WORKERS" ]]; then
        if [[ "$q" =~ ^[0-9]+$ ]] && ((q > 0)); then QUEUE_WORKERS="$q"; else QUEUE_WORKERS="$(recommend_queue_workers)"; fi
    fi
    if [[ -z "$OCTANE_WORKERS" ]]; then
        if [[ "$o" =~ ^[0-9]+$ ]] && ((o > 0)); then OCTANE_WORKERS="$o"; else OCTANE_WORKERS="$(recommend_octane_workers)"; fi
    fi
}

update_load_install() {
    app_get_var || return 1
    nginx_layout_detect
    detect_web_user_group
    opts_load_keep
    octane_update_default
    workers_defaults_from_env
    return 0
}

scr_update_pick() {
    PICK_TITLE="Update"
    while :; do
        screen_pick_install || return $?
        if ! update_load_install; then
            ui_error "Update" "$(tx "$PHASE_FAIL_MSG")" "${G_BACK} Back"
            continue
        fi
        UPDATE_LICENSE_CHECKED=0
        if have curl; then
            if ui_busy "Checking your license${G_ELLIPSIS}" license_verify; then
                UPDATE_LICENSE_CHECKED=1
            else
                ui_error "License" "The license for {b}$(tx "$DOMAIN"){/} could not be verified:\n\n$(tx "$LICENSE_MSG")" "${G_BACK} Back"
                continue
            fi
        fi
        return 0
    done
}

scr_update_overview() {
    local text="" cur="${INSTALLED_VERSION:-unknown}" avail="${AVAILABLE_VERSION:-}"
    if [[ -n "$avail" && "$avail" != "$cur" ]] && version_gt "$avail" "$cur" 2>/dev/null; then
        text="{a}DezerX Spartan ${avail}{/} is available. This server runs ${cur}.\n\n"
    elif [[ -n "$avail" ]]; then
        text="This server already runs the latest version ({b}${cur}{/}). Updating reinstalls it and brings PHP, Nginx and the other components up to date.\n\n"
    else
        text="Installed version: {b}${cur}{/}\n\n"
    fi
    text+="  {d}Site         {/}$(tx "$DOMAIN")\n"
    text+="  {d}Location     {/}$(tx "$APP_DIR")\n"
    text+="  {d}License      {/}${PRODUCT_NAME}\n"
    text+="  {d}Database     {/}$(tx "${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME}")\n\n"
    text+="During the update:\n"
    text+="  - The site shows a maintenance page\n"
    text+="  - Files, database and settings are backed up to ${BACKUP_DIR}\n"
    text+="  - If anything fails, the previous version is restored automatically\n"
    text+="  - Your modules, themes and settings are kept (next screen)"
    ui_nav "Update" "$text"
}

scr_update_keep() {
    local -a items=(
        NGINX "Nginx configuration" "$KEEP_NGINX"
        CSS "Dashboard colours (CSS)" "$KEEP_CSS"
        THEMES "Client themes" "$KEEP_THEMES"
        PORTALS "Portals" "$KEEP_PORTALS"
        EMAILS "E-mail templates" "$KEEP_EMAILS"
        FAVICON "Favicon" "$KEEP_FAVICON"
    )
    ui_checklist "Keep" "Select what to keep from the current installation. Your choices are saved to ${OPTIONS_JSON_NAME} for automatic updates." "${items[@]}" || return $?
    local k
    for k in NGINX CSS THEMES PORTALS EMAILS FAVICON; do
        if [[ " ${UI_RESULT} " == *" ${k} "* ]]; then printf -v "KEEP_${k}" '%s' 1; else printf -v "KEEP_${k}" '%s' 0; fi
    done
    UPDATE_SAVE_KEEP=1
    return 0
}

update_review_text() {
    local t keep="" k
    for k in NGINX CSS THEMES PORTALS EMAILS FAVICON; do
        local v="KEEP_${k}"
        ((${!v})) && keep+="${k,,}, "
    done
    keep="${keep%, }"
    t="Review the update. Nothing has been changed yet.\n\n"
    t+="  {d}Site         {/}$(tx "$DOMAIN") {d}($(tx "$APP_DIR")){/}\n"
    t+="  {d}Version      {/}${INSTALLED_VERSION:-?} ${G_NEXT} ${AVAILABLE_VERSION:-latest}\n"
    t+="  {d}Keep         {/}${keep:-nothing}\n"
    if octane_wanted; then
        t+="  {d}Performance  {/}Octane, ${OCTANE_WORKERS} HTTP workers, ${QUEUE_WORKERS} queue workers\n"
    else
        t+="  {d}Performance  {/}PHP-FPM, ${QUEUE_WORKERS} queue workers\n"
    fi
    t+="  {d}Backups      {/}${BACKUP_DIR} (the last ${BACKUP_KEEP} are kept)\n"
    ((SKIP_UPGRADE)) || t+="\nSystem packages are upgraded as part of the update."
    printf '%s' "$t"
}

scr_update_review() { ui_nav "Review" "$(update_review_text)" "Update ${G_NEXT}"; }

up_backup() {
    task "Preparing ${BACKUP_DIR}" backup_prepare_dir || return 1
    task "Checking free disk space" backup_check_space || return 1
    task "Testing the database connection" db_check_connection || {
        phase_fail "Cannot connect to the database ${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME} with the credentials in .env."
        return 1
    }
    task "Entering maintenance mode" app_maintenance_on || true
    task "Backing up the Nginx site" create_nginx_backup || return 1
    task "Backing up the application files" create_app_backup || return 1
    task "Backing up the database" create_db_backup || return 1
    task "Backing up PHP and ionCube settings" create_php_backup || return 1
    task "Backing up the ionCube loader" create_ioncube_backup || return 1
    task "Backing up service settings" create_sys_backup || return 1
}

up_download() { download_release; }

up_deploy() {
    ((${UPDATE_SAVE_KEEP:-0})) || opts_load_keep
    UPDATE_TOUCHED=1
    task "Setting aside excluded files" opts_stage_exclusions || return 1
    task "Saving your customisations" up_preserve || return 1
    task "Removing the previous version" app_dir_cleanup || return 1
    task "Restoring storage and uploads" restore_core || return 1
    task "Restoring portals and e-mail templates" restore_portals_emails || return 1
    task "Installing the new version" release_deploy || return 1
    task "Restoring your modules" restore_modules || return 1
    task "Restoring your client themes" restore_themes || return 1
    task "Restoring .env and customisations" restore_files || return 1
    task "Restoring excluded files" opts_restore_exclusions || return 1
    task "Merging .env with the new settings" env_merge || return 1
    task "Merging module statuses" merge_module_statuses || return 1
    preserve_finish
}

up_preserve() {
    preserve_begin || return 1
    preserve_css || return 1
    preserve_themes || return 1
    preserve_portals || return 1
    preserve_emails || return 1
    preserve_favicon || return 1
    preserve_core || return 1
}

up_components() {
    task "Updating the PHP repository" php_enable_repo || return 1
    task "Updating PHP ${PHP_VER} and extensions" php_install_packages || return 1
    php_octane_requirements >/dev/null || true
    task "Setting up $(kv_target_name)" install_valkey || true
    task_try "Tuning the database" config_db_tuning
    install_nodejs || return 1
    install_ioncube || return 1
    task "Configuring OPcache" config_opcache || return 1
    task_try "Applying network settings" config_network
    have composer || task "Installing Composer" install_composer || return 1
    return 0
}

up_app() {
    task "Installing PHP dependencies (Composer)" app_composer_install || return 1
    task "Installing frontend dependencies (pnpm)" app_pnpm_install || return 1
    task "Running database migrations" artisan migrate --force || return 1
    task "Seeding the database" artisan db:seed --force || return 1
    task "Linking storage" app_storage_link || true
    if [[ "$css_save_methode" == php ]]; then
        task "Restoring dashboard colours" app_theme_restore || warn_add "The saved dashboard colours could not be restored."
    fi
    task "Building the dashboard" app_pnpm_build || return 1
    task "Moving cache and queue to $(kv_name)" switch_to_redis_drivers || true
    task "Applying deletions from ${OPTIONS_JSON_NAME}" opts_apply_deletions || true
}

up_nginx() {
    if ((KEEP_NGINX)) && octane_wanted && [[ ! -f "$NGINX_UPSTREAM_CONF" ]]; then
        warn_add "Octane was just enabled, so the Nginx site had to be rewritten even though it was set to be kept."
        KEEP_NGINX=0
    fi
    if ((KEEP_NGINX)); then
        say "Keeping the current Nginx site."
        return 0
    fi
    if [[ "$(env_read_value APP_URL)" == https://* ]]; then
        CERT_DIR="$(nginx_existing_cert_dir)"
        if [[ -z "$CERT_DIR" || ! -f "${CERT_DIR}/fullchain.pem" ]]; then
            if [[ -f "${SELF_SIGNED_BASE}/${DOMAIN}/fullchain.pem" ]]; then
                CERT_DIR="${SELF_SIGNED_BASE}/${DOMAIN}"
            elif [[ -f "${LETSENCRYPT_LIVE}/${DOMAIN}/fullchain.pem" ]]; then
                CERT_DIR="${LETSENCRYPT_LIVE}/${DOMAIN}"
            else
                warn_add "No certificate was found for ${DOMAIN}; a self-signed one was created so the site keeps working over HTTPS."
                task "Creating a self-signed certificate" create_self_signed_certs || return 1
            fi
        fi
        task "Writing the Nginx site (HTTPS)" configure_nginx ssl
    else
        task "Writing the Nginx site (HTTP)" configure_nginx http
    fi
}

up_services() {
    setup_octane || return 1
    task "Setting file permissions" apply_permissions || return 1
    task "Configuring PHP-FPM" config_php_fpm || return 1
    task "Scheduling Laravel's task runner (cron)" setup_cron || return 1
    task "Restarting ${QUEUE_WORKERS} queue worker(s)" setup_systemd_queue || return 1
    up_nginx || return 1
    task_try "Opening ports 80 and 443" firewall_open_web
    if selinux_enforcing; then
        task_try "Applying SELinux rules" selinux_configure
    fi
    task "Restarting PHP-FPM" php_fpm_restart || true
    task "Restarting Nginx" nginx_restart || return 1
}

up_finish() {
    task "Writing ${OPTIONS_JSON_NAME}" opts_ensure || true
    if ((${UPDATE_SAVE_KEEP:-0})); then
        task "Saving your keep choices" opts_save_keep || true
    fi
    task "Clearing caches" app_optimize_clear || true
    if octane_wanted; then
        task "Restarting Octane" restart_octane || warn_add "Octane did not answer after the restart; check: journalctl -u dezerx-octane -n 100"
    fi
    task "Leaving maintenance mode" app_maintenance_off || true
    task "Removing old backups" rotate_backups || true
    task "Checking the database connection" db_check_connection || return 1
    task "Checking the website" smoke_test || warn_add "The website did not answer as expected; see /var/log/nginx/dezerx.app-error.log."
    return 0
}

update_plan() {
    plan_new "Updating DezerX Spartan"
    plan_add prepare "Preparing the system" 8 ph_prepare
    plan_add backup "Creating backups" 10 up_backup
    plan_add download "Downloading DezerX Spartan${AVAILABLE_VERSION:+ ${AVAILABLE_VERSION}}" 6 up_download
    plan_add deploy "Installing the new version" 8 up_deploy
    plan_add components "Upgrading PHP, $(kv_target_name) and Node.js" 14 up_components
    plan_add app "Migrating and building" 34 up_app
    plan_add services "Configuring services" 10 up_services
    plan_add finish "Finishing up" 10 up_finish
}

update_summary_ok() {
    local scheme
    scheme="$(site_scheme)"
    summary_reset "Update complete" 1
    local from="${INSTALLED_VERSION:-?}" to="${RELEASE_VERSION:-${AVAILABLE_VERSION:-?}}"
    summary_add "DezerX Spartan was updated (${from} ${G_NEXT} ${to})."
    summary_add ""
    summary_kv "Dashboard" "${scheme}://${DOMAIN}"
    summary_kv "Location" "$APP_DIR"
    summary_kv "PHP" "$(php -r 'echo PHP_VERSION;' 2>/dev/null) with ionCube $(ioncube_installed_version)"
    if octane_wanted; then summary_kv "Octane" "${OCTANE_WORKERS} workers on ${OCTANE_HOST}:${OCTANE_PORT}"; else summary_kv "Octane" "off (PHP-FPM)"; fi
    summary_kv "Queue" "${QUEUE_WORKERS} worker(s), $(env_read_value QUEUE_CONNECTION)"
    summary_kv "Backup" "${APP_BACKUP_FILE##*/}, ${DB_BACKUP_FILE##*/}"
    summary_kv "Backups in" "$BACKUP_DIR"
}

update_run() {
    update_plan
    if plan_run; then
        update_summary_ok
        summary_show
        return 0
    fi

    local reason
    reason="$(plan_fail_reason)"
    local tail
    tail="$(task_fail_tail 10)"
    if ((UPDATE_TOUCHED)); then
        run_rollback
        summary_reset "Update failed" 0
        summary_add "{e}${G_FAIL}{/} $(tx "$reason")"
        [[ -n "$tail" ]] && summary_add "\n{d}Last output:{/}\n$(tx "$tail" | sed 's/^/  /')"
        summary_add ""
        if [[ "$UPDATE_ROLLED_BACK" == ok ]]; then
            summary_add "The previous version was restored from the backup and the site is back online."
        else
            summary_add "{e}${G_FAIL}{/} The automatic restore did not finish. Restore by hand:"
            summary_add "  tar -xzf ${APP_BACKUP_FILE} -C $(dirname "$APP_DIR")"
            summary_add "  gunzip < ${DB_BACKUP_FILE} | mysql ${DB_NAME}"
        fi
        local w
        for w in "${ROLLBACK_WARNINGS[@]}"; do WARNINGS+=("Rollback: ${w}"); done
    else
        task_try "Leaving maintenance mode" app_maintenance_off >/dev/null 2>&1
        summary_reset "Update failed" 0
        summary_add "{e}${G_FAIL}{/} $(tx "$reason")"
        [[ -n "$tail" ]] && summary_add "\n{d}Last output:{/}\n$(tx "$tail" | sed 's/^/  /')"
        summary_add ""
        summary_add "The installed version was not changed and the site is online."
    fi
    summary_show
    return 1
}

flow_update() {
    UPDATE_SAVE_KEEP=0
    wizard_run scr_update_pick scr_update_overview scr_update_keep scr_performance scr_update_review || return 1
    update_run
}

flow_update_noninteractive() {
    if ! app_looks_like_spartan "$APP_DIR"; then
        if [[ -n "$DETECTED_APP_DIR" && "$USED_APP_DIR" == 0 ]]; then
            APP_DIR="$DETECTED_APP_DIR"
        else
            lp "Error: no DezerX Spartan installation in ${APP_DIR} (use --app-dir)."
            return 1
        fi
    fi
    [[ -n "$PRE_BLOCKER" ]] && { lp "Error: ${PRE_BLOCKER}"; return 1; }
    if ! update_load_install; then
        lp "Error: ${PHASE_FAIL_MSG}"
        return 1
    fi
    lp "Updating ${DOMAIN} in ${APP_DIR} (installed ${INSTALLED_VERSION:-unknown})"
    update_run
}
