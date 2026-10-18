scr_uninstall_pick() {
    PICK_TITLE="Uninstall"
    screen_pick_install || return $?
    app_get_var >/dev/null 2>&1 || true
    nginx_layout_detect
    return 0
}

scr_uninstall_options() {
    UI_CHECK_DESC=("" "" "" "")
    local -a items=(
        BACKUP "Back up files and database first" "$RM_FINAL_BACKUP"
        DATABASE "Delete the database ${DB_NAME:-?} and user ${DB_USER:-?}" "$RM_DATABASE"
        BACKUPS "Delete all backups in ${BACKUP_DIR}" "$RM_BACKUPS"
        CERT "Delete the SSL certificate for ${DOMAIN:-the domain}" "$RM_CERT"
    )
    ui_checklist "Uninstall" "This removes the application files in {b}$(tx "$APP_DIR"){/}, the Octane and queue services, the scheduler entry and the Nginx site. Also:" "${items[@]}" || return $?
    RM_FINAL_BACKUP=0 RM_DATABASE=0 RM_BACKUPS=0 RM_CERT=0
    [[ " ${UI_RESULT} " == *" BACKUP "* ]] && RM_FINAL_BACKUP=1
    [[ " ${UI_RESULT} " == *" DATABASE "* ]] && RM_DATABASE=1
    [[ " ${UI_RESULT} " == *" BACKUPS "* ]] && RM_BACKUPS=1
    [[ " ${UI_RESULT} " == *" CERT "* ]] && RM_CERT=1
    ((RM_BACKUPS)) && RM_FINAL_BACKUP=0
    return 0
}

_validate_delete_word() {
    [[ "${FORM_VALUES[0]}" == DELETE ]] && return 0
    FORM_ERROR="Type DELETE in capitals to confirm."
    return 1
}

scr_uninstall_confirm() {
    local t
    t="{e}This cannot be undone.{/}\n\nRemoved: $(tx "$APP_DIR"), services, scheduler entry, Nginx site"
    ((RM_DATABASE)) && t+=", {e}database ${DB_NAME}{/}"
    ((RM_BACKUPS)) && t+=", {e}all backups{/}"
    ((RM_CERT)) && t+=", SSL certificate"
    t+="."
    ((RM_FINAL_BACKUP)) && t+="\n\nA final backup is written to ${BACKUP_DIR} first."
    t+="\n\nType DELETE to continue."
    local saved="$UI_DANGER"
    UI_DANGER=1
    form_reset
    form_add "Confirm" "" text
    FORM_VALIDATE=_validate_delete_word
    UI_FORM_NEXT="Uninstall"
    ui_form "Uninstall DezerX Spartan" "$t"
    local rc=$?
    UI_FORM_NEXT=""
    UI_DANGER="$saved"
    ui_force_redraw
    return "$rc"
}

un_backup() {
    ((RM_FINAL_BACKUP)) || return 3
    task "Preparing ${BACKUP_DIR}" backup_prepare_dir || return 1
    task "Backing up the application files" create_app_backup || return 1
    if [[ -n "$DB_NAME" && -n "$DB_USER" ]]; then
        task "Backing up the database" create_db_backup || warn_add "The database could not be backed up."
    fi
    return 0
}

remove_nginx_site() {
    nginx_layout_detect
    rm -f "$NGINX_CONF_PATH" "$NGINX_CONF_OLD_PATH" "$NGINX_UPSTREAM_CONF"
    [[ -n "$NGINX_ENABLED" ]] && rm -f "${NGINX_ENABLED}/spartan.conf" "${NGINX_ENABLED}/dezerx.conf"
    have nginx || return 0
    nginx -t && systemctl reload nginx
}

drop_database() {
    local user host
    user="$(_sql_str "$DB_USER")"
    host="$(_sql_str "$DB_HOST")"
    db_root_sql "DROP DATABASE IF EXISTS \`${DB_NAME}\`; DROP USER IF EXISTS '${user}'@'${host}'; FLUSH PRIVILEGES;"
}

delete_certificate() {
    [[ -n "$DOMAIN" ]] || return 0
    if have certbot && [[ -d "${LETSENCRYPT_LIVE}/${DOMAIN}" ]]; then
        certbot delete --non-interactive --cert-name "$DOMAIN" || return 1
    fi
    [[ -d "${SELF_SIGNED_BASE}/${DOMAIN}" ]] && rm -rf -- "${SELF_SIGNED_BASE:?}/${DOMAIN}"
    return 0
}

delete_backups() {
    [[ -d "$BACKUP_DIR" ]] || return 0
    local p
    while read -r p; do rm -f -- "${BACKUP_DIR}/${p}"*; done < <(backup_prefixes)
    echo "Backups removed."
}

un_remove() {
    task "Stopping and removing the services" remove_spartan_services || return 1
    task "Removing the scheduler entry" remove_cron || true
    task "Removing the Nginx site" remove_nginx_site || warn_add "Nginx did not reload cleanly; check: nginx -t"
    task "Deleting ${APP_DIR}" safe_rm_rf "$APP_DIR" || return 1
    if ((RM_DATABASE)); then
        task "Deleting the database and user" drop_database || warn_add "The database could not be deleted; remove ${DB_NAME} by hand."
    fi
    if ((RM_CERT)); then
        task "Deleting the SSL certificate" delete_certificate || warn_add "The certificate could not be deleted."
    fi
    if ((RM_BACKUPS)); then
        task "Deleting backups" delete_backups || true
    fi
    return 0
}

uninstall_run() {
    plan_new "Uninstalling DezerX Spartan"
    plan_add backup "Creating a final backup" 40 un_backup
    plan_add remove "Removing DezerX Spartan" 60 un_remove
    if plan_run; then
        summary_reset "Uninstalled" 1
        summary_add "DezerX Spartan was removed from $(tx "$APP_DIR")."
        ((RM_FINAL_BACKUP)) && summary_kv "Backup" "${APP_BACKUP_FILE}"
        ((RM_DATABASE)) || summary_add "\nThe database ${DB_NAME} was kept."
        summary_add "PHP, Nginx, the database server and $(kv_name) are still installed."
        summary_show
        return 0
    fi
    show_failure "Uninstall failed" ""
    summary_show
    return 1
}

flow_uninstall() {
    RM_FINAL_BACKUP=1 RM_DATABASE=0 RM_BACKUPS=0 RM_CERT=0
    wizard_run scr_uninstall_pick scr_uninstall_options scr_uninstall_confirm || return 1
    uninstall_run
}
