# shellcheck shell=bash
# Updating in place: the user's data and customisations are moved aside, the
# old version is removed, the new release is deployed and everything is put
# back. Same rules as 1.x:
#   - storage/, public/, .env and modules_statuses.json always survive
#   - Modules, client themes: user-added ones are restored, ones that ship with
#     the new release keep the new version
#   - CSS, portals, e-mail templates, favicon: kept when selected
# Moving (not copying) keeps this fast even with gigabytes in storage/.

preserve_begin() {
    update_tmpdir="$(mktemp -d "${APP_DIR}/.cleanup.XXXXXX")" || return 1
    chmod 700 "$update_tmpdir"
    css_save_methode=""
}

# _mv_into <source> <target dir> - moves a path if it exists.
_mv_into() {
    [[ -e "$1" || -L "$1" ]] || return 0
    mkdir -p "$2" && mv -- "$1" "$2/"
}

preserve_css() {
    ((KEEP_CSS)) || return 0
    if php "${APP_DIR}/artisan" help theme:backup --no-interaction >/dev/null 2>&1 &&
        (cd "$APP_DIR" && php artisan theme:backup --save --no-interaction); then
        css_save_methode="php"
        echo "Dashboard colours saved with theme:backup."
    else
        css_save_methode="fallback"
        _mv_into "${APP_DIR}/resources/css" "$update_tmpdir"
        echo "Dashboard CSS set aside (fallback)."
    fi
}

preserve_themes() {
    ((KEEP_THEMES)) || return 0
    local src="${APP_DIR}/resources/js/pages/themes" d n=0
    [[ -d "$src" ]] || { echo "No client themes directory."; return 0; }
    mkdir -p "${update_tmpdir}/Themes"
    for d in "$src"/*/; do
        d="${d%/}"
        [[ -d "$d" ]] || continue
        [[ "$(basename "$d")" == default ]] && continue
        mv -- "$d" "${update_tmpdir}/Themes/" && n=$((n + 1))
    done
    echo "${n} client theme(s) set aside."
}

preserve_portals() {
    ((KEEP_PORTALS)) || return 0
    local src="${APP_DIR}/resources/js/pages/Portal" d n=0
    [[ -d "$src" ]] || { echo "No portal directory."; return 0; }
    mkdir -p "${update_tmpdir}/Portals"
    for d in "$src"/*/; do
        d="${d%/}"
        [[ -d "$d" ]] || continue
        [[ "$(basename "${d,,}")" == default ]] && continue
        mv -- "$d" "${update_tmpdir}/Portals/" && n=$((n + 1))
    done
    echo "${n} portal(s) set aside."
}

preserve_emails() {
    ((KEEP_EMAILS)) || return 0
    _mv_into "${APP_DIR}/resources/views/emails" "$update_tmpdir"
    echo "E-mail templates set aside."
}

preserve_favicon() {
    ((KEEP_FAVICON)) || return 0
    mkdir -p "${update_tmpdir}/favicon"
    local f
    for f in favicon.ico favicon.svg; do
        [[ -f "${APP_DIR}/public/${f}" ]] && cp -a "${APP_DIR}/public/${f}" "${update_tmpdir}/favicon/"
    done
    return 0
}

preserve_core() {
    local p
    for p in storage public Modules modules_statuses.json .env; do
        _mv_into "${APP_DIR}/${p}" "$update_tmpdir" || return 1
    done
    echo "storage, public, Modules, modules_statuses.json and .env set aside."
}

# Removes everything in the application directory except the staging folder.
app_dir_cleanup() {
    path_is_protected "$APP_DIR" && { phase_fail "Refusing to clean ${APP_DIR}."; return 1; }
    local e n=0
    shopt -s dotglob nullglob
    for e in "${APP_DIR}"/*; do
        [[ "$e" == "$update_tmpdir" ]] && continue
        rm -rf -- "$e"
        n=$((n + 1))
    done
    shopt -u dotglob nullglob
    echo "Removed ${n} entries of the previous version."
}

restore_core() {
    local p
    for p in storage public; do
        [[ -e "${update_tmpdir}/${p}" ]] && mv -- "${update_tmpdir}/${p}" "${APP_DIR}/"
    done
    [[ -f "${update_tmpdir}/modules_statuses.json" ]] && mv -- "${update_tmpdir}/modules_statuses.json" "${APP_DIR}/modules_statuses.json.old"
    return 0
}

restore_portals_emails() {
    if ((KEEP_PORTALS)) && [[ -d "${update_tmpdir}/Portals" ]]; then
        mkdir -p "${APP_DIR}/resources/js/pages/Portal"
        rsync -aI "${update_tmpdir}/Portals/" "${APP_DIR}/resources/js/pages/Portal/" && rm -rf -- "${update_tmpdir}/Portals"
        echo "Portals restored."
    fi
    if ((KEEP_EMAILS)) && [[ -d "${update_tmpdir}/emails" ]]; then
        mkdir -p "${APP_DIR}/resources/views/emails"
        rsync -aI "${update_tmpdir}/emails/" "${APP_DIR}/resources/views/emails/" && rm -rf -- "${update_tmpdir}/emails"
        echo "E-mail templates restored."
    fi
    return 0
}

# User modules that the new release does not ship are put back, sorted into
# their category folder by name suffix (Gateway/Service/Provider/Addon).
restore_modules() {
    local saved="${update_tmpdir}/Modules" dest="${APP_DIR}/Modules"
    [[ -d "$saved" ]] || { echo "No saved modules."; return 0; }
    mkdir -p "$dest"
    local restored=0 skipped=0 modjson moddir name sub
    while IFS= read -r -d '' modjson; do
        moddir="$(dirname "$modjson")"
        name="$(basename "$moddir")"
        if [[ -n "$(find "$dest" -mindepth 1 -maxdepth 2 -type d -name "$name" -print -quit 2>/dev/null)" ]]; then
            skipped=$((skipped + 1))
            continue
        fi
        case "$name" in
            *Gateway) sub="Gateways" ;;
            *Service) sub="Services" ;;
            *Provider) sub="Providers" ;;
            *) sub="Addons" ;;
        esac
        mkdir -p "${dest}/${sub}"
        rsync -aI "${moddir}/" "${dest}/${sub}/${name}/"
        echo "Kept custom module ${name} -> Modules/${sub}/"
        restored=$((restored + 1))
    done < <(find "$saved" -mindepth 1 -name module.json -print0 2>/dev/null)
    echo "Custom modules kept: ${restored}, shipped with the release: ${skipped}"
    rm -rf -- "$saved"
}

# Client themes: same rule as modules. Runs before the frontend build because
# Vite only bundles the themes it can see.
restore_themes() {
    local saved="${update_tmpdir}/Themes" dest="${APP_DIR}/resources/js/pages/themes"
    [[ -d "$saved" ]] || { echo "No saved client themes."; return 0; }
    mkdir -p "$dest"
    local restored=0 skipped=0 d name
    for d in "$saved"/*/; do
        d="${d%/}"
        [[ -d "$d" ]] || continue
        name="$(basename "$d")"
        if [[ "$name" == default || -d "${dest}/${name}" ]]; then
            skipped=$((skipped + 1))
            continue
        fi
        rsync -aI "${d}/" "${dest}/${name}/"
        echo "Kept custom theme ${name}"
        restored=$((restored + 1))
    done
    echo "Custom themes kept: ${restored}, shipped with the release: ${skipped}"
    rm -rf -- "$saved"
}

restore_files() {
    [[ -f "${update_tmpdir}/.env" ]] && mv -f -- "${update_tmpdir}/.env" "${APP_DIR}/.env"
    if ((KEEP_FAVICON)) && [[ -d "${update_tmpdir}/favicon" ]]; then
        mkdir -p "${APP_DIR}/public"
        cp -a "${update_tmpdir}/favicon/." "${APP_DIR}/public/" 2>/dev/null
    fi
    if ((KEEP_CSS)) && [[ "$css_save_methode" == fallback && -d "${update_tmpdir}/css" ]]; then
        mkdir -p "${APP_DIR}/resources/css"
        rsync -aI "${update_tmpdir}/css/" "${APP_DIR}/resources/css/"
    fi
    return 0
}

# modules_statuses.json: the user's on/off choices win, new modules get the
# release default.
merge_module_statuses() {
    local old="${APP_DIR}/modules_statuses.json.old" new="${APP_DIR}/modules_statuses.json"
    [[ -f "$old" ]] || return 0
    if [[ ! -f "$new" ]]; then
        mv -f -- "$old" "$new"
        return 0
    fi
    jq -s '.[0] as $old | .[1] as $new | (($old | keys) + ($new | keys) | unique) as $ks |
        reduce $ks[] as $k ({}; .[$k] = (if ($old | has($k)) then $old[$k] else $new[$k] end))' \
        "$old" "$new" >"${new}.tmp" || { rm -f "${new}.tmp"; return 1; }
    mv -f -- "${new}.tmp" "$new"
    rm -f -- "$old"
    echo "Module statuses merged."
}

preserve_finish() {
    [[ -n "$update_tmpdir" && -d "$update_tmpdir" ]] || return 0
    if [[ -n "$(find "$update_tmpdir" -mindepth 1 -print -quit)" ]]; then
        log "Leftovers in ${update_tmpdir}: $(find "$update_tmpdir" -mindepth 1 -maxdepth 2 | head -n 20 | tr '\n' ' ')"
    fi
    rm -rf -- "$update_tmpdir"
    update_tmpdir=""
}
