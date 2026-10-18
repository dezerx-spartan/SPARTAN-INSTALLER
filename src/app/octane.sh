octane_wanted() { [[ "$OCTANE_ENABLED" == 1 ]]; }

octane_is_installed() { [[ -d "${APP_DIR}/vendor/laravel/octane" && -f "${APP_DIR}/config/octane.php" ]]; }

octane_code_is_ready() {
    local f
    for f in app/Octane/Runtime.php app/Octane/Listeners/FlushApplicationState.php app/Http/Middleware/EnforceOperationalState.php; do
        if [[ ! -f "${APP_DIR}/${f}" ]]; then
            OCTANE_BLOCK_REASON="this Spartan release predates Octane support (missing ${f})"
            return 1
        fi
    done
    if grep -q 'enforceOperationalState()' "${APP_DIR}/routes/web.php" 2>/dev/null; then
        OCTANE_BLOCK_REASON="routes/web.php still enforces app state at boot time, which is not Octane-safe"
        return 1
    fi
    if grep -qE '\]\)->send\(\);' "${APP_DIR}/app/Helpers/ApplicationStateManager.php" 2>/dev/null; then
        OCTANE_BLOCK_REASON="ApplicationStateManager still terminates the process instead of returning a response"
        return 1
    fi
    return 0
}

usable_mem_mb() {
    [[ -n "$MEM_TOTAL_MB" ]] || detect_resources
    local reserved=1024
    ((MEM_TOTAL_MB <= 2048)) && reserved=512
    ((MEM_TOTAL_MB <= 1024)) && reserved=320
    local usable=$((MEM_TOTAL_MB - reserved))
    ((usable < 256)) && usable=256
    echo "$usable"
}

recommend_octane_workers() {
    [[ -n "$CPU_CORES" ]] || detect_resources
    local usable by_cpu by_ram r
    usable="$(usable_mem_mb)"
    by_cpu=$((CPU_CORES * 2))
    by_ram=$(((usable / 2) / 128))
    r=$by_cpu
    ((by_ram < r)) && r=$by_ram
    ((r < 1)) && r=1
    ((r > 24)) && r=24
    echo "$r"
}

recommend_queue_workers() {
    [[ -n "$CPU_CORES" ]] || detect_resources
    local usable by_ram r
    usable="$(usable_mem_mb)"
    by_ram=$(((usable / 3) / 192))
    r=$CPU_CORES
    ((by_ram < r)) && r=$by_ram
    ((r < 1)) && r=1
    ((r > 12)) && r=12
    echo "$r"
}

pick_octane_port() {
    if [[ -n "$OCTANE_PORT" ]]; then
        echo "$OCTANE_PORT"
        return 0
    fi
    local env_port
    env_port="$(env_read_value OCTANE_PORT)"
    if [[ "$env_port" =~ ^[0-9]+$ ]] && [[ -f "$OCTANE_SERVICE" ]]; then
        echo "$env_port"
        return 0
    fi
    local p=8000
    while ((p < 8100)); do
        if port_is_free "$p" && port_is_free $((p - 1999)); then
            echo "$p"
            return 0
        fi
        p=$((p + 1))
    done
    echo 8000
}

octane_runtime_defaults() {
    [[ -n "$OCTANE_HOST" ]] || OCTANE_HOST="127.0.0.1"
    [[ -n "$OCTANE_PORT" ]] || OCTANE_PORT="$(env_read_value OCTANE_PORT)"
    [[ "$OCTANE_PORT" =~ ^[0-9]+$ ]] || OCTANE_PORT="8000"
    [[ -n "$OCTANE_WORKERS" ]] || OCTANE_WORKERS="$(env_read_value OCTANE_WORKERS)"
    [[ "$OCTANE_WORKERS" =~ ^[0-9]+$ ]] || OCTANE_WORKERS="$(recommend_octane_workers)"
}

octane_update_default() {
    [[ -n "$OCTANE_CHOICE" ]] && return 0
    local flag
    flag="$(env_read_value OCTANE_ENABLED)"
    if [[ "${flag,,}" == false ]]; then
        OCTANE_ENABLED=0
    else
        OCTANE_ENABLED=1
    fi
    return 0
}

octane_install_package() {
    [[ -d "${APP_DIR}/vendor/laravel/octane" ]] && return 0
    composer_run require laravel/octane spiral/roadrunner-cli spiral/roadrunner-http --optimize-autoloader --prefer-dist --no-progress
}

octane_fetch_binary() {
    artisan octane:install --server=roadrunner || return 1
    [[ -x "${APP_DIR}/rr" ]] || { echo "The RoadRunner binary was not downloaded."; return 1; }
}

setup_systemd_octane() {
    local php_bin
    php_bin="$(command -v php || echo /usr/bin/php)"
    cat >"$OCTANE_SERVICE" <<EOF
[Unit]
Description=DezerX Spartan Octane Server (RoadRunner)
After=network.target
StartLimitBurst=5
StartLimitIntervalSec=60

[Service]
Type=simple
User=${APP_USER}
Group=${APP_GROUP}
WorkingDirectory=${APP_DIR}
Environment=LARAVEL_OCTANE=1
Environment=PHP_INI_SCAN_DIR=:${PHP_OCTANE_INI_DIR}
ExecStart=${php_bin} ${APP_DIR}/artisan octane:start --server=roadrunner --host=${OCTANE_HOST} --port=${OCTANE_PORT} --workers=${OCTANE_WORKERS} --max-requests=${OCTANE_MAX_REQUESTS}
ExecReload=${php_bin} ${APP_DIR}/artisan octane:reload
Restart=always
RestartSec=5
KillSignal=SIGTERM
TimeoutStopSec=30
StandardOutput=journal
StandardError=journal
SyslogIdentifier=dezerx-octane

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable dezerx-octane.service
}

remove_octane_service() {
    [[ -f "$OCTANE_SERVICE" ]] || return 0
    systemctl disable --now dezerx-octane.service >/dev/null 2>&1
    rm -f "$OCTANE_SERVICE"
    systemctl daemon-reload
}

setup_octane() {
    if ! octane_wanted; then
        env_write_value OCTANE_ENABLED false
        task "Removing the Octane service" remove_octane_service || true
        return 0
    fi
    if ! octane_code_is_ready; then
        warn_add "Octane was skipped: ${OCTANE_BLOCK_REASON}. The site runs on PHP-FPM; update Spartan and run the installer again to enable it."
        OCTANE_ENABLED=0
        env_write_value OCTANE_ENABLED false
        task "Removing the Octane service" remove_octane_service || true
        return 0
    fi
    if ! task "Installing Laravel Octane" octane_install_package; then
        warn_add "Laravel Octane could not be installed; the site runs on PHP-FPM."
        OCTANE_ENABLED=0
        env_write_value OCTANE_ENABLED false
        return 0
    fi
    if ! task "Fetching the RoadRunner server" octane_fetch_binary; then
        warn_add "RoadRunner could not be set up; the site runs on PHP-FPM."
        OCTANE_ENABLED=0
        env_write_value OCTANE_ENABLED false
        return 0
    fi
    OCTANE_PORT="$(pick_octane_port)"
    [[ "$OCTANE_WORKERS" =~ ^[0-9]+$ ]] || OCTANE_WORKERS="$(recommend_octane_workers)"
    env_write_value OCTANE_ENABLED true
    env_write_value OCTANE_SERVER roadrunner
    env_write_value OCTANE_HOST "$OCTANE_HOST"
    env_write_value OCTANE_PORT "$OCTANE_PORT"
    env_write_value OCTANE_WORKERS "$OCTANE_WORKERS"
    env_write_value OCTANE_MAX_REQUESTS "$OCTANE_MAX_REQUESTS"
    env_write_value OCTANE_MAX_EXECUTION_TIME 120
    chown "${APP_USER}:${APP_GROUP}" "${APP_DIR}/rr" 2>/dev/null
    chmod 0755 "${APP_DIR}/rr" 2>/dev/null
    [[ -f "${APP_DIR}/.rr.yaml" ]] && chown "${APP_USER}:${APP_GROUP}" "${APP_DIR}/.rr.yaml"
    task "Creating the Octane service (${OCTANE_WORKERS} workers on port ${OCTANE_PORT})" setup_systemd_octane
}

wait_for_octane() {
    local i code
    for ((i = 0; i < 20; i++)); do
        code="$(curl -s -o /dev/null -m 3 -w '%{http_code}' "http://${OCTANE_HOST}:${OCTANE_PORT}/up" 2>/dev/null)"
        if [[ -n "$code" && "$code" != 000 ]]; then
            echo "Octane answers on ${OCTANE_HOST}:${OCTANE_PORT} (HTTP ${code})."
            return 0
        fi
        sleep 2
    done
    echo "Octane did not answer within 40 seconds. See: journalctl -u dezerx-octane -n 100 --no-pager"
    return 1
}

restart_octane() {
    octane_wanted || return 0
    [[ -f "$OCTANE_SERVICE" ]] || return 0
    octane_runtime_defaults
    systemctl restart dezerx-octane.service || return 1
    wait_for_octane
}
