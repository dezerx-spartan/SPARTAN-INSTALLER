# shellcheck shell=bash
# Finds existing DezerX Spartan installations, so the update and tools screens
# can offer the right directory instead of asking the user to type it.

DETECTED_APP_DIR=""
DETECTED_DOMAIN=""
DETECTED_VERSION=""

app_looks_like_spartan() {
    local d="$1"
    [[ -n "$d" && -f "${d}/artisan" && -f "${d}/.env" ]] || return 1
    grep -qE '^LICENSE_KEY=' "${d}/.env" 2>/dev/null || [[ -f "${d}/version.json" ]]
}

app_version_of() {
    local d="$1" v=""
    [[ -f "${d}/version.json" ]] || return 0
    v="$(json_get "${d}/version.json" .version 2>/dev/null)"
    [[ -n "$v" ]] || v="$(sed -nE 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "${d}/version.json" | head -n1)"
    printf '%s' "$v"
}

app_domain_of() {
    local d="$1" url
    url="$(env_read_value APP_URL "${d}/.env")"
    url="${url#http://}"
    url="${url#https://}"
    printf '%s' "${url%%/*}"
}

# Candidate directories, most likely first.
app_detect_candidates() {
    local -a c=()
    ((USED_APP_DIR)) && c+=("$APP_DIR")
    local f d
    for f in "$OCTANE_SERVICE" "$QUEUE_TEMPLATE" "$LEGACY_QUEUE_SERVICE"; do
        [[ -f "$f" ]] || continue
        d="$(sed -nE 's/^WorkingDirectory=(.*)$/\1/p' "$f" | head -n1)"
        [[ -n "$d" ]] && c+=("$d")
    done
    c+=("$APP_DEFAULT_DIR")
    if have crontab; then
        while IFS= read -r d; do c+=("$d"); done < <(crontab -l 2>/dev/null | sed -nE 's/.*cd ([^ ]+) && .*artisan schedule:run.*/\1/p')
    fi
    for f in /etc/nginx/sites-available/spartan.conf /etc/nginx/conf.d/spartan.conf /etc/nginx/sites-available/dezerx.conf /etc/nginx/conf.d/dezerx.conf; do
        [[ -f "$f" ]] || continue
        d="$(sed -nE 's/^[[:space:]]*root[[:space:]]+([^;]+)\/public;.*/\1/p' "$f" | head -n1)"
        [[ -n "$d" ]] && c+=("$d")
    done
    local seen="|" x
    for x in "${c[@]}"; do
        x="${x%/}"
        [[ "$seen" == *"|${x}|"* ]] && continue
        seen+="${x}|"
        printf '%s\n' "$x"
    done
}

app_detect() {
    DETECTED_APP_DIR=""
    DETECTED_DOMAIN=""
    DETECTED_VERSION=""
    local d
    while IFS= read -r d; do
        if app_looks_like_spartan "$d"; then
            DETECTED_APP_DIR="$d"
            DETECTED_DOMAIN="$(app_domain_of "$d")"
            DETECTED_VERSION="$(app_version_of "$d")"
            log "Detected installation: ${d} (domain ${DETECTED_DOMAIN:-?}, version ${DETECTED_VERSION:-?})"
            return 0
        fi
    done < <(app_detect_candidates)
    return 1
}
