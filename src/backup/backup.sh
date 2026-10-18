# shellcheck shell=bash
# Backups taken before an update (and before uninstalling or overwriting).
#
# File names and the "keep 7 of each" rotation match 1.x. The directory moved
# from /tmp/spartan (cleared on reboot, world-readable) to /var/backups/spartan
# with mode 700; backups found in the old place are moved over once.

backup_prefixes() {
    printf '%s\n' spartan_backup_ spartan_db_backup_ spartan_php_backup_ spartan_ioncube_backup_ \
        spartan_conf_backup_ spartan_sys_backup_
}

backup_prepare_dir() {
    (umask 077 && mkdir -p "$BACKUP_DIR") || return 1
    chmod 700 "$BACKUP_DIR"
    BACKUP_TS="$(date +%Y%m%d%H%M%S)"
    if [[ -d "$LEGACY_BACKUP_DIR" && "$LEGACY_BACKUP_DIR" != "$BACKUP_DIR" ]]; then
        local f n=0
        for f in "$LEGACY_BACKUP_DIR"/spartan_*; do
            [[ -f "$f" ]] || continue
            mv -n -- "$f" "$BACKUP_DIR/" && chmod 600 "${BACKUP_DIR}/$(basename "$f")" && n=$((n + 1))
        done
        ((n)) && echo "Moved ${n} backup(s) from ${LEGACY_BACKUP_DIR} to ${BACKUP_DIR}."
    fi
    return 0
}

# Space check before anything is written: application (without node_modules)
# plus database, with 20% headroom.
backup_check_space() {
    local app_mb db_mb need free
    app_mb="$(dir_size_mb "$APP_DIR" --exclude=node_modules)"
    db_mb="$(db_size_mb 2>/dev/null)"
    [[ "$app_mb" =~ ^[0-9]+$ ]] || app_mb=0
    [[ "$db_mb" =~ ^[0-9]+$ ]] || db_mb=0
    need=$(((app_mb + db_mb) * 12 / 10 + 512))
    free="$(free_mb "$BACKUP_DIR")"
    echo "Backup needs about ${need} MB, ${free} MB free in ${BACKUP_DIR}."
    if [[ "$free" =~ ^[0-9]+$ ]] && ((free < need)); then
        phase_fail "Not enough disk space for the backup: about ${need} MB needed, ${free} MB free in ${BACKUP_DIR}."
        return 1
    fi
    return 0
}

create_app_backup() {
    APP_BACKUP_FILE="${BACKUP_DIR}/spartan_backup_${BACKUP_TS}.tar.gz"
    local rc=0
    (umask 077 && tar -czf "$APP_BACKUP_FILE" -C "$(dirname "$APP_DIR")" \
        --exclude="$(basename "$APP_DIR")/node_modules" --exclude="$(basename "$APP_DIR")/.cleanup.*" \
        --warning=no-file-changed "$(basename "$APP_DIR")") || rc=$?
    # GNU tar exits 1 when a file changed while it was read (a log being
    # written); the archive is still complete.
    if ((rc > 1)) || [[ ! -s "$APP_BACKUP_FILE" ]]; then
        echo "tar failed with exit code ${rc}."
        return 1
    fi
    echo "Application backup: ${APP_BACKUP_FILE} ($(fmt_bytes "$(stat -c %s "$APP_BACKUP_FILE")"))"
}

create_db_backup() {
    DB_BACKUP_FILE="${BACKUP_DIR}/spartan_db_backup_${BACKUP_TS}.sql.gz"
    (umask 077 && db_dump "$DB_BACKUP_FILE") || return 1
    echo "Database backup: ${DB_BACKUP_FILE} ($(fmt_bytes "$(stat -c %s "$DB_BACKUP_FILE")"))"
}

create_nginx_backup() {
    NGINX_BACKUP_FILE="${BACKUP_DIR}/spartan_conf_backup_${BACKUP_TS}.conf"
    NGINX_RESTORE_PATH=""
    if [[ -n "$NGINX_CONF_OLD_PATH" && -f "$NGINX_CONF_OLD_PATH" ]]; then
        NGINX_RESTORE_PATH="$NGINX_CONF_OLD_PATH"
    elif [[ -n "$NGINX_CONF_PATH" && -f "$NGINX_CONF_PATH" ]]; then
        NGINX_RESTORE_PATH="$NGINX_CONF_PATH"
    fi
    if [[ -z "$NGINX_RESTORE_PATH" ]]; then
        NGINX_BACKUP_FILE=""
        echo "No Spartan vhost to back up."
        return 0
    fi
    install -m 600 "$NGINX_RESTORE_PATH" "$NGINX_BACKUP_FILE" && echo "Nginx vhost backup: ${NGINX_BACKUP_FILE}"
}

# _tar_list <archive> <path>... - archives the paths that exist (relative to /).
_tar_list() {
    local out="$1"
    shift
    local -a rel=()
    local p
    for p in "$@"; do
        [[ -e "$p" ]] && rel+=("${p#/}")
    done
    ((${#rel[@]})) || return 3
    (umask 077 && tar -czf "$out" -C / "${rel[@]}")
}

create_php_backup() {
    PHP_BACKUP_FILE="${BACKUP_DIR}/spartan_php_backup_${BACKUP_TS}.tar.gz"
    local -a files=()
    mapfile -t files < <(find /etc/php* -type f \( -name '*ioncube*.ini' -o -name '10-opcache-custom.ini' \) 2>/dev/null)
    local pool
    pool="$(php_fpm_pool_conf 2>/dev/null)" && files+=("$pool")
    _tar_list "$PHP_BACKUP_FILE" "${files[@]}"
    local rc=$?
    if ((rc == 3)); then
        PHP_BACKUP_FILE=""
        echo "No PHP configuration to back up."
        return 0
    fi
    ((rc == 0)) && echo "PHP configuration backup: ${PHP_BACKUP_FILE}"
    return "$rc"
}

create_ioncube_backup() {
    IONCUBE_BACKUP_FILE="${BACKUP_DIR}/spartan_ioncube_backup_${BACKUP_TS}.tar.gz"
    local -a files=()
    mapfile -t files < <(find "$IONCUBE_DIR" -maxdepth 1 -type f -name 'ioncube_loader_lin_*.so' 2>/dev/null)
    _tar_list "$IONCUBE_BACKUP_FILE" "${files[@]}"
    local rc=$?
    if ((rc == 3)); then
        IONCUBE_BACKUP_FILE=""
        echo "No ionCube loader to back up."
        return 0
    fi
    ((rc == 0)) && echo "ionCube backup: ${IONCUBE_BACKUP_FILE}"
    return "$rc"
}

# Service units, the Octane upstream, /etc/dezerx and root's crontab, so a
# rollback also undoes service changes.
create_sys_backup() {
    SYS_BACKUP_FILE="${BACKUP_DIR}/spartan_sys_backup_${BACKUP_TS}.tar.gz"
    mkdir -p /etc/dezerx
    if have crontab; then
        (umask 077 && crontab -l >/etc/dezerx/crontab.root.bak 2>/dev/null) || rm -f /etc/dezerx/crontab.root.bak
    fi
    _tar_list "$SYS_BACKUP_FILE" "$OCTANE_SERVICE" "$QUEUE_TEMPLATE" "$QUEUE_TARGET" "$LEGACY_QUEUE_SERVICE" \
        "$NGINX_UPSTREAM_CONF" /etc/dezerx
    local rc=$?
    ((rc == 3)) && { SYS_BACKUP_FILE=""; return 0; }
    ((rc == 0)) && echo "Service configuration backup: ${SYS_BACKUP_FILE}"
    return "$rc"
}

rotate_backups() {
    local prefix
    while read -r prefix; do
        # shellcheck disable=SC2012
        ls -1t "${BACKUP_DIR}/${prefix}"* 2>/dev/null | tail -n +$((BACKUP_KEEP + 1)) | while IFS= read -r f; do
            rm -f -- "$f" && echo "Removed old backup $(basename "$f")"
        done
    done < <(backup_prefixes)
    return 0
}

backups_newest() {
    # shellcheck disable=SC2012
    ls -1t "${BACKUP_DIR}"/spartan_backup_*.tar.gz 2>/dev/null | head -n1
}

backups_total_mb() {
    du -sm "$BACKUP_DIR" 2>/dev/null | awk '{ print $1 }'
}
