redis_cli_bin() {
    if have redis-cli; then echo redis-cli; elif have valkey-cli; then echo valkey-cli; fi
}

redis_is_up() {
    local cli
    cli="$(redis_cli_bin)"
    if [[ -n "$cli" ]]; then
        [[ "$("$cli" -h 127.0.0.1 -p 6379 ping 2>/dev/null)" == PONG ]]
    else
        php -r 'exit(@fsockopen("127.0.0.1", 6379) ? 0 : 1);' >/dev/null 2>&1
    fi
}

redis_service_name() {
    local s
    for s in redis-server redis valkey; do
        svc_exists "$s" && { echo "$s"; return 0; }
    done
    echo redis-server
}

redis_conf_path() {
    local c
    for c in /etc/redis/redis.conf /etc/redis.conf /etc/valkey/valkey.conf; do
        [[ -f "$c" ]] && { echo "$c"; return 0; }
    done
}

php_redis_ping() {
    php -r '
        [, $host, $port, $password, $username, $url] = $argv;
        $blank = fn ($v) => $v === null || $v === "" || strtolower((string) $v) === "null";
        if (!class_exists("Redis")) { exit(2); }
        if (!$blank($url)) {
            $p = parse_url($url);
            if ($p === false || empty($p["host"])) { exit(1); }
            $host = (in_array(strtolower($p["scheme"] ?? ""), ["tls", "rediss"], true) ? "tls://" : "").$p["host"];
            $port = $p["port"] ?? $port;
            $username = isset($p["user"]) ? rawurldecode($p["user"]) : $username;
            $password = isset($p["pass"]) ? rawurldecode($p["pass"]) : $password;
        }
        try {
            $r = new Redis();
            if (!@$r->connect($blank($host) ? "127.0.0.1" : $host, $blank($port) ? 6379 : (int) $port, 2.0)) { exit(1); }
            if (!$blank($password) && !$r->auth($blank($username) ? $password : [$username, $password])) { exit(1); }
            exit($r->ping() ? 0 : 1);
        } catch (Throwable $e) { exit(1); }
    ' "${1:-}" "${2:-}" "${3:-}" "${4:-}" "${5:-}" >/dev/null 2>&1
}

app_uses_working_redis() {
    [[ "$(env_read_value CACHE_STORE)" == redis && "$(env_read_value QUEUE_CONNECTION)" == redis ]] || return 1
    php_redis_ping "$(env_read_value REDIS_HOST)" "$(env_read_value REDIS_PORT)" "$(env_read_value REDIS_PASSWORD)" \
        "$(env_read_value REDIS_USERNAME)" "$(env_read_value REDIS_URL)"
}

install_redis() {
    if [[ -f "${APP_DIR}/.env" ]] && app_uses_working_redis; then
        echo "Spartan already uses a working Redis; leaving it as it is."
        return 0
    fi
    local installed_now=0
    if ! have redis-server && ! have valkey-server; then
        if is_debian_family; then
            pkg_install redis-server || true
        else
            pkg_install redis || pkg_install valkey || true
        fi
        { have redis-server || have valkey-server; } && installed_now=1
    fi
    if ! have redis-server && ! have valkey-server; then
        warn_add "Redis could not be installed; Spartan keeps using the database for cache and queue."
        return 0
    fi
    start_service "$(redis_service_name)" || true
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        redis_is_up && break
        sleep 1
    done
    if ! redis_is_up; then
        warn_add "Redis does not answer on 127.0.0.1:6379; Spartan keeps using the database for cache and queue."
        return 0
    fi
    ((installed_now)) && config_redis
    return 0
}

config_redis() {
    local cli conf
    cli="$(redis_cli_bin)"
    conf="$(redis_conf_path)"
    [[ -n "$cli" && -n "$conf" ]] || return 0
    grep -q "^# dezerx-spartan tuning" "$conf" 2>/dev/null && return 0
    [[ -n "$MEM_TOTAL_MB" ]] || detect_resources
    local max_mb=$((MEM_TOTAL_MB / 20))
    ((max_mb < 64)) && max_mb=64
    ((max_mb > 512)) && max_mb=512
    local block="# dezerx-spartan tuning" current_max
    current_max="$("$cli" -h 127.0.0.1 -p 6379 config get maxmemory 2>/dev/null | tail -n 1)"
    if [[ "$current_max" == 0 ]]; then
        "$cli" -h 127.0.0.1 -p 6379 config set maxmemory "${max_mb}mb" >/dev/null &&
            "$cli" -h 127.0.0.1 -p 6379 config set maxmemory-policy volatile-lru >/dev/null
        block+=$'\n'"maxmemory ${max_mb}mb"$'\n'"maxmemory-policy volatile-lru"
    fi
    if [[ "$("$cli" -h 127.0.0.1 -p 6379 config get appendonly 2>/dev/null | tail -n 1)" != yes ]]; then
        "$cli" -h 127.0.0.1 -p 6379 config set appendonly yes >/dev/null
        local i
        for i in $(seq 1 30); do
            "$cli" -h 127.0.0.1 -p 6379 info persistence 2>/dev/null | grep -q "aof_rewrite_in_progress:0" && break
            sleep 1
        done
    fi
    block+=$'\n'"appendonly yes"$'\n'"appendfsync everysec"
    printf '\n%s\n' "$block" >>"$conf"
    echo "Redis tuned (maxmemory ${max_mb} MB, append-only)."
}

app_redis_ready() {
    local url
    url="$(env_read_value REDIS_URL)"
    php_redis_ping "$(env_read_value REDIS_HOST)" "$(env_read_value REDIS_PORT)" "$(env_read_value REDIS_PASSWORD)" \
        "$(env_read_value REDIS_USERNAME)" "$url" && return 0
    [[ -n "$url" && "${url,,}" != null ]] && return 1
    if php_redis_ping 127.0.0.1 6379 "" "" ""; then
        env_write_value REDIS_HOST 127.0.0.1
        env_write_value REDIS_PORT 6379
        env_write_value REDIS_PASSWORD null
        return 0
    fi
    return 1
}

redis_install_prefix() { printf 'spartan_%s_' "$(printf '%s' "$APP_DIR" | sha1sum | cut -c1-10)"; }

configure_cache_queue_drivers() {
    if app_redis_ready; then
        [[ -n "$(env_read_value REDIS_PREFIX)" ]] || env_write_value REDIS_PREFIX "$(redis_install_prefix)"
        env_write_value REDIS_CLIENT phpredis
        env_write_value CACHE_STORE redis
        env_write_value QUEUE_CONNECTION redis
    else
        warn_add "Redis is not usable from PHP, so cache and queue use the database. Run the installer with --update once Redis works."
        env_write_value CACHE_STORE database
        env_write_value QUEUE_CONNECTION database
    fi
}

database_queue_job_count() {
    (cd "$APP_DIR" && php artisan tinker --execute='echo \Illuminate\Support\Facades\DB::table("jobs")->count();' 2>/dev/null | tr -dc '0-9') || true
}

switch_to_redis_drivers() {
    local cache queue move_cache=0 move_queue=0
    cache="$(env_read_value CACHE_STORE)"
    queue="$(env_read_value QUEUE_CONNECTION)"
    [[ -z "$cache" || "$cache" == database || "$cache" == file ]] && move_cache=1
    [[ -z "$queue" || "$queue" == database ]] && move_queue=1
    ((move_cache || move_queue)) || return 0
    if ! app_redis_ready; then
        warn_add "Redis is not usable from PHP, so cache and queue stay on the database."
        return 0
    fi
    if [[ "$cache" != redis && "$queue" != redis && -z "$(env_read_value REDIS_PREFIX)" ]]; then
        env_write_value REDIS_PREFIX "$(redis_install_prefix)"
    fi
    [[ -n "$(env_read_value REDIS_CLIENT)" ]] || env_write_value REDIS_CLIENT phpredis
    ((move_cache)) && env_write_value CACHE_STORE redis
    ((move_queue)) || return 0
    if [[ "$queue" == database ]]; then
        (cd "$APP_DIR" && timeout 600 php artisan queue:work database --queue=critical,high,medium,default,low \
            --stop-when-empty --force --tries=3 --timeout=120) || true
        local remaining
        remaining="$(database_queue_job_count)"
        if [[ -n "$remaining" && "$remaining" != 0 ]]; then
            warn_add "${remaining} delayed job(s) are still in the database queue, so the queue stays on the database until the next update."
            return 0
        fi
    fi
    env_write_value QUEUE_CONNECTION redis
}
