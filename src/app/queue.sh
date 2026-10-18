# shellcheck shell=bash
# Queue workers: dezerx-queue@1..N grouped under dezerx.target (1.x layout).

setup_systemd_queue() {
    [[ "$QUEUE_WORKERS" =~ ^[0-9]+$ ]] || QUEUE_WORKERS="$(recommend_queue_workers)"
    ((QUEUE_WORKERS < 1)) && QUEUE_WORKERS=1
    ((QUEUE_WORKERS > 32)) && QUEUE_WORKERS=32
    env_write_value QUEUE_WORKERS "$QUEUE_WORKERS"

    local php_bin
    php_bin="$(command -v php || echo /usr/bin/php)"
    if [[ -f "$LEGACY_QUEUE_SERVICE" ]]; then
        systemctl disable --now dezerx.service >/dev/null 2>&1
        rm -f "$LEGACY_QUEUE_SERVICE"
    fi

    cat >"$QUEUE_TEMPLATE" <<EOF
[Unit]
Description=DezerX Spartan Queue Worker %i
After=network.target
PartOf=dezerx.target
StartLimitBurst=5
StartLimitIntervalSec=60

[Service]
Type=simple
User=${APP_USER}
Group=${APP_GROUP}
WorkingDirectory=${APP_DIR}
Environment=PHP_INI_SCAN_DIR=:${PHP_OCTANE_INI_DIR}
Nice=10
CPUWeight=20
ExecStart=${php_bin} ${APP_DIR}/artisan queue:work --queue=critical,high,medium,default,low --sleep=3 --tries=3 --max-time=3600
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=dezerx-worker-%i

[Install]
WantedBy=dezerx.target
EOF

    {
        echo "[Unit]"
        echo "Description=DezerX Spartan Queue Workers"
        echo "After=network.target"
        local i
        for ((i = 1; i <= QUEUE_WORKERS; i++)); do echo "Wants=dezerx-queue@${i}.service"; done
        echo
        echo "[Install]"
        echo "WantedBy=multi-user.target"
    } >"$QUEUE_TARGET"

    systemctl daemon-reload || return 1

    local unit idx
    while read -r unit; do
        [[ -n "$unit" ]] || continue
        idx="${unit#dezerx-queue@}"
        idx="${idx%.service}"
        if [[ ! "$idx" =~ ^[0-9]+$ ]] || ((idx > QUEUE_WORKERS)); then
            systemctl disable --now "$unit" >/dev/null 2>&1
            echo "Removed surplus worker ${unit}"
        fi
    done < <(systemctl list-units --all --plain --no-legend 'dezerx-queue@*.service' 2>/dev/null | awk '{ print $1 }')

    local -a instances=()
    for ((i = 1; i <= QUEUE_WORKERS; i++)); do instances+=("dezerx-queue@${i}.service"); done
    systemctl enable dezerx.target >/dev/null 2>&1
    systemctl enable "${instances[@]}" >/dev/null 2>&1
    systemctl restart "${instances[@]}" || true
    systemctl start dezerx.target || true
    echo "${QUEUE_WORKERS} queue worker(s) running."
}

remove_spartan_services() {
    remove_octane_service
    local unit
    while read -r unit; do
        [[ -n "$unit" ]] && systemctl disable --now "$unit" >/dev/null 2>&1
    done < <(systemctl list-units --all --plain --no-legend 'dezerx-queue@*.service' 2>/dev/null | awk '{ print $1 }')
    [[ -f "$QUEUE_TEMPLATE" ]] && rm -f "$QUEUE_TEMPLATE"
    if [[ -f "$QUEUE_TARGET" ]]; then
        systemctl disable --now dezerx.target >/dev/null 2>&1
        rm -f "$QUEUE_TARGET"
    fi
    if [[ -f "$LEGACY_QUEUE_SERVICE" ]]; then
        systemctl disable --now dezerx.service >/dev/null 2>&1
        rm -f "$LEGACY_QUEUE_SERVICE"
    fi
    rm -f "$NGINX_UPSTREAM_CONF"
    systemctl daemon-reload
    return 0
}

restart_queue_workers() {
    local -a units
    mapfile -t units < <(systemctl list-units --all --plain --no-legend 'dezerx-queue@*.service' 2>/dev/null | awk '{ print $1 }')
    ((${#units[@]})) || return 0
    systemctl restart "${units[@]}"
}
