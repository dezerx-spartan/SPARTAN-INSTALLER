ioncube_installed_version() {
    php -r 'echo function_exists("ioncube_loader_version") ? ioncube_loader_version() : "0";' 2>/dev/null || echo 0
}

ioncube_fetch() {
    local url="$1" out="$2" host="downloads.ioncube.com" err pin
    curl -fsSL --connect-timeout 15 --retry 2 "$url" -o "$out" && return 0

    err="$(curl -sSL "$url" -o /dev/null 2>&1 || true)"
    if ! grep -qi "certificate has expired" <<<"$err"; then
        echo "ionCube download failed: ${err}"
        return 1
    fi
    echo "downloads.ioncube.com serves an expired certificate; retrying with its public key pinned."
    pin="$(echo | openssl s_client -connect "${host}:443" -servername "$host" 2>/dev/null |
        openssl x509 -pubkey -noout 2>/dev/null |
        openssl pkey -pubin -outform der 2>/dev/null |
        openssl dgst -sha256 -binary | openssl enc -base64)"
    [[ -n "$pin" ]] || { echo "Could not read the public key of ${host}."; return 1; }
    curl -fsSL --insecure --pinnedpubkey "sha256//${pin}" --connect-timeout 15 --retry 2 "$url" -o "$out" || return 1
    file -b "$out" | grep -Eqi 'gzip|tar' || { echo "The download is not a gzip archive."; return 1; }
}

ioncube_write_ini() {
    local phpv="$1"
    local so="${IONCUBE_DIR}/ioncube_loader_lin_${phpv}.so"
    local line="zend_extension=${so}"
    [[ -f "$so" ]] || return 0
    if [[ -d "/etc/php/${phpv}/cli/conf.d" ]]; then
        local sapi
        for sapi in cli fpm apache2; do
            [[ -d "/etc/php/${phpv}/${sapi}/conf.d" ]] && echo "$line" >"/etc/php/${phpv}/${sapi}/conf.d/00-ioncube.ini"
        done
    elif [[ -d /etc/php.d ]]; then
        echo "$line" >/etc/php.d/00-ioncube.ini
    fi
    return 0
}

install_ioncube() {
    local phpv arch url tmp tar so dst cur new
    phpv="$(php_minor)"
    cur="$(ioncube_installed_version)"
    case "$(uname -m)" in
        x86_64) arch="x86-64" ;;
        aarch64 | arm64) arch="aarch64" ;;
        *) phase_fail "ionCube has no loader for $(uname -m)."; return 1 ;;
    esac
    url="https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_${arch}.tar.gz"
    work_dir ioncube || return 1
    tmp="$REPLY"
    tar="${tmp}/ioncube.tar.gz"

    if ! task "Downloading the ionCube loader" ioncube_fetch "$url" "$tar"; then
        if [[ -n "$cur" && "$cur" != 0 ]]; then
            warn_add "Could not download the ionCube loader; keeping the installed loader ${cur}."
            ioncube_write_ini "$phpv"
            return 0
        fi
        phase_fail "The ionCube loader could not be downloaded and none is installed. Install ${IONCUBE_DIR}/ioncube_loader_lin_${phpv}.so manually and run the installer again."
        return 1
    fi
    tar -xzf "$tar" -C "$tmp" || { phase_fail "The ionCube archive could not be extracted."; return 1; }
    so="${tmp}/ioncube/ioncube_loader_lin_${phpv}.so"
    if [[ ! -f "$so" ]]; then
        phase_fail "ionCube does not provide a loader for PHP ${phpv} yet. Use PHP ${PHP_IONCUBE_MAX} or older."
        return 1
    fi
    new="$(php -n -d "zend_extension=${so}" -r 'echo function_exists("ioncube_loader_version") ? ioncube_loader_version() : "0";' 2>/dev/null)"
    dst="${IONCUBE_DIR}/ioncube_loader_lin_${phpv}.so"
    install -d "$IONCUBE_DIR"

    if [[ -z "$cur" || "$cur" == 0 ]]; then
        echo "Installing ionCube ${new}"
        install -m 0644 "$so" "$dst" || return 1
    elif [[ ! -f "$dst" ]] || version_gt "$new" "$cur"; then
        echo "Updating ionCube ${cur} -> ${new}"
        find /etc/php* -type f -name '*ioncube*.ini' -delete 2>/dev/null
        rm -f "${IONCUBE_DIR}"/ioncube_loader_lin_*.so
        install -m 0644 "$so" "$dst" || return 1
    else
        echo "ionCube ${cur} is up to date."
    fi
    ioncube_write_ini "$phpv"

    if [[ "$(ioncube_installed_version)" == 0 ]]; then
        phase_fail "The ionCube loader is installed but PHP does not load it."
        return 1
    fi
    echo "ionCube $(ioncube_installed_version) loaded."
}
