# shellcheck shell=bash
# Read-only checks shown on the welcome screen. Nothing here changes the system.

declare -a PRE_STATE=() PRE_LABEL=() PRE_DETAIL=()
PRE_BLOCKER=""
INTERNET_OK=""

_pre_add() {
    PRE_STATE+=("$1")
    PRE_LABEL+=("$2")
    PRE_DETAIL+=("$3")
    [[ "$1" == fail && -z "$PRE_BLOCKER" ]] && PRE_BLOCKER="$2: $3"
    return 0
}

# port_owner <port> - name of the process listening on a TCP port (empty if free).
port_owner() {
    have ss || return 0
    ss -H -ltnp "( sport = :$1 )" 2>/dev/null | grep -oE 'users:\(\("[^"]+"' | head -n1 | sed -E 's/users:\(\("//; s/"$//'
}

port_is_free() {
    local port="$1"
    if have ss; then
        ! ss -H -ltn 2>/dev/null | awk '{ print $4 }' | grep -qE "[:.]${port}\$"
    elif have netstat; then
        ! netstat -ltn 2>/dev/null | awk '{ print $4 }' | grep -qE "[:.]${port}\$"
    else
        ! (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null
    fi
}

detect_resources() {
    CPU_CORES="$(nproc 2>/dev/null || echo 1)"
    [[ "$CPU_CORES" =~ ^[0-9]+$ ]] || CPU_CORES=1
    ((CPU_CORES < 1)) && CPU_CORES=1
    MEM_TOTAL_MB="$(mem_total_mb)"
    [[ "$MEM_TOTAL_MB" =~ ^[0-9]+$ ]] || MEM_TOTAL_MB=1024
    ((MEM_TOTAL_MB < 256)) && MEM_TOTAL_MB=256
    return 0
}

internet_check() {
    INTERNET_OK=0
    have curl || return 1
    local url
    for url in https://github.com https://market.dezerx.com; do
        if curl -sS -o /dev/null -m 8 --connect-timeout 5 "$url" 2>/dev/null; then
            INTERNET_OK=1
            return 0
        fi
    done
    return 1
}

preflight_run() {
    PRE_STATE=() PRE_LABEL=() PRE_DETAIL=()
    PRE_BLOCKER=""
    detect_resources

    case "$OS_SUPPORT" in
        supported) _pre_add ok "System" "$(os_pretty)" ;;
        untested) _pre_add warn "System" "$(os_pretty) - ${OS_SUPPORT_NOTE}" ;;
        *) _pre_add fail "System" "${OS_SUPPORT_NOTE:-$(os_pretty) is not supported}" ;;
    esac

    if is_systemd; then
        _pre_add ok "Services" "systemd"
    else
        _pre_add fail "Services" "systemd is required (containers without systemd are not supported)"
    fi

    local mem_gb
    mem_gb="$(awk -v m="$MEM_TOTAL_MB" 'BEGIN { printf "%.1f", m / 1024 }')"
    if ((MEM_TOTAL_MB < 1500)); then
        _pre_add warn "Resources" "${CPU_CORES} CPU, ${mem_gb} GB RAM - very little memory; a swap file will be added"
    elif ((MEM_TOTAL_MB <= 2048)); then
        _pre_add warn "Resources" "${CPU_CORES} CPU, ${mem_gb} GB RAM - a 2 GB swap file will be added"
    else
        _pre_add ok "Resources" "${CPU_CORES} CPU, ${mem_gb} GB RAM"
    fi

    local free
    free="$(free_mb "${APP_DIR:-/var/www}")"
    [[ "$free" =~ ^[0-9]+$ ]] || free=0
    local free_gb
    free_gb="$(awk -v m="$free" 'BEGIN { printf "%.1f", m / 1024 }')"
    if ((free < 3072)); then
        _pre_add fail "Disk" "${free_gb} GB free - at least 3 GB is needed (8 GB recommended)"
    elif ((free < 8192)); then
        _pre_add warn "Disk" "${free_gb} GB free - 8 GB or more is recommended"
    else
        _pre_add ok "Disk" "${free_gb} GB free"
    fi

    if internet_check; then
        _pre_add ok "Network" "github.com and market.dezerx.com reachable"
    elif have curl; then
        _pre_add fail "Network" "cannot reach github.com or market.dezerx.com"
    else
        _pre_add warn "Network" "curl is not installed yet; checked during installation"
    fi

    local p80
    p80="$(port_owner 80)"
    case "$p80" in
        "" | nginx) ;;
        apache2 | httpd) _pre_add warn "Port 80" "used by Apache, which will be stopped and disabled for Nginx" ;;
        *) _pre_add warn "Port 80" "used by ${p80}; Nginx needs this port" ;;
    esac
    return 0
}

# preflight_summary - tagged text for the welcome screen.
preflight_summary() {
    local i out="" icon
    for i in "${!PRE_STATE[@]}"; do
        case "${PRE_STATE[i]}" in
            ok) icon=" " ;;
            warn) icon="{w}${G_WARN}{/}" ;;
            *) icon="{e}${G_FAIL}{/}" ;;
        esac
        printf -v out '%s  %s {d}%-10s{/} %s\n' "$out" "$icon" "${PRE_LABEL[i]}" "$(tx "${PRE_DETAIL[i]}")"
    done
    printf '%s' "${out%$'\n'}"
}
