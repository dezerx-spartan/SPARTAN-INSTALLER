# shellcheck shell=bash
# Operating system detection and the support matrix.
#
# OS_FAMILY  debian | rhel | fedora | unsupported
# OS_BASE    ubuntu | debian | el | fedora   (what repositories are built for)
# PKG_CODENAME  release codename used for apt repositories (Mint & co. map to Ubuntu)

OS_BASE=""
OS_EL_MAJOR=""
PKG_CODENAME=""

os_detect() {
    local id="unknown" ver="" code="" name="Linux" like="" ubuntu_code=""
    if [[ -r /etc/os-release ]]; then
        # Read in a subshell: os-release defines VERSION, NAME, ID, ... which
        # would otherwise overwrite the installer's own variables.
        IFS=$'\t' read -r id ver code name like ubuntu_code < <(
            # shellcheck source=/dev/null
            . /etc/os-release
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${ID:-unknown}" "${VERSION_ID:-}" "${VERSION_CODENAME:-}" \
                "${PRETTY_NAME:-${NAME:-Linux}}" "${ID_LIKE:-}" "${UBUNTU_CODENAME:-}"
        )
    fi
    DISTRO_ID="${id,,}"
    DISTRO_VER="$ver"
    DISTRO_CODENAME="${code:-$ubuntu_code}"
    DISTRO_NAME="$name"
    DISTRO_LIKE="${like,,}"
    if [[ -z "$DISTRO_CODENAME" ]] && have lsb_release; then
        DISTRO_CODENAME="$(lsb_release -sc 2>/dev/null || true)"
    fi
    PKG_CODENAME="$DISTRO_CODENAME"

    case "$DISTRO_ID" in
        ubuntu) OS_FAMILY="debian" OS_BASE="ubuntu" ;;
        debian) OS_FAMILY="debian" OS_BASE="debian" ;;
        rhel | centos | almalinux | rocky | ol | oracle | eurolinux | navy | cloudlinux) OS_FAMILY="rhel" OS_BASE="el" ;;
        fedora) OS_FAMILY="fedora" OS_BASE="fedora" ;;
        *)
            case " ${DISTRO_LIKE} " in
                *" ubuntu "*)
                    OS_FAMILY="debian" OS_BASE="ubuntu"
                    [[ -n "$ubuntu_code" ]] && PKG_CODENAME="$ubuntu_code"
                    ;;
                *" debian "*) OS_FAMILY="debian" OS_BASE="debian" ;;
                *" rhel "* | *" centos "*) OS_FAMILY="rhel" OS_BASE="el" ;;
                *" fedora "*) OS_FAMILY="rhel" OS_BASE="el" ;;
                *) OS_FAMILY="unsupported" OS_BASE="" ;;
            esac
            ;;
    esac

    if [[ "$OS_FAMILY" == rhel ]]; then
        OS_EL_MAJOR="${DISTRO_VER%%.*}"
        if have rpm; then
            local m
            m="$(rpm -E %rhel 2>/dev/null)"
            [[ "$m" =~ ^[0-9]+$ ]] && OS_EL_MAJOR="$m"
        fi
    fi

    ARCH="$(uname -m)"
    os_support_check
    log "OS: ${DISTRO_NAME} (id=${DISTRO_ID} version=${DISTRO_VER} codename=${DISTRO_CODENAME:-none} family=${OS_FAMILY} arch=${ARCH}) support=${OS_SUPPORT}"
}

# Sets OS_SUPPORT (supported | untested | unsupported) and OS_SUPPORT_NOTE.
os_support_check() {
    OS_SUPPORT="supported"
    OS_SUPPORT_NOTE=""
    local major="${DISTRO_VER%%.*}"
    case "$DISTRO_ID" in
        ubuntu)
            case "$DISTRO_VER" in
                22.04 | 24.04 | 26.04) ;;
                *) OS_SUPPORT="untested" OS_SUPPORT_NOTE="Ubuntu ${DISTRO_VER} is not an LTS release we test on (22.04, 24.04 and 26.04 are)." ;;
            esac
            ;;
        debian)
            case "$major" in
                12 | 13) ;;
                *) OS_SUPPORT="untested" OS_SUPPORT_NOTE="Debian ${DISTRO_VER} is not tested (12 and 13 are)." ;;
            esac
            ;;
        rhel | almalinux | rocky | ol | centos)
            case "$OS_EL_MAJOR" in
                8 | 9) ;;
                *) OS_SUPPORT="untested" OS_SUPPORT_NOTE="${DISTRO_NAME} is not tested (EL 8 and 9 are)." ;;
            esac
            ;;
        fedora) OS_SUPPORT="untested" OS_SUPPORT_NOTE="Fedora works on a best-effort basis." ;;
        *)
            if [[ "$OS_FAMILY" != unsupported ]]; then
                OS_SUPPORT="untested"
                OS_SUPPORT_NOTE="${DISTRO_NAME} is treated as ${OS_BASE}; it is not tested."
            else
                OS_SUPPORT="unsupported"
                OS_SUPPORT_NOTE="${DISTRO_NAME} is not supported. Use Ubuntu, Debian, AlmaLinux, Rocky Linux or RHEL."
            fi
            ;;
    esac
    case "$ARCH" in
        x86_64 | aarch64 | arm64) ;;
        *)
            OS_SUPPORT="unsupported"
            OS_SUPPORT_NOTE="The ${ARCH} architecture is not supported (ionCube ships loaders for x86_64 and aarch64 only)."
            ;;
    esac
}

is_debian_family() { [[ "$OS_FAMILY" == debian ]]; }
is_rpm_family() { [[ "$OS_FAMILY" == rhel || "$OS_FAMILY" == fedora ]]; }

os_pretty() { printf '%s (%s)' "$DISTRO_NAME" "$ARCH"; }
