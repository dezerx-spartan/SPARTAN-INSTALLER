php_minor() { php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "$PHP_VER"; }

php_pick_apt_version() {
    [[ -n "$(apt_candidate "php${PHP_VER}-fpm")" ]] && return 0

    local v best_ok="" best_any=""
    for v in $(apt-cache pkgnames php 2>/dev/null | sed -nE 's/^php([0-9]+\.[0-9]+)-fpm$/\1/p' | sort -uV); do
        [[ -n "$(apt_candidate "php${v}-fpm")" ]] || continue
        version_ge "$v" "$PHP_MIN_VER" || continue
        best_any="$v"
        version_ge "$PHP_IONCUBE_MAX" "$v" && best_ok="$v"
    done
    local pick="${best_ok:-$best_any}"
    if [[ -z "$pick" ]]; then
        phase_fail "No PHP ${PHP_MIN_VER}+ packages are available for ${DISTRO_NAME}."
        return 1
    fi
    warn_add "PHP ${PHP_VER} is not packaged for ${DISTRO_NAME}; installed PHP ${pick} instead."
    PHP_VER="$pick"
}

php_enable_repo() {
    case "$OS_BASE" in
        debian)
            if [[ "$(apt_repo_state "$SURY_PHP_URL")" == "missing" ]]; then
                echo "packages.sury.org has no PHP repository for Debian ${PKG_CODENAME} yet; using Debian's PHP."
            else
                pkg_install curl ca-certificates gnupg lsb-release || return 1
                if ! dpkg-query -W -f='${Status}' debsuryorg-archive-keyring 2>/dev/null | grep -q 'install ok installed'; then
                    work_dir sury || return 1
                    local deb="${REPLY}/debsuryorg-archive-keyring.deb"
                    curl -fsSL --retry 3 -o "$deb" https://packages.sury.org/debsuryorg-archive-keyring.deb || return 1
                    dpkg -i "$deb" || return 1
                fi
                if ! grep -qs "^deb .*packages.sury.org/php/ ${PKG_CODENAME}" /etc/apt/sources.list.d/php.list; then
                    echo "deb [signed-by=/usr/share/keyrings/debsuryorg-archive-keyring.gpg] https://packages.sury.org/php/ ${PKG_CODENAME} main" \
                        >/etc/apt/sources.list.d/php.list
                fi
            fi
            apt_get update || return 1
            php_pick_apt_version
            ;;
        ubuntu)
            if [[ "$(apt_repo_state "$PHP_PPA_URL")" == "missing" ]]; then
                echo "The ondrej/php PPA has no packages for ${PKG_CODENAME} yet; using Ubuntu's PHP."
            else
                pkg_install software-properties-common curl ca-certificates gnupg lsb-release || return 1
                if ! apt_source_has "ondrej/php"; then
                    LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php || return 1
                fi
            fi
            apt_get update || return 1
            php_pick_apt_version
            ;;
        el)
            el_enable_epel_remi || return 1
            if dnf module list php >/dev/null 2>&1; then
                dnf -y module reset php || true
                if dnf module list php 2>/dev/null | grep -q "remi-${PHP_VER}"; then
                    dnf -y module enable "php:remi-${PHP_VER}" || return 1
                else
                    warn_add "PHP ${PHP_VER} is not offered by the Remi repository; using the newest PHP available."
                fi
            fi
            ;;
        fedora)
            pkg_install dnf-plugins-core || true
            if dnf module list php >/dev/null 2>&1; then
                local module="php"
                if ! dnf module list php 2>/dev/null | grep -q "remi-${PHP_VER}"; then
                    pkg_install "https://rpms.remirepo.net/fedora/remi-release-$(rpm -E %fedora).rpm" || true
                fi
                dnf module list php 2>/dev/null | grep -q "remi-${PHP_VER}" && module="php:remi-${PHP_VER}"
                dnf -y module reset php || true
                [[ "$module" != php ]] && { dnf -y module enable "$module" || true; }
            fi
            ;;
    esac
}

el_enable_epel_remi() {
    pkg_install dnf-plugins-core || true
    if [[ "$DISTRO_ID" == rhel ]]; then
        have subscription-manager && subscription-manager repos --enable "codeready-builder-for-rhel-${OS_EL_MAJOR}-$(uname -m)-rpms" >/dev/null 2>&1
    elif have crb; then
        crb enable >/dev/null 2>&1 || true
    else
        dnf config-manager --set-enabled crb >/dev/null 2>&1 || dnf config-manager --set-enabled powertools >/dev/null 2>&1 || true
    fi
    if ! pkg_installed epel-release; then
        pkg_install epel-release ||
            pkg_install "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${OS_EL_MAJOR}.noarch.rpm" || return 1
    fi
    if ! pkg_installed remi-release; then
        pkg_install "https://rpms.remirepo.net/enterprise/remi-release-${OS_EL_MAJOR}.rpm" || return 1
    fi
    return 0
}

php_packages_apt() {
    local v="$PHP_VER" p
    PHP_PKGS=("php${v}" "php${v}-cli" "php${v}-fpm" "php${v}-gd" "php${v}-mysql" "php${v}-mbstring"
        "php${v}-bcmath" "php${v}-xml" "php${v}-curl" "php${v}-zip" "php${v}-intl")
    [[ -n "$(apt_candidate "php${v}-opcache")" ]] && PHP_PKGS+=("php${v}-opcache")
    db_is_pg && PHP_PKGS+=("php${v}-pgsql")
    PHP_EXTRA_PKGS=()
    for p in sockets redis imap; do
        [[ -n "$(apt_candidate "php${v}-${p}")" ]] && PHP_EXTRA_PKGS+=("php${v}-${p}")
    done
}

php_install_packages() {
    if is_debian_family; then
        php_packages_apt
        pkg_install_lean "${PHP_PKGS[@]}" || return 1
        local p
        for p in "${PHP_EXTRA_PKGS[@]}"; do
            pkg_install_lean "$p" || echo "Optional package ${p} could not be installed."
        done
        if [[ -x "/usr/bin/php${PHP_VER}" ]] && have update-alternatives; then
            update-alternatives --set php "/usr/bin/php${PHP_VER}" >/dev/null 2>&1 || true
        fi
    else
        pkg_install php php-cli php-fpm php-gd php-mysqlnd php-mbstring php-bcmath php-xml \
            php-curl php-zip php-intl php-opcache || pkg_install php php-cli php-fpm php-gd php-mysqlnd \
            php-mbstring php-bcmath php-xml php-intl php-opcache || return 1
        pkg_install php-sockets php-process || pkg_install php-process || true
        pkg_install php-redis || pkg_install php-pecl-redis6 || pkg_install php-pecl-redis5 || true
        pkg_install php-imap || pkg_install php-pecl-imap || true
        if db_is_pg; then
            pkg_install php-pgsql || return 1
        fi
    fi
    have php || { phase_fail "PHP was installed but the php command is missing."; return 1; }
    local got
    got="$(php_minor)"
    echo "PHP CLI version: $(php -v 2>/dev/null | head -n1)"
    if ! version_ge "$got" "$PHP_MIN_VER"; then
        phase_fail "PHP ${got} is installed, but DezerX Spartan needs PHP ${PHP_MIN_VER} or newer."
        return 1
    fi
    PHP_VER="$got"
}

php_octane_requirements() {
    local missing=() ext
    for ext in sockets posix pcntl; do
        php -r "exit(extension_loaded('${ext}') ? 0 : 1);" 2>/dev/null || missing+=("$ext")
    done
    if ((${#missing[@]})); then
        warn_add "PHP is missing ${missing[*]} (needed by RoadRunner), so Octane is skipped and the site runs on PHP-FPM."
        OCTANE_ENABLED=0
        return 1
    fi
    echo "PHP CLI has the extensions RoadRunner needs (sockets, posix, pcntl)."
    return 0
}

php_redis_available() { php -r 'exit(class_exists("Redis") ? 0 : 1);' 2>/dev/null; }

php_fpm_service() {
    local s
    s="php${PHP_VER}-fpm"
    svc_exists "$s" && { echo "$s"; return; }
    systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '/^php.*-fpm\.service/ { print $1 }' | sort -rV | head -n1 | sed 's/\.service$//'
}

php_fpm_start() {
    local svc
    svc="$(php_fpm_service)"
    [[ -n "$svc" ]] || svc="php-fpm"
    systemctl enable --now "$svc"
}

php_fpm_restart() {
    local svc
    svc="$(php_fpm_service)"
    [[ -n "$svc" ]] || svc="php-fpm"
    systemctl restart "$svc"
}

php_fpm_socket() {
    local s
    shopt -s nullglob
    for s in "/run/php/php$(php_minor)-fpm.sock" /run/php/php*-fpm.sock /var/run/php/php*-fpm.sock \
        /run/php/php-fpm.sock /var/run/php/php-fpm.sock /run/php-fpm/www.sock; do
        if [[ -S "$s" ]]; then
            shopt -u nullglob
            echo "unix:$s"
            return 0
        fi
    done
    shopt -u nullglob
    if is_debian_family; then echo "unix:/run/php/php$(php_minor)-fpm.sock"; else echo "unix:/run/php-fpm/www.sock"; fi
}

php_fpm_pool_conf() {
    local c
    if is_debian_family; then
        for c in "/etc/php/$(php_minor)/fpm/pool.d/www.conf" /etc/php/*/fpm/pool.d/www.conf; do
            [[ -f "$c" ]] && { echo "$c"; return 0; }
        done
    else
        [[ -f /etc/php-fpm.d/www.conf ]] && { echo /etc/php-fpm.d/www.conf; return 0; }
    fi
    return 1
}

config_php_fpm() {
    local cfg
    cfg="$(php_fpm_pool_conf)" || { echo "No PHP-FPM pool configuration found."; return 0; }
    sed -Ei \
        -e "s|^[[:space:]]*;?[[:space:]]*user[[:space:]]*=.*|user = ${APP_USER}|" \
        -e "s|^[[:space:]]*;?[[:space:]]*group[[:space:]]*=.*|group = ${APP_GROUP}|" \
        -e "s|^[[:space:]]*;?[[:space:]]*listen\.owner[[:space:]]*=.*|listen.owner = ${APP_USER}|" \
        -e "s|^[[:space:]]*;?[[:space:]]*listen\.group[[:space:]]*=.*|listen.group = ${APP_GROUP}|" \
        "$cfg" || return 1
    echo "PHP-FPM pool ${cfg} runs as ${APP_USER}:${APP_GROUP}."
    php_fpm_restart
}

php_conf_dirs() {
    local -a dirs=()
    if is_debian_family; then
        shopt -s nullglob
        dirs+=(/etc/php/"$(php_minor)"/*/conf.d)
        ((${#dirs[@]})) || dirs+=(/etc/php/*/*/conf.d)
        shopt -u nullglob
    else
        dirs+=(/etc/php.d)
    fi
    local d
    for d in "${dirs[@]}"; do [[ -d "$d" ]] && echo "$d"; done
    return 0
}

config_opcache() {
    local wrote=0 dir enable_cli memory
    while read -r dir; do
        [[ -n "$dir" ]] || continue
        enable_cli=1
        memory=256
        if [[ "$dir" == */cli/conf.d ]]; then
            enable_cli=0
            memory=192
        fi
        cat >"${dir}/10-opcache-custom.ini" <<EOF || continue
opcache.enable=1
opcache.enable_cli=${enable_cli}
opcache.memory_consumption=${memory}
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=20000
opcache.validate_timestamps=0
opcache.revalidate_freq=2
opcache.save_comments=1
EOF
        echo "Wrote ${dir}/10-opcache-custom.ini"
        wrote=1
    done < <(php_conf_dirs)
    ((wrote)) || warn_add "No PHP conf.d directory was found, so OPcache was not tuned."
    config_opcache_file_cache
}

config_opcache_file_cache() {
    local user="${APP_USER:-$APP_USER_DEFAULT}" group="${APP_GROUP:-$APP_GROUP_DEFAULT}"
    mkdir -p "$PHP_OCTANE_INI_DIR" "$PHP_CRON_INI_DIR" "$OPCACHE_FILE_CACHE_DIR" "$OPCACHE_CRON_FILE_CACHE_DIR" || return 1
    find "$OPCACHE_FILE_CACHE_DIR" "$OPCACHE_CRON_FILE_CACHE_DIR" -mindepth 1 -delete 2>/dev/null
    chown "${user}:${group}" "$OPCACHE_FILE_CACHE_DIR" && chmod 0750 "$OPCACHE_FILE_CACHE_DIR"
    chown root:root "$OPCACHE_CRON_FILE_CACHE_DIR" && chmod 0700 "$OPCACHE_CRON_FILE_CACHE_DIR"
    local pair ini_dir cache_dir
    for pair in "${PHP_OCTANE_INI_DIR}|${OPCACHE_FILE_CACHE_DIR}" "${PHP_CRON_INI_DIR}|${OPCACHE_CRON_FILE_CACHE_DIR}"; do
        ini_dir="${pair%%|*}"
        cache_dir="${pair##*|}"
        cat >"${ini_dir}/90-dezerx-opcache.ini" <<EOF
opcache.enable=1
opcache.enable_cli=1
opcache.memory_consumption=192
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=20000
opcache.validate_timestamps=1
opcache.revalidate_freq=2
opcache.save_comments=1
opcache.file_cache=${cache_dir}
EOF
    done
    echo "OPcache file cache configured."
}

install_php_stack() {
    php_enable_repo || return 1
    php_install_packages || return 1
    php_octane_requirements || true
    return 0
}
