# shellcheck shell=bash
# Composer, verified against the checksum getcomposer.org publishes.

composer_bin() { command -v composer 2>/dev/null || echo /usr/local/bin/composer; }

install_composer() {
    if have composer; then
        echo "Composer is installed: $(command -v composer)"
        return 0
    fi
    work_dir composer || return 1
    local d="$REPLY"
    curl -fsSL --retry 3 -o "${d}/composer.phar" https://getcomposer.org/download/latest-stable/composer.phar || return 1
    local want got
    want="$(curl -fsSL --retry 3 https://getcomposer.org/download/latest-stable/composer.phar.sha256 2>/dev/null | awk '{ print $1 }')"
    got="$(sha256sum "${d}/composer.phar" | awk '{ print $1 }')"
    if [[ -n "$want" && "$want" != "$got" ]]; then
        echo "Composer checksum mismatch (expected ${want}, got ${got})."
        return 1
    fi
    install -m 0755 "${d}/composer.phar" /usr/local/bin/composer || return 1
    [[ -e /usr/bin/composer ]] || ln -sf /usr/local/bin/composer /usr/bin/composer
    echo "Composer installed: $(/usr/local/bin/composer --version 2>/dev/null | head -n1)"
}

# composer_run <args...> - composer as root inside the app directory.
composer_run() {
    (cd "$APP_DIR" && COMPOSER_ALLOW_SUPERUSER=1 COMPOSER_NO_INTERACTION=1 "$(composer_bin)" "$@")
}
