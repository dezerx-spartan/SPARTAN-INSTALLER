APT_OPTS=(-y -q -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

pkg_env() {
    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_MODE=a
    export NEEDRESTART_SUSPEND=1
    export APT_LISTCHANGES_FRONTEND=none
    export UCF_FORCE_CONFFOLD=1
}

apt_get() {
    pkg_env
    apt-get "${APT_OPTS[@]}" "$@"
}

dnf_cmd() {
    if have dnf; then
        dnf -y "$@"
    else
        yum -y "$@"
    fi
}

apt_candidate() {
    LC_ALL=C apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ && $2 != "(none)" { print $2; exit }'
}

pkg_installed() {
    if is_debian_family; then
        dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
    else
        rpm -q "$1" >/dev/null 2>&1
    fi
}

pkg_available() {
    if is_debian_family; then
        [[ -n "$(apt_candidate "$1")" ]]
    else
        dnf_cmd -q list "$1" >/dev/null 2>&1
    fi
}

pkg_refresh() {
    if is_debian_family; then
        apt_drop_unpublished_sources
        apt_get update
    else
        dnf_cmd makecache
    fi
}

pkg_upgrade() {
    if is_debian_family; then
        apt_get upgrade
    elif have dnf; then
        dnf -y upgrade --refresh || dnf -y distro-sync
    else
        yum -y upgrade
    fi
}

pkg_install() {
    (($#)) || return 0
    if is_debian_family; then
        apt_get install "$@"
    elif have dnf; then
        dnf -y --setopt=install_weak_deps=False install "$@"
    else
        yum -y install "$@"
    fi
}

pkg_install_lean() {
    (($#)) || return 0
    if is_debian_family; then
        apt_get install --no-install-recommends "$@"
    else
        pkg_install "$@"
    fi
}

pkg_install_any() {
    local p
    for p in "$@"; do
        pkg_install "$p" && return 0
    done
    return 1
}

apt_drop_unpublished_sources() {
    is_debian_family || return 0
    [[ -n "$PKG_CODENAME" ]] || return 0
    local f url
    for f in /etc/apt/sources.list.d/ondrej-ubuntu-php-*.list /etc/apt/sources.list.d/ondrej-ubuntu-php-*.sources \
        /etc/apt/sources.list.d/php.list /etc/apt/sources.list.d/nginx.list; do
        [[ -f "$f" ]] || continue
        grep -qsw -- "$PKG_CODENAME" "$f" || continue
        url=""
        case "$f" in
            */ondrej-ubuntu-php-*) url="$PHP_PPA_URL" ;;
            */php.list) grep -qs "packages.sury.org/php" "$f" && url="$SURY_PHP_URL" ;;
            */nginx.list) url="$(grep -oE 'https?://nginx\.org/packages/[^[:space:]]+' "$f" | head -n1 || true)" ;;
        esac
        [[ -n "$url" ]] || continue
        if [[ "$(apt_repo_state "$url")" == "missing" ]]; then
            echo "Removing $(basename "$f"): the repository has no ${PKG_CODENAME} release"
            rm -f "$f"
        fi
    done
}

apt_repo_state() {
    local code
    [[ -n "$PKG_CODENAME" ]] || { echo "unknown"; return 0; }
    code="$(curl -sL -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 30 "${1%/}/dists/${PKG_CODENAME}/Release" 2>/dev/null || true)"
    case "$code" in
        200) echo "published" ;;
        404 | 410) echo "missing" ;;
        *) echo "unknown" ;;
    esac
}

apt_source_has() {
    local marker="$1" f
    for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
        [[ -f "$f" ]] || continue
        if grep -qs -- "$marker" "$f" && grep -qsw -- "$PKG_CODENAME" "$f"; then
            return 0
        fi
    done
    return 1
}

essentials_missing() {
    local -a want=()
    if is_debian_family; then
        have curl || want+=(curl)
        have jq || want+=(jq)
        have unzip || want+=(unzip)
        have rsync || want+=(rsync)
        have file || want+=(file)
        have openssl || want+=(openssl)
        have gpg || want+=(gnupg)
        have ps || want+=(procps)
        have crontab || want+=(cron)
        have diff || want+=(diffutils)
        have ss || want+=(iproute2)
        have lsb_release || want+=(lsb-release)
        have tar || want+=(tar)
        have gzip || want+=(gzip)
        [[ -d /etc/ssl/certs ]] && pkg_installed ca-certificates || want+=(ca-certificates)
    else
        have curl || want+=(curl)
        have jq || want+=(jq)
        have unzip || want+=(unzip)
        have rsync || want+=(rsync)
        have file || want+=(file)
        have openssl || want+=(openssl)
        have gpg || want+=(gnupg2)
        have ps || want+=(procps-ng)
        have crontab || want+=(cronie)
        have diff || want+=(diffutils)
        have ss || want+=(iproute)
        have tar || want+=(tar)
        have gzip || want+=(gzip)
        pkg_installed ca-certificates || want+=(ca-certificates)
    fi
    printf '%s\n' "${want[@]}"
}

install_essentials() {
    local -a pkgs
    mapfile -t pkgs < <(essentials_missing)
    ((${#pkgs[@]})) || { echo "All required tools are present."; return 0; }
    pkg_install "${pkgs[@]}"
}

pkg_remove() {
    (($#)) || return 0
    if is_debian_family; then
        apt_get remove "$@"
    elif have dnf; then
        dnf -y remove "$@"
    else
        yum -y remove "$@"
    fi
}
