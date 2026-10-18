have() { command -v "$1" >/dev/null 2>&1; }

is_true() {
    case "${1,,}" in
        1 | true | yes | y | on | enable | enabled) return 0 ;;
    esac
    return 1
}

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

now() { printf '%(%s)T' -1; }

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

fmt_duration() {
    local s="${1:-0}"
    if ((s < 60)); then
        printf '%ds' "$s"
    elif ((s < 3600)); then
        printf '%dm %02ds' $((s / 60)) $((s % 60))
    else
        printf '%dh %02dm' $((s / 3600)) $((s % 3600 / 60))
    fi
}

fmt_bytes() {
    awk -v b="${1:-0}" 'BEGIN {
        split("B KB MB GB TB", u, " "); i = 1
        while (b >= 1024 && i < 5) { b /= 1024; i++ }
        if (i == 1) printf "%d %s", b, u[i]; else printf "%.1f %s", b, u[i]
    }'
}

version_ge() {
    [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

version_gt() { [[ "$1" != "$2" ]] && version_ge "$1" "$2"; }

version_minor() {
    local v="$1"
    [[ "$v" =~ ^([0-9]+)\.([0-9]+) ]] && printf '%s.%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

random_password() {
    local p=""
    if have openssl; then
        p="$(openssl rand -hex 16 2>/dev/null)"
    fi
    if [[ -z "$p" ]]; then
        p="$(head -c 64 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 32)"
    fi
    printf '%s' "$p"
}

domain_normalize() {
    local d
    d="$(trim "$1")"
    d="${d,,}"
    d="${d#http://}"
    d="${d#https://}"
    d="${d%%/*}"
    d="${d%%\?*}"
    d="${d%%#*}"
    d="${d%%:*}"
    d="${d%.}"
    printf '%s' "$d"
}

domain_is_ip() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

domain_valid() {
    local d="$1"
    ((${#d} >= 1 && ${#d} <= 253)) || return 1
    domain_is_ip "$d" && return 0
    [[ "$d" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+([a-z][a-z0-9-]{0,61}[a-z0-9]|xn--[a-z0-9-]{1,59})$ ]]
}

db_ident_valid() { [[ "$1" =~ ^[A-Za-z0-9_]{1,64}$ ]]; }

port_valid() { is_uint "$1" && (($1 >= 1 && $1 <= 65535)); }

email_valid() { [[ "$1" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; }

path_is_protected() {
    local p="$1"
    [[ -n "$p" ]] || return 0
    [[ "$p" == /* ]] || return 0
    if have realpath; then
        p="$(realpath -m -- "$p" 2>/dev/null || printf '%s' "$p")"
    fi
    while [[ "$p" == */ && "$p" != "/" ]]; do p="${p%/}"; done
    case "$p" in
        / | /bin | /boot | /dev | /etc | /home | /lib | /lib32 | /lib64 | /libx32 | /media | /mnt | /opt | \
            /proc | /root | /run | /sbin | /srv | /sys | /tmp | /usr | /var | /var/www | /var/lib | /var/log | \
            /var/cache | /var/tmp | /var/backups | /var/spool | /var/mail | /var/opt | /var/run | /snap)
            return 0
            ;;
        /bin/* | /boot/* | /dev/* | /etc/* | /lib/* | /lib32/* | /lib64/* | /proc/* | /run/* | /sbin/* | /sys/* | /usr/* | /var/lib/* | /var/log/* | /snap/*)
            return 0
            ;;
    esac
    [[ "$p" =~ ^/home/[^/]+$ ]] && return 0
    local slashes="${p//[^\/]/}"
    ((${#slashes} >= 2)) || return 0
    return 1
}

safe_rm_rf() {
    local p
    for p in "$@"; do
        [[ -n "$p" ]] || continue
        if path_is_protected "$p"; then
            log "Refusing to remove protected path: ${p}"
            return 1
        fi
        rm -rf -- "$p"
    done
}

dir_is_empty() {
    [[ -d "$1" ]] || return 0
    [[ -z "$(find "$1" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]
}

mem_total_mb() { awk '/^MemTotal:/ { printf "%d", $2 / 1024 }' /proc/meminfo 2>/dev/null || echo 1024; }
swap_total_mb() { awk '/^SwapTotal:/ { printf "%d", $2 / 1024 }' /proc/meminfo 2>/dev/null || echo 0; }

free_mb() {
    local p="$1"
    while [[ ! -e "$p" && "$p" != "/" ]]; do p="$(dirname "$p")"; done
    df -Pm -- "$p" 2>/dev/null | awk 'NR == 2 { print $4 }'
}

dir_size_mb() {
    local d="$1"
    shift
    [[ -d "$d" ]] || { echo 0; return; }
    du -sm "$@" -- "$d" 2>/dev/null | awk '{ print $1 }' | tail -n1
}

in_container() {
    systemd-detect-virt -q --container 2>/dev/null && return 0
    grep -qa 'container=' /proc/1/environ 2>/dev/null
}

cleanup_add() { CLEANUP_PATHS+=("$@"); }

cleanup_run() {
    local p
    for p in "${CLEANUP_PATHS[@]}"; do
        [[ -n "$p" && -e "$p" ]] || continue
        case "$p" in
            "$WORK_BASE"/spartan-* | /tmp/spartan-* | "${APP_DIR}"/.cleanup.* | "${APP_DIR}"/.spartan-*) rm -rf -- "$p" ;;
            *) rm -f -- "$p" 2>/dev/null ;;
        esac
    done
    CLEANUP_PATHS=()
}

work_dir() {
    REPLY="$(mktemp -d "${WORK_BASE}/spartan-${1:-work}.XXXXXX")" || return 1
    chmod 700 "$REPLY"
    cleanup_add "$REPLY"
}

json_get() {
    local file="$1" path="$2"
    [[ -s "$file" ]] || return 1
    if have jq; then
        jq -r "(${path}) // empty | if type == \"boolean\" or type == \"number\" then tostring else . end" "$file" 2>/dev/null
        return 0
    fi
    if have python3; then
        python3 -I -c '
import json, sys
try:
    v = json.load(open(sys.argv[1]))
    for k in [p for p in sys.argv[2].split(".") if p]:
        v = v.get(k) if isinstance(v, dict) else None
    if v is None: sys.exit(0)
    print(str(v).lower() if isinstance(v, bool) else v)
except Exception:
    sys.exit(0)
' "$file" "$path" 2>/dev/null
        return 0
    fi
    if have php; then
        php -r '
$v = json_decode((string) @file_get_contents($argv[1]), true);
foreach (array_filter(explode(".", $argv[2]), "strlen") as $k) { $v = is_array($v) && array_key_exists($k, $v) ? $v[$k] : null; }
if ($v === null) exit(0);
echo is_bool($v) ? ($v ? "true" : "false") : (is_scalar($v) ? $v : json_encode($v)), "\n";
' "$file" "$path" 2>/dev/null
        return 0
    fi
    local key="${path##*.}" raw
    raw="$(tr -d '\n' <"$file" | grep -oE "\"${key}\"[[:space:]]*:[[:space:]]*(\"([^\"\\\\]|\\\\.)*\"|true|false|null|-?[0-9.]+)" | head -n1)"
    raw="${raw#*:}"
    raw="$(trim "$raw")"
    [[ "$raw" == "null" ]] && return 0
    if [[ "$raw" == \"*\" ]]; then
        raw="${raw:1:${#raw}-2}"
        raw="${raw//\\\//\/}"
        raw="${raw//\\\"/\"}"
        raw="${raw//\\\\/\\}"
    fi
    printf '%s\n' "$raw"
}

warn_add() {
    WARNINGS+=("$1")
    log "WARNING: $1"
    PHASE_WARNED=1
    ((${PLAN_RUNNING:-0})) && [[ "$UI_MODE" != tui ]] && ui_task_note "$1"
    return 0
}

note_add() {
    NOTES+=("$1")
    log "NOTE: $1"
}
