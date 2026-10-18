redis_cli_bin() {
    if have valkey-cli; then echo valkey-cli; elif have redis-cli; then echo redis-cli; fi
}

redis_conf_path() {
    local c
    for c in /etc/valkey/valkey.conf /etc/redis/redis.conf /etc/redis.conf; do
        [[ -f "$c" ]] && { echo "$c"; return 0; }
    done
}

redis_server_conf_path() {
    local c
    for c in /etc/redis/redis.conf /etc/redis.conf; do
        [[ -f "$c" ]] && { echo "$c"; return 0; }
    done
}

kv_conf_pass() {
    local conf="${1:-$(redis_conf_path)}"
    [[ -n "$conf" && -f "$conf" ]] || return 0
    awk '$1 == "requirepass" { v = $2; gsub(/^"|"$/, "", v); print v; exit }' "$conf" 2>/dev/null
}

kv_cli() {
    local cli pass
    cli="$(redis_cli_bin)"
    [[ -n "$cli" ]] || return 1
    pass="$(kv_conf_pass)"
    if [[ -n "$pass" ]]; then
        REDISCLI_AUTH="$pass" VALKEYCLI_AUTH="$pass" "$cli" -h 127.0.0.1 -p 6379 "$@"
    else
        "$cli" -h 127.0.0.1 -p 6379 "$@"
    fi
}

kv_key_count() {
    kv_cli info keyspace 2>/dev/null | sed -nE 's/^db[0-9]+:keys=([0-9]+).*/\1/p' | awk '{ s += $1 } END { print s + 0 }'
}

redis_is_up() {
    local cli out
    cli="$(redis_cli_bin)"
    if [[ -n "$cli" ]]; then
        out="$("$cli" -h 127.0.0.1 -p 6379 ping 2>&1)"
        [[ "$out" == PONG || "$out" == *NOAUTH* ]]
    else
        php -r 'exit(@fsockopen("127.0.0.1", 6379) ? 0 : 1);' >/dev/null 2>&1
    fi
}

kv_wait_up() {
    local i
    for i in $(seq 1 15); do
        redis_is_up && return 0
        sleep 1
    done
    return 1
}

kv_server_kind() {
    local info
    info="$(kv_cli info server 2>/dev/null)" || true
    if [[ "$info" == *server_name:valkey* || "$info" == *valkey_version:* ]]; then
        echo valkey
    elif [[ "$info" == *redis_version:* ]]; then
        echo redis
    fi
}

valkey_service_name() {
    local s
    for s in valkey-server valkey; do
        svc_exists "$s" && { echo "$s"; return 0; }
    done
    if is_debian_family; then echo valkey-server; else echo valkey; fi
}

redis_server_service_name() {
    local s
    for s in redis-server redis; do
        svc_exists "$s" && { echo "$s"; return 0; }
    done
    echo redis-server
}

redis_service_name() {
    if have valkey-server; then valkey_service_name; else redis_server_service_name; fi
}

kv_name() { if have valkey-server; then echo Valkey; else echo Redis; fi; }

kv_target_name() {
    if [[ "$OS_BASE" == ubuntu ]]; then
        case "$PKG_CODENAME" in
            bionic | focal | jammy) echo Redis; return 0 ;;
        esac
    fi
    echo Valkey
}

valkey_pkg() { if is_debian_family; then echo valkey-server; else echo valkey; fi; }

valkey_backports_enable() {
    [[ "$OS_BASE" == debian && -n "$PKG_CODENAME" ]] || return 1
    apt_source_has "${PKG_CODENAME}-backports" && return 1
    echo "Adding ${PKG_CODENAME}-backports for Valkey"
    echo "deb http://deb.debian.org/debian ${PKG_CODENAME}-backports main" >/etc/apt/sources.list.d/debian-backports.list
    apt_get update
}

valkey_available() {
    have valkey-server && return 0
    pkg_available "$(valkey_pkg)" && return 0
    valkey_backports_enable && pkg_available "$(valkey_pkg)"
}

valkey_install_pkg() {
    local p
    p="$(valkey_pkg)"
    pkg_install "$p" && return 0
    is_debian_family && [[ -n "$PKG_CODENAME" ]] && apt_get install -t "${PKG_CODENAME}-backports" "$p"
}

queue_workers_stop() {
    systemctl stop 'dezerx-queue@*.service' dezerx.service >/dev/null 2>&1
    return 0
}

retire_redis_server() {
    svc_stop_disable "$1"
    if is_debian_family; then
        pkg_installed redis-server && pkg_remove redis-server
    else
        pkg_installed redis && pkg_remove redis
    fi
    return 0
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

app_redis_is_local() {
    local url host port
    url="$(env_read_value REDIS_URL)"
    host="$(env_read_value REDIS_HOST)"
    port="$(env_read_value REDIS_PORT)"
    [[ -z "$url" || "${url,,}" == null ]] || return 1
    case "${host,,}" in "" | null | 127.0.0.1 | localhost | ::1) ;; *) return 1 ;; esac
    case "${port,,}" in "" | null | 6379) ;; *) return 1 ;; esac
}

install_valkey() {
    local kind=""
    redis_is_up && kind="$(kv_server_kind)"
    if [[ "$kind" == valkey ]]; then
        echo "Valkey is running."
        return 0
    fi
    if [[ -f "${APP_DIR}/.env" ]] && ! app_redis_is_local && app_uses_working_redis; then
        echo "Spartan uses an external Redis server; leaving it as it is."
        return 0
    fi
    if ! valkey_available; then
        echo "Valkey is not packaged for ${DISTRO_NAME}; using Redis."
        install_redis_server
        return 0
    fi
    if [[ "$kind" == redis ]]; then
        migrate_redis_to_valkey
        return 0
    fi
    if redis_is_up; then
        echo "Another server answers on 127.0.0.1:6379; leaving it as it is."
        return 0
    fi
    local installed_now=0
    if ! have valkey-server; then
        have redis-server && retire_redis_server "$(redis_server_service_name)"
        if ! valkey_install_pkg || ! have valkey-server; then
            warn_add "Valkey could not be installed; Spartan keeps using the database for cache and queue."
            return 0
        fi
        installed_now=1
    fi
    start_service "$(valkey_service_name)" || true
    if ! kv_wait_up; then
        warn_add "Valkey does not answer on 127.0.0.1:6379; Spartan keeps using the database for cache and queue."
        return 0
    fi
    ((installed_now)) && config_redis
    return 0
}

kv_copy_keys_php() {
    have php && php_redis_available || return 1
    php -r '
        [, $sport, $tpass] = $argv;
        $s = new Redis();
        $t = new Redis();
        if (!$s->connect("127.0.0.1", (int) $sport, 5) || !$t->connect("127.0.0.1", 6379, 5)) { exit(1); }
        if ($tpass !== "" && !$t->auth($tpass)) { exit(1); }
        $s->setOption(Redis::OPT_SCAN, Redis::SCAN_RETRY);
        $n = 0;
        foreach ($s->info("keyspace") as $db => $unused) {
            if (!preg_match("/^db(\d+)$/", $db, $m)) { continue; }
            $s->select((int) $m[1]);
            $t->select((int) $m[1]);
            $it = null;
            while (($keys = $s->scan($it, "*", 1000)) !== false) {
                foreach ($keys as $k) {
                    $ttl = $s->pttl($k);
                    switch ($s->type($k)) {
                        case Redis::REDIS_STRING:
                            $t->set($k, $s->get($k));
                            break;
                        case Redis::REDIS_LIST:
                            $t->del($k);
                            $v = $s->lRange($k, 0, -1);
                            if ($v) { $t->rPush($k, ...$v); }
                            break;
                        case Redis::REDIS_SET:
                            $t->del($k);
                            $v = $s->sMembers($k);
                            if ($v) { $t->sAdd($k, ...$v); }
                            break;
                        case Redis::REDIS_ZSET:
                            $t->del($k);
                            foreach ($s->zRange($k, 0, -1, true) as $member => $score) { $t->zAdd($k, $score, (string) $member); }
                            break;
                        case Redis::REDIS_HASH:
                            $t->del($k);
                            $v = $s->hGetAll($k);
                            if ($v) { $t->hMSet($k, $v); }
                            break;
                        default:
                            continue 2;
                    }
                    if ($ttl > 0) { $t->pExpire($k, $ttl); }
                    $n++;
                }
                if ($it === 0) { break; }
            }
        }
        echo $n, "\n";
    ' "$1" "$(kv_conf_pass)"
}

kv_copy_from_snapshot() {
    local rdb="$1" dir cli rc=1 i n
    have redis-server && [[ -f "$rdb" ]] || return 1
    cli="$(redis_cli_bin)"
    dir="$(dirname "$rdb")/spartan-migrate"
    rm -rf "$dir"
    mkdir -p "$dir" && cp -f "$rdb" "${dir}/dump.rdb" || return 1
    chown -R --reference="$(dirname "$rdb")" "$dir"
    local -a run=()
    id redis >/dev/null 2>&1 && run=(runuser -u redis --)
    "${run[@]}" redis-server --port 6390 --bind 127.0.0.1 --dir "$dir" --dbfilename dump.rdb --save '' \
        --appendonly no --daemonize yes --pidfile "${dir}/redis.pid" --logfile "${dir}/redis.log" || { rm -rf "$dir"; return 1; }
    for i in $(seq 1 30); do
        [[ "$("$cli" -h 127.0.0.1 -p 6390 ping 2>/dev/null)" == PONG ]] && break
        sleep 1
    done
    if n="$(kv_copy_keys_php 6390)"; then
        echo "Copied ${n} key(s) from the Redis snapshot into Valkey."
        rc=0
    fi
    "$cli" -h 127.0.0.1 -p 6390 shutdown nosave >/dev/null 2>&1 || true
    sleep 1
    rm -rf "$dir"
    return "$rc"
}

migrate_redis_to_valkey() {
    local rconf rsvc vsvc rdb="" keys=0 vdir vfile target copied=0
    rconf="$(redis_server_conf_path)"
    if [[ -n "$rconf" ]] && grep -qE '^[[:space:]]*(aclfile|user)[[:space:]]' "$rconf"; then
        warn_add "Redis uses ACL users, so it was not switched to Valkey."
        return 0
    fi
    rsvc="$(redis_server_service_name)"
    queue_workers_stop
    if [[ "$(kv_cli save 2>/dev/null)" == OK ]]; then
        rdb="$(kv_cli config get dir 2>/dev/null | tail -n 1)/$(kv_cli config get dbfilename 2>/dev/null | tail -n 1)"
        keys="$(kv_key_count)"
    fi
    echo "Redis holds ${keys} key(s); snapshot: ${rdb:-none}"
    svc_stop_disable "$rsvc"
    redis_is_up && { kv_cli shutdown >/dev/null 2>&1 || true; sleep 2; }
    if ! have valkey-server && { ! valkey_install_pkg || ! have valkey-server; }; then
        start_service "$rsvc" || true
        kv_wait_up || true
        warn_add "Valkey could not be installed, so Spartan keeps using Redis."
        return 0
    fi
    vsvc="$(valkey_service_name)"
    start_service "$vsvc" || true
    kv_wait_up || true
    vdir="$(kv_cli config get dir 2>/dev/null | tail -n 1)"
    vfile="$(kv_cli config get dbfilename 2>/dev/null | tail -n 1)"
    [[ "$vdir" == /* ]] || vdir=/var/lib/valkey
    [[ -n "$vfile" && "$vfile" != */* ]] || vfile=dump.rdb
    target="${vdir}/${vfile}"
    systemctl stop "$vsvc" >/dev/null 2>&1 || true
    if [[ -n "$rconf" && -f /etc/valkey/valkey.conf ]] && ! grep -qE '^[[:space:]]*requirepass[[:space:]]' /etc/valkey/valkey.conf; then
        local pass_line
        pass_line="$(grep -m1 -E '^[[:space:]]*requirepass[[:space:]]' "$rconf" || true)"
        [[ -n "$pass_line" ]] && printf '\n%s\n' "$pass_line" >>/etc/valkey/valkey.conf
    fi
    if [[ -f "$rdb" ]] && ((keys > 0)); then
        if cp -f "$rdb" "$target" && chown --reference="$vdir" "$target" && chmod 640 "$target"; then
            copied=1
            have restorecon && restorecon "$target" >/dev/null 2>&1
        fi
    fi
    systemctl reset-failed "$vsvc" >/dev/null 2>&1
    start_service "$vsvc" || true
    if ! kv_wait_up && ((copied)); then
        echo "Valkey cannot read this Redis snapshot format; copying the keys one by one."
        rm -f "$target"
        systemctl reset-failed "$vsvc" >/dev/null 2>&1
        start_service "$vsvc" || true
        kv_wait_up || true
        copied=0
        if redis_is_up && kv_copy_from_snapshot "$rdb"; then
            copied=1
        else
            warn_add "The Redis data could not be copied into Valkey, so the cache starts empty. The Redis snapshot is kept in ${rdb}."
        fi
    fi
    if ! redis_is_up; then
        svc_stop_disable "$vsvc"
        start_service "$rsvc" || true
        kv_wait_up || true
        warn_add "Valkey did not start, so Spartan keeps using Redis."
        return 0
    fi
    ((copied)) && echo "Valkey loaded $(kv_key_count) of ${keys} key(s) from Redis."
    retire_redis_server "$rsvc"
    config_redis
    echo "Switched from Redis to Valkey."
}

install_redis_server() {
    local installed_now=0
    if ! have redis-server; then
        if is_debian_family; then
            pkg_install redis-server || true
        else
            pkg_install redis || true
        fi
        have redis-server && installed_now=1
    fi
    if ! have redis-server; then
        warn_add "Redis could not be installed; Spartan keeps using the database for cache and queue."
        return 0
    fi
    start_service "$(redis_server_service_name)" || true
    if ! kv_wait_up; then
        warn_add "Redis does not answer on 127.0.0.1:6379; Spartan keeps using the database for cache and queue."
        return 0
    fi
    ((installed_now)) && config_redis
    return 0
}

config_redis() {
    local conf
    conf="$(redis_conf_path)"
    [[ -n "$(redis_cli_bin)" && -n "$conf" ]] || return 0
    grep -q "^# dezerx-spartan tuning" "$conf" 2>/dev/null && return 0
    [[ -n "$MEM_TOTAL_MB" ]] || detect_resources
    local max_mb=$((MEM_TOTAL_MB / 20))
    ((max_mb < 64)) && max_mb=64
    ((max_mb > 512)) && max_mb=512
    local block="# dezerx-spartan tuning" current_max
    current_max="$(kv_cli config get maxmemory 2>/dev/null | tail -n 1)"
    if [[ "$current_max" == 0 ]]; then
        kv_cli config set maxmemory "${max_mb}mb" >/dev/null &&
            kv_cli config set maxmemory-policy volatile-lru >/dev/null
        block+=$'\n'"maxmemory ${max_mb}mb"$'\n'"maxmemory-policy volatile-lru"
    fi
    if [[ "$(kv_cli config get appendonly 2>/dev/null | tail -n 1)" != yes ]]; then
        kv_cli config set appendonly yes >/dev/null
        local i
        for i in $(seq 1 30); do
            kv_cli info persistence 2>/dev/null | grep -q "aof_rewrite_in_progress:0" && break
            sleep 1
        done
    fi
    block+=$'\n'"appendonly yes"$'\n'"appendfsync everysec"
    printf '\n%s\n' "$block" >>"$conf"
    echo "$(kv_name) tuned (maxmemory ${max_mb} MB, append-only)."
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
        warn_add "$(kv_name) is not usable from PHP, so cache and queue use the database. Run the installer with --update once $(kv_name) works."
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
        warn_add "$(kv_name) is not usable from PHP, so cache and queue stay on the database."
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
