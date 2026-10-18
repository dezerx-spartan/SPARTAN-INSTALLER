# shellcheck shell=bash
# SSL: Let's Encrypt through the webroot, or a self-signed certificate.
#
# Fixes over 1.x: when Let's Encrypt fails the site stays on working HTTP
# (1.x wrote an HTTPS vhost pointing at missing files and Nginx went down),
# and renewals reload Nginx so a renewed certificate is actually served.

install_certbot_pkgs() {
    have certbot && return 0
    if is_debian_family; then
        pkg_install certbot python3-certbot-nginx || pkg_install certbot || return 1
    else
        if [[ "$OS_FAMILY" == rhel ]] && ! pkg_installed epel-release; then
            pkg_install epel-release ||
                pkg_install "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${OS_EL_MAJOR}.noarch.rpm" || true
        fi
        pkg_install certbot python3-certbot-nginx || pkg_install certbot || return 1
    fi
}

ssl_letsencrypt_dir() { echo "${LETSENCRYPT_LIVE}/${DOMAIN}"; }

certbot_issue() {
    local email="${SSL_EMAIL:-admin@${DOMAIN}}"
    mkdir -p "${APP_DIR}/public/.well-known/acme-challenge"
    certbot certonly --non-interactive --agree-tos -m "$email" --webroot -w "${APP_DIR}/public" \
        -d "$DOMAIN" --keep-until-expiring
}

certbot_renewal_hook() {
    mkdir -p "$(dirname "$CERTBOT_DEPLOY_HOOK")"
    cat >"$CERTBOT_DEPLOY_HOOK" <<'EOF'
#!/bin/sh
# Installed by the DezerX Spartan installer: serve renewed certificates.
nginx -t >/dev/null 2>&1 && systemctl reload nginx
EOF
    chmod 755 "$CERTBOT_DEPLOY_HOOK"
    local t
    for t in certbot.timer certbot-renew.timer snap.certbot.renew.timer; do
        if systemctl list-unit-files --no-legend "$t" 2>/dev/null | grep -q .; then
            systemctl enable --now "$t" >/dev/null 2>&1
        fi
    done
    return 0
}

create_self_signed_certs() {
    local dir="${SELF_SIGNED_BASE}/${DOMAIN}"
    mkdir -p "$dir"
    local -a san=()
    if openssl req -help 2>&1 | grep -q -- '-addext'; then
        if domain_is_ip "$DOMAIN"; then san=(-addext "subjectAltName=IP:${DOMAIN}"); else san=(-addext "subjectAltName=DNS:${DOMAIN},DNS:*.${DOMAIN}"); fi
    fi
    openssl req -x509 -nodes -sha256 -days 365 -newkey rsa:4096 \
        -subj "/O=DezerX Spartan - Bauer Kuke EDV GBR/CN=${DOMAIN}" "${san[@]}" \
        -keyout "${dir}/privkey.pem" -out "${dir}/fullchain.pem" || return 1
    chmod 750 "$dir"
    chmod 640 "${dir}/privkey.pem" "${dir}/fullchain.pem"
    chown -R "${APP_USER:-root}:${APP_GROUP:-root}" "$dir" 2>/dev/null
    CERT_DIR="$dir"
    echo "Self-signed certificate created in ${dir}"
}

# flip_app_url_to_https - APP_URL to https and Octane told about TLS.
flip_app_url_to_https() {
    [[ -f "${APP_DIR}/.env" ]] || return 0
    env_write_value APP_URL "https://${DOMAIN}"
    octane_wanted && env_write_value OCTANE_HTTPS true
    return 0
}

# ssl_apply - runs the chosen SSL mode for a fresh install or the SSL tool.
# Returns 3 when SSL was skipped on purpose.
ssl_apply() {
    case "${SSL_MODE:-later}" in
        install)
            if domain_is_ip "$DOMAIN"; then
                warn_add "Let's Encrypt cannot issue certificates for an IP address; the site stays on HTTP."
                return 0
            fi
            task "Installing certbot" install_certbot_pkgs || {
                warn_add "certbot could not be installed; the site stays on HTTP."
                return 0
            }
            if ! task "Requesting a Let's Encrypt certificate for ${DOMAIN}" certbot_issue; then
                SSL_RESULT="failed"
                warn_add "Let's Encrypt could not issue a certificate for ${DOMAIN} (check that DNS points to this server and port 80 is open). The site runs on HTTP; run the installer with --ssl to try again."
                return 0
            fi
            CERT_DIR="$(ssl_letsencrypt_dir)"
            task "Enabling automatic renewal" certbot_renewal_hook || true
            ;;
        assume)
            task "Creating a self-signed certificate" create_self_signed_certs || {
                warn_add "The self-signed certificate could not be created; the site stays on HTTP."
                return 0
            }
            ;;
        *)
            return 3
            ;;
    esac
    task "Switching Nginx to HTTPS" configure_nginx ssl || {
        warn_add "Nginx did not accept the HTTPS configuration; the site stays on HTTP."
        task "Restoring the HTTP configuration" configure_nginx http || true
        return 0
    }
    task "Setting APP_URL to https://${DOMAIN}" flip_app_url_to_https || true
    SSL_RESULT="ok"
    return 0
}
