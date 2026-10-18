is_systemd() {
    [[ -d /run/systemd/system ]] && return 0
    [[ "$(ps -p 1 -o comm= 2>/dev/null)" == systemd ]]
}

svc_exists() {
    local u="${1%.service}.service"
    systemctl list-unit-files --no-legend "$u" 2>/dev/null | grep -q . && return 0
    [[ -f "/etc/systemd/system/$u" || -f "/lib/systemd/system/$u" || -f "/usr/lib/systemd/system/$u" ]]
}

svc_active() { systemctl is-active --quiet "$1" 2>/dev/null; }

svc_enable_now() { systemctl enable --now "$1"; }

svc_restart() { systemctl restart "$1"; }

svc_stop_disable() {
    systemctl disable --now "$1" >/dev/null 2>&1
    return 0
}

svc_reload_or_restart() {
    systemctl reload "$1" 2>/dev/null || systemctl restart "$1"
}

start_service() {
    local svc="$1"
    if is_systemd && have systemctl; then
        systemctl enable --now "$svc" && return 0
        systemctl start "$svc" && return 0
    fi
    if have rc-service; then
        rc-service "$svc" start && return 0
    fi
    if have service; then
        service "$svc" start && return 0
    fi
    return 1
}

svc_wait_active() {
    local unit="$1" tries="${2:-10}" i
    for ((i = 0; i < tries; i++)); do
        svc_active "$unit" && return 0
        sleep 1
    done
    return 1
}
