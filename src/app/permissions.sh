detect_web_user_group() {
    local user="" group="" method=""
    if [[ -f /etc/nginx/nginx.conf ]]; then
        read -r user group < <(grep -E '^[[:space:]]*user[[:space:]]' /etc/nginx/nginx.conf | tr -d ';' | awk '{ print $2, $3 }' | head -n1)
        [[ -n "$user" ]] && method="nginx.conf"
    fi
    if [[ -z "$user" ]] && have pgrep; then
        user="$(ps -o user= -C nginx 2>/dev/null | grep -v '^root$' | head -n1)"
        [[ -n "$user" ]] && method="running nginx"
    fi
    if [[ -z "$user" ]]; then
        local u
        for u in www-data nginx www; do
            id "$u" >/dev/null 2>&1 && { user="$u"; method="system user"; break; }
        done
    fi
    if [[ -z "$user" ]] || ! id "$user" >/dev/null 2>&1; then
        user="$APP_USER_DEFAULT"
        method="default"
    fi
    [[ -n "$group" ]] || group="$(id -gn "$user" 2>/dev/null || echo "$user")"
    APP_USER="$user"
    APP_GROUP="$group"
    log "Web user: ${APP_USER}:${APP_GROUP} (${method})"
}

apply_permissions() {
    [[ -d "$APP_DIR" ]] || { echo "${APP_DIR} does not exist."; return 1; }
    path_is_protected "$APP_DIR" && { echo "Refusing to change permissions on ${APP_DIR}."; return 1; }
    chown -R "${APP_USER}:${APP_GROUP}" "$APP_DIR" || return 1
    chmod -R u+rwX,go+rX,go-w "$APP_DIR" || return 1
    local d
    for d in storage bootstrap/cache; do
        [[ -d "${APP_DIR}/${d}" ]] && chmod -R ug+rwX "${APP_DIR}/${d}"
    done
    [[ -f "${APP_DIR}/.env" ]] && chmod 640 "${APP_DIR}/.env"
    [[ -f "${APP_DIR}/rr" ]] && chmod 755 "${APP_DIR}/rr"
    echo "Ownership ${APP_USER}:${APP_GROUP} applied to ${APP_DIR}."
}
