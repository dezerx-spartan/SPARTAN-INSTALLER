node_major() { node -v 2>/dev/null | sed -nE 's/^v([0-9]+).*/\1/p'; }

nodesource_setup() {
    work_dir nodesource || return 1
    local script="${REPLY}/setup.sh"
    if is_debian_family; then
        curl -fsSL --retry 3 https://deb.nodesource.com/setup_lts.x -o "$script" || return 1
    else
        curl -fsSL --retry 3 https://rpm.nodesource.com/setup_lts.x -o "$script" || return 1
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
    task "Installing pnpm ${PNPM_MAJOR}" install_pnpm || {
        phase_fail "pnpm could not be installed; the frontend build needs it."
        return 1
    }
    say "Node.js $(node -v), pnpm $(pnpm -v 2>/dev/null)"
}

install_pnpm() {
    local cur
    cur="$(pnpm -v 2>/dev/null || true)"
    if [[ "${cur%%.*}" == "$PNPM_MAJOR" ]]; then
        echo "pnpm ${cur} is installed."
        return 0
    fi
    npm install -g --force "pnpm@${PNPM_MAJOR}" --no-audit --no-fund || return 1
    hash -r
    have pnpm || return 1
    echo "pnpm $(pnpm -v)"
}
