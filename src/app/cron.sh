cron_line() {
    printf '* * * * * cd %s && PHP_INI_SCAN_DIR=:%s nice -n 10 php artisan schedule:run >> /dev/null 2>&1' "$APP_DIR" "$PHP_CRON_INI_DIR"
}

cron_match_regex() {
    local escaped
    escaped="$(printf '%s' "$APP_DIR" | sed 's/[][\.*^$(){}?+|]/\\&/g')"
    printf 'cd %s .*artisan schedule:run' "$escaped"
}

ensure_cron_running() {
    local svc="crond"
    is_debian_family && svc="cron"
    start_service "$svc" && return 0
    warn_add "The cron service (${svc}) could not be started; scheduled tasks will not run until it is."
    return 0
}

setup_cron() {
    ensure_cron_running
    have crontab || { warn_add "crontab is missing; add the scheduler manually: $(cron_line)"; return 0; }
    local tmp re
    tmp="$(mktemp)"
    re="$(cron_match_regex)"
    { crontab -l 2>/dev/null || true; } | grep -vE "$re" >"$tmp"
    cron_line >>"$tmp"
    printf '\n' >>"$tmp"
    crontab "$tmp"
    local rc=$?
    rm -f "$tmp"
    return "$rc"
}

remove_cron() {
    have crontab || return 0
    local tmp re
    tmp="$(mktemp)"
    re="$(cron_match_regex)"
    { crontab -l 2>/dev/null || true; } | grep -vE "$re" >"$tmp"
    crontab "$tmp"
    rm -f "$tmp"
}
