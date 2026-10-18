RELEASE_DIR=""
RELEASE_SRC=""
RELEASE_VERSION=""

find_7z_bin() {
    local b
    for b in 7zz 7z 7za 7zr; do
        have "$b" && { SEVENZIP_BIN="$b"; return 0; }
    done
    return 1
}

ensure_7z() {
    find_7z_bin && return 0
    if is_debian_family; then
        pkg_install_any p7zip-full 7zip p7zip || true
    else
        pkg_install_any p7zip 7zip p7zip-plugins || true
    fi
    find_7z_bin
}

release_fetch() {
    work_dir release || return 1
    RELEASE_DIR="$REPLY"
    mkdir -p "${RELEASE_DIR}/download" "${RELEASE_DIR}/extract"
    (cd "${RELEASE_DIR}/download" && curl -fL -OJ --retry 3 --connect-timeout 20 --progress-bar "$DL_URL") || {
        echo "The download failed."
        return 1
    }
}

release_extract() {
    local file kind
    file="$(find "${RELEASE_DIR}/download" -maxdepth 1 -type f -print -quit)"
    [[ -n "$file" ]] || { echo "Nothing was downloaded."; return 1; }
    kind="$(file -b "$file")"
    case "$kind" in
        7-zip* | 7-Zip*) kind="7z" ;;
        Zip* | zip*) kind="zip" ;;
        gzip* | *tar\ archive* | POSIX\ tar*) kind="tar" ;;
        *)
            case "${file,,}" in
                *.7z) kind="7z" ;;
                *.zip) kind="zip" ;;
                *.tar.gz | *.tgz | *.tar) kind="tar" ;;
                *) echo "Unknown archive type: ${kind}"; return 1 ;;
            esac
            ;;
    esac
    echo "Extracting $(basename "$file") (${kind}, $(fmt_bytes "$(stat -c %s "$file")"))"
    case "$kind" in
        7z)
            ensure_7z || { echo "7-Zip is needed to unpack this release but could not be installed."; return 1; }
            "$SEVENZIP_BIN" x -y -o"${RELEASE_DIR}/extract" "$file" >/dev/null || return 1
            ;;
        zip) unzip -q -o "$file" -d "${RELEASE_DIR}/extract" || return 1 ;;
        tar) tar -xf "$file" -C "${RELEASE_DIR}/extract" || return 1 ;;
    esac
    rm -f "$file"

    RELEASE_SRC=""
    if [[ -f "${RELEASE_DIR}/extract/artisan" ]]; then
        RELEASE_SRC="${RELEASE_DIR}/extract"
    else
        local a
        a="$(find "${RELEASE_DIR}/extract" -mindepth 2 -maxdepth 2 -type f -name artisan -not -path '*/__MACOSX/*' -print -quit)"
        [[ -n "$a" ]] && RELEASE_SRC="$(dirname "$a")"
    fi
    if [[ -z "$RELEASE_SRC" || ! -f "${RELEASE_SRC}/composer.json" ]]; then
        phase_fail "The downloaded archive does not contain a DezerX Spartan release (no artisan/composer.json)."
        return 1
    fi
    RELEASE_VERSION="$(app_version_of "$RELEASE_SRC")"
    echo "Release ${RELEASE_VERSION:-unknown} unpacked."
}

release_deploy() {
    rsync -aI --remove-source-files "${RELEASE_SRC}/" "${APP_DIR}/" || return 1
    [[ -f "${APP_DIR}/composer.json" ]] || { phase_fail "composer.json is missing after deploying the release."; return 1; }
    echo "Release deployed to ${APP_DIR}."
}

download_release() {
    task "Verifying your license" license_verify || {
        phase_fail "License check failed: ${LICENSE_MSG}"
        return 1
    }
    task "Requesting a download link" license_request_download || return 1
    task "Downloading DezerX Spartan${AVAILABLE_VERSION:+ ${AVAILABLE_VERSION}}" release_fetch || return 1
    task "Unpacking the release" release_extract || return 1
}
