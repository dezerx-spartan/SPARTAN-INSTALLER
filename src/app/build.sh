artisan() { (cd "$APP_DIR" && php artisan "$@" --no-interaction); }

app_maintenance_on() {
    [[ -f "${APP_DIR}/artisan" ]] || return 0
    artisan down || true
    APP_IN_MAINTENANCE=1
}

app_maintenance_off() {
    [[ -f "${APP_DIR}/artisan" ]] || return 0
    artisan up || true
    APP_IN_MAINTENANCE=0
}

app_composer_install() {
    [[ -f "${APP_DIR}/composer.json" ]] || return 0
    composer_run install --no-dev --optimize-autoloader --prefer-dist --no-progress
}

app_npm_install() {
    if [[ -f "${APP_DIR}/package-lock.json" ]]; then
        (cd "$APP_DIR" && npm ci --no-audit --no-fund)
    elif [[ -f "${APP_DIR}/package.json" ]]; then
        (cd "$APP_DIR" && npm install --no-audit --no-fund)
    fi
}

app_npm_build() {
    [[ -f "${APP_DIR}/package.json" ]] || return 0
    local ram swap total target=4096 overhead=512
    ram="$(mem_total_mb)"
    swap="$(swap_total_mb)"
    total=$((ram + swap))
    echo "Memory: ${ram} MB RAM + ${swap} MB swap"
    if ((total < target)); then
        local need=$((target - total + overhead))
        if swap_temp_on "$need"; then
            total=$((total + need))
        else
            echo "Building with the memory that is available."
        fi
    fi
    local heap=$((total - overhead))
    ((heap < 512)) && heap=512
    ((heap > 8192)) && heap=8192
    echo "NODE_OPTIONS=--max-old-space-size=${heap}"
    local rc=0
    (cd "$APP_DIR" && NODE_OPTIONS="--max-old-space-size=${heap}" npm run build) || rc=$?
    swap_temp_off
    return "$rc"
}

app_storage_link() {
    [[ -L "${APP_DIR}/public/storage" && -e "${APP_DIR}/public/storage" ]] && { echo "public/storage link exists."; return 0; }
    rm -f "${APP_DIR}/public/storage" 2>/dev/null
    artisan storage:link
}

app_theme_restore() {
    [[ "$css_save_methode" == php ]] || return 0
    artisan theme:backup --restore
}

app_optimize_clear() { artisan optimize:clear; }
