# shellcheck shell=bash
# Node.js LTS from NodeSource (the frontend build needs a current Node).
# When NodeSource has nothing for this distribution yet, the distribution's own
# Node.js is used if it is new enough.

node_major() { node -v 2>/dev/null | sed -nE 's/^v([0-9]+).*/\1/p'; }

nodesource_setup() {
    work_dir nodesource || return 1
    local script="${REPLY}/setup.sh"
    if is_debian_family; then
        curl -fsSL --retry 3 https://deb.nodesource.com/setup_lts.x -o "$script" || return 1
    else
        curl -fsSL --retry 3 https://rpm.nodesource.com/setup_lts.x -o "$script" || return 1
        # The distribution's nodejs module would shadow NodeSource's packages.
        if have dnf && dnf module list nodejs 2>/dev/null | grep -qi '^nodejs'; then
            dnf -y module reset nodejs || true
            dnf -y module disable nodejs || true
        fi
    fi
    bash "$script"
}

install_nodejs() {
    if task "Adding the NodeSource LTS repository" nodesource_setup; then
        task "Installing Node.js" pkg_install nodejs || return 1
    else
        warn_add "NodeSource has no packages for ${DISTRO_NAME}; using the distribution's Node.js."
        task "Installing Node.js (distribution package)" pkg_install nodejs || return 1
    fi
    have npm || task "Installing npm" pkg_install npm || true
    local major
    major="$(node_major)"
    if [[ -z "$major" ]] || ((major < NODE_MIN_MAJOR)); then
        phase_fail "Node.js ${major:-is missing}; the frontend build needs Node.js ${NODE_MIN_MAJOR} or newer."
        return 1
    fi
    say "Node.js $(node -v), npm $(npm -v 2>/dev/null)"
}
