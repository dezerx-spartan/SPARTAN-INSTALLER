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

PNPM_FLAGS=(--config.node-linker=hoisted --config.confirm-modules-purge=false
    --config.dangerously-allow-all-builds=true --config.update-notifier=false)

app_pnpm_install() {
    [[ -f "${APP_DIR}/package.json" ]] || return 0
    (
        cd "$APP_DIR" || exit 1
        if [[ -d node_modules && ! -f node_modules/.modules.yaml ]]; then
            echo "Removing node_modules installed by npm"
            rm -rf node_modules
        fi
        if [[ ! -f pnpm-lock.yaml && -f package-lock.json ]]; then
            pnpm import "${PNPM_FLAGS[@]}" || rm -f pnpm-lock.yaml
        fi
        if [[ -f pnpm-lock.yaml ]]; then
            if pnpm install --frozen-lockfile "${PNPM_FLAGS[@]}"; then
                pnpm store prune >/dev/null 2>&1 || true
                exit 0
            fi
            echo "The lockfile does not match package.json; resolving again."
        fi
        pnpm install --no-frozen-lockfile "${PNPM_FLAGS[@]}" || exit 1
        pnpm store prune >/dev/null 2>&1 || true
    )
}

app_pnpm_build() {
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
    (cd "$APP_DIR" && NODE_OPTIONS="--max-old-space-size=${heap}" pnpm run build) || rc=$?
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
