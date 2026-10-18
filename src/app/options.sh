opts_file() { printf '%s/%s' "$APP_DIR" "$OPTIONS_JSON_NAME"; }

opts_valid() { [[ -f "$(opts_file)" ]] && jq -e . "$(opts_file)" >/dev/null 2>&1; }

opts_ensure() {
    local f
    f="$(opts_file)"
    [[ -f "$f" ]] && return 0
    cat >"$f" <<'EOF'
{
    "keep": {
        "nginx": false,
        "css": true,
        "themes": true,
        "portals": true,
        "emails": true,
        "favicon": true
    },
    "exclude": {
        "files": [],
        "folders": []
    },
    "delete": []
}
EOF
    echo "Created ${f}"
}

opts_load_keep() {
    have jq || return 0
    opts_valid || return 0
    local key val
    while IFS='=' read -r key val; do
        key="${key^^}"
        case "$key" in NGINX | CSS | THEMES | PORTALS | EMAILS | FAVICON) ;; *) continue ;; esac
        [[ -n "${KEEP_FROM_CLI[$key]:-}" ]] && continue
        case "$val" in
            true) printf -v "KEEP_${key}" '%s' 1 ;;
            false) printf -v "KEEP_${key}" '%s' 0 ;;
        esac
    done < <(jq -r '.keep? // {} | to_entries[] | "\(.key)=\(.value)"' "$(opts_file)" 2>/dev/null)
    log "Keep flags: nginx=${KEEP_NGINX} css=${KEEP_CSS} themes=${KEEP_THEMES} portals=${KEEP_PORTALS} emails=${KEEP_EMAILS} favicon=${KEEP_FAVICON}"
}

opts_save_keep() {
    have jq || return 0
    opts_ensure
    opts_valid || return 0
    local f tmp
    f="$(opts_file)"
    tmp="${f}.tmp.$$"
    jq --argjson n "$KEEP_NGINX" --argjson c "$KEEP_CSS" --argjson t "$KEEP_THEMES" \
        --argjson p "$KEEP_PORTALS" --argjson e "$KEEP_EMAILS" --argjson fv "$KEEP_FAVICON" \
        '.keep = ((.keep // {}) + {nginx: ($n == 1), css: ($c == 1), themes: ($t == 1), portals: ($p == 1), emails: ($e == 1), favicon: ($fv == 1)})' \
        "$f" >"$tmp" && cat "$tmp" >"$f"
    rm -f "$tmp"
}

opts_clean_path() {
    local p
    p="$(trim "$1")"
    p="${p#"$APP_DIR"}"
    while [[ "$p" == /* ]]; do p="${p#/}"; done
    while [[ "$p" == */ ]]; do p="${p%/}"; done
    case "/${p}/" in
        // | /./ | */../* | */./*) p="" ;;
    esac
    printf '%s' "$p"
}

opts_stage_exclusions() {
    have jq || return 0
    opts_valid || return 0
    work_dir exclude || return 1
    EXCLUDE_TMPDIR="$REPLY"
    cp -a "$(opts_file)" "${EXCLUDE_TMPDIR}/${OPTIONS_JSON_NAME}"
    local item rel n=0
    while IFS= read -r item; do
        rel="$(opts_clean_path "$item")"
        [[ -n "$rel" && -e "${APP_DIR}/${rel}" ]] || continue
        mkdir -p "${EXCLUDE_TMPDIR}/$(dirname "$rel")"
        cp -a "${APP_DIR}/${rel}" "${EXCLUDE_TMPDIR}/${rel}" && n=$((n + 1))
        echo "Keeping ${rel}"
    done < <(jq -r '(.exclude.files // [])[], (.exclude.folders // [])[]' "$(opts_file)" 2>/dev/null)
    echo "${n} excluded item(s) set aside."
}

opts_restore_exclusions() {
    [[ -n "$EXCLUDE_TMPDIR" && -d "$EXCLUDE_TMPDIR" ]] || return 0
    rsync -a "${EXCLUDE_TMPDIR}/" "${APP_DIR}/" || return 1
    echo "Excluded items restored."
}

opts_apply_deletions() {
    have jq || return 0
    opts_valid || return 0
    local item rel
    while IFS= read -r item; do
        rel="$(opts_clean_path "$item")"
        [[ -n "$rel" ]] || continue
        if [[ -e "${APP_DIR}/${rel}" || -L "${APP_DIR}/${rel}" ]]; then
            rm -rf -- "${APP_DIR:?}/${rel}"
            echo "Deleted ${rel}"
        fi
    done < <(jq -r '(.delete // [])[]' "$(opts_file)" 2>/dev/null)
    return 0
}
