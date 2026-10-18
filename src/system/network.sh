IPV6_SYSCTL="/etc/sysctl.d/99-spartan-disable-ipv6.conf"

net_has_ipv4_route() { ip -4 route show default 2>/dev/null | grep -q .; }

net_ipv6_ssh_sessions() {
    have ss || return 1
    local ports
    ports="$(ss -Hltnp 2>/dev/null | awk '/sshd/ { n = split($4, a, ":"); print a[n] }' | sort -u)"
    [[ -n "$ports" ]] || ports=22
    local p
    for p in $ports; do
        ss -Htn state established "( sport = :${p} )" 2>/dev/null | awk '{ print $3 }' |
            grep -v '::ffff:' | grep -q '\[' && return 0
    done
    return 1
}

net_other_ipv6_listeners() {
    [[ -d /etc/nginx ]] || return 1
    grep -rlsE '^[[:space:]]*listen[[:space:]]+\[::' /etc/nginx 2>/dev/null |
        grep -vE "/(spartan|dezerx)(\.conf)?$|spartan-octane\.conf$" | grep -q .
}

license_curl_ip_opt() {
    if ((ENABLE_IPV6 == 0)) && net_has_ipv4_route; then
        printf '%s' "-4"
    fi
}

config_network() {
    if ((ENABLE_IPV6)); then
        if [[ -f "$IPV6_SYSCTL" ]]; then
            echo "Removing ${IPV6_SYSCTL} (IPv6 requested)."
            rm -f "$IPV6_SYSCTL"
            sysctl --system >/dev/null 2>&1 || true
        else
            echo "IPv6 stays enabled."
        fi
        return 0
    fi

    if [[ -f "$IPV6_SYSCTL" ]]; then
        echo "IPv6 is already disabled by ${IPV6_SYSCTL}."
        return 0
    fi
    if ! net_has_ipv4_route; then
        warn_add "This server has no IPv4 route, so IPv6 was left enabled."
        return 0
    fi
    if net_other_ipv6_listeners; then
        warn_add "Other Nginx sites listen on IPv6, so IPv6 was left enabled (use --ipv6 to silence this)."
        return 0
    fi

    printf '%s\n' "net.ipv6.conf.all.disable_ipv6 = 1" "net.ipv6.conf.default.disable_ipv6 = 1" \
        "net.ipv6.conf.lo.disable_ipv6 = 1" >"$IPV6_SYSCTL"
    if net_ipv6_ssh_sessions; then
        warn_add "IPv6 will be disabled after the next reboot (an SSH session uses IPv6, so it was not switched off now)."
        return 0
    fi
    sysctl -p "$IPV6_SYSCTL" || true
    echo "IPv6 disabled."
}

net_detect_public_ip() {
    [[ -n "$PUBLIC_IPV4" ]] && return 0
    have curl || return 1
    local url ip
    for url in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip; do
        ip="$(curl -4 -fsS -m 6 "$url" 2>/dev/null | tr -d '[:space:]')"
        if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            PUBLIC_IPV4="$ip"
            return 0
        fi
    done
    return 1
}

ip4_to_int() {
    local IFS=.
    local -a o
    read -ra o <<<"$1"
    echo $(((o[0] << 24) + (o[1] << 16) + (o[2] << 8) + o[3]))
}

ip4_in_cidr() {
    local ip net bits
    ip="$(ip4_to_int "$1")"
    net="$(ip4_to_int "${2%/*}")"
    bits="${2#*/}"
    local mask=$(((0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF))
    (((ip & mask) == (net & mask)))
}

ip4_is_cloudflare() {
    local c
    for c in 173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18 \
        190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 \
        104.24.0.0/14 172.64.0.0/13 131.0.72.0/22; do
        ip4_in_cidr "$1" "$c" && return 0
    done
    return 1
}

dns_check() {
    local domain="$1" ip
    DNS_RESOLVED=""
    DNS_STATUS="unknown"
    if domain_is_ip "$domain"; then
        DNS_STATUS="ip"
        return 0
    fi
    DNS_RESOLVED="$(getent ahostsv4 "$domain" 2>/dev/null | awk '{ print $1 }' | sort -u | tr '\n' ' ')"
    DNS_RESOLVED="${DNS_RESOLVED% }"
    if [[ -z "$DNS_RESOLVED" ]]; then
        DNS_STATUS="unresolved"
        return 0
    fi
    net_detect_public_ip
    if [[ -z "$PUBLIC_IPV4" ]]; then
        DNS_STATUS="unknown"
        return 0
    fi
    for ip in $DNS_RESOLVED; do
        [[ "$ip" == "$PUBLIC_IPV4" ]] && { DNS_STATUS="ok"; return 0; }
    done
    for ip in $DNS_RESOLVED; do
        ip4_is_cloudflare "$ip" && { DNS_STATUS="proxied"; return 0; }
    done
    for ip in $DNS_RESOLVED; do
        ip -4 addr show 2>/dev/null | grep -q "inet ${ip}/" && { DNS_STATUS="ok"; return 0; }
    done
    DNS_STATUS="mismatch"
    return 0
}

dns_status_text() {
    local d="$1"
    case "$DNS_STATUS" in
        ok) printf '%s points to this server (%s).' "$d" "${PUBLIC_IPV4:-$DNS_RESOLVED}" ;;
        proxied) printf '{w}%s{/} %s is proxied through Cloudflare (%s).' "$G_WARN" "$d" "$DNS_RESOLVED" ;;
        mismatch) printf '{w}%s{/} %s points to %s, but this server is %s.' "$G_WARN" "$d" "$DNS_RESOLVED" "$PUBLIC_IPV4" ;;
        unresolved) printf '{w}%s{/} %s does not resolve yet.' "$G_WARN" "$d" ;;
        ip) printf '{d}%s is an IP address; Let'"'"'s Encrypt needs a domain name.{/}' "$d" ;;
        *) printf '{d}Could not compare %s with this server'"'"'s public IP.{/}' "$d" ;;
    esac
}
