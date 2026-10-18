# shellcheck shell=bash
# Nginx: package, layout detection and the Spartan virtual host.
# The vhost templates are the 1.x ones (same file names, logs, headers, Octane
# proxy and micro-cache); changes are marked where they fix something.

nginx_version() { nginx -v 2>&1 | sed -nE 's|.*nginx/([0-9.]+).*|\1|p'; }

nginx_layout_detect() {
    if [[ -d /etc/nginx/sites-available && -d /etc/nginx/sites-enabled ]]; then
        NGINX_MODE="debian"
        NGINX_ENABLED="/etc/nginx/sites-enabled"
        NGINX_CONF_PATH="/etc/nginx/sites-available/spartan.conf"
        NGINX_CONF_OLD_PATH="/etc/nginx/sites-available/dezerx.conf"
        NGINX_CONF_OLD_SYMLINK="/etc/nginx/sites-enabled/dezerx.conf"
    else
        NGINX_MODE="rhel"
        NGINX_ENABLED=""
        NGINX_CONF_PATH="/etc/nginx/conf.d/spartan.conf"
        NGINX_CONF_OLD_PATH="/etc/nginx/conf.d/dezerx.conf"
        NGINX_CONF_OLD_SYMLINK=""
    fi
    log "Nginx layout: ${NGINX_MODE} (vhost ${NGINX_CONF_PATH})"
}

# Installs Nginx. An Nginx that is already installed is kept as it is (other
# sites may depend on its packaging); otherwise the nginx.org mainline
# repository is used, falling back to the distribution package.
install_nginx() {
    if have nginx; then
        echo "Nginx $(nginx_version) is already installed; keeping it."
        return 0
    fi
    case "$OS_BASE" in
        ubuntu | debian)
            if [[ "$(apt_repo_state "${NGINX_APT_URL}/${OS_BASE}")" == "missing" ]]; then
                echo "nginx.org has no packages for ${PKG_CODENAME} yet; installing the distribution's Nginx."
                rm -f /etc/apt/sources.list.d/nginx.list
            else
                curl -fsSL --retry 3 https://nginx.org/keys/nginx_signing.key | gpg --dearmor --yes -o /usr/share/keyrings/nginx-archive-keyring.gpg || return 1
                echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] ${NGINX_APT_URL}/${OS_BASE} ${PKG_CODENAME} nginx" \
                    >/etc/apt/sources.list.d/nginx.list
                printf '%s\n' "Package: *" "Pin: origin nginx.org" "Pin: release o=nginx" "Pin-Priority: 900" \
                    >/etc/apt/preferences.d/99nginx
            fi
            apt_get update || return 1
            pkg_install nginx || return 1
            ;;
        el)
            cat >/etc/yum.repos.d/nginx.repo <<'EOF'
[nginx-stable]
name=nginx stable repo
baseurl=https://nginx.org/packages/centos/$releasever/$basearch/
gpgcheck=1
enabled=1
gpgkey=https://nginx.org/keys/nginx_signing.key
module_hotfixes=true

[nginx-mainline]
name=nginx mainline repo
baseurl=https://nginx.org/packages/mainline/centos/$releasever/$basearch/
gpgcheck=1
enabled=1
gpgkey=https://nginx.org/keys/nginx_signing.key
module_hotfixes=true
EOF
            if ! pkg_install nginx; then
                echo "nginx.org packages are not available here; using the distribution's Nginx."
                rm -f /etc/yum.repos.d/nginx.repo
                pkg_install nginx || return 1
            fi
            ;;
        *) pkg_install nginx || return 1 ;;
    esac
    have nginx || return 1
    echo "Nginx $(nginx_version) installed."
}

# Apache on port 80 keeps Nginx from starting (1.x did the same).
no_apache() {
    local pkg svc sock
    if is_debian_family; then pkg="apache2" svc="apache2.service" sock="apache2.socket"; else pkg="httpd" svc="httpd.service" sock="httpd.socket"; fi
    if pkg_installed "$pkg" || svc_exists "$svc"; then
        echo "Apache found, stopping and disabling it."
        systemctl disable --now "$svc" >/dev/null 2>&1
        systemctl disable --now "$sock" >/dev/null 2>&1
    else
        echo "Apache is not installed."
    fi
    return 0
}

nginx_remove_defaults() {
    local f
    for f in /etc/nginx/sites-enabled/default /etc/nginx/sites-available/default /etc/nginx/conf.d/default.conf; do
        if [[ -e "$f" || -L "$f" ]]; then
            rm -f "$f" && echo "Removed default site ${f}"
        fi
    done
}

nginx_enable_site() {
    if [[ "$NGINX_MODE" == debian && -n "$NGINX_ENABLED" ]]; then
        ln -sf "$NGINX_CONF_PATH" "${NGINX_ENABLED}/spartan.conf"
    fi
}

# Other vhosts claiming the same server_name make Nginx pick one at random;
# they are disabled (symlinks removed, files renamed) like in 1.x.
nginx_disable_conflicting_sites() {
    [[ -n "$DOMAIN" ]] || return 0
    local dir="/etc/nginx/conf.d"
    [[ "$NGINX_MODE" == debian ]] && dir="$NGINX_ENABLED"
    [[ -d "$dir" ]] || return 0
    local ours upstream stamp domain_re f target
    ours="$(readlink -f "$NGINX_CONF_PATH" 2>/dev/null || echo "$NGINX_CONF_PATH")"
    upstream="$(readlink -f "$NGINX_UPSTREAM_CONF" 2>/dev/null || true)"
    stamp="$(date +%Y%m%d-%H%M%S)"
    domain_re="$(printf '%s' "$DOMAIN" | sed 's/[].[^$*\\/]/\\&/g')"
    for f in "$dir"/*; do
        [[ -e "$f" ]] || continue
        [[ "$f" == *.disabled-by-spartan-* ]] && continue
        target="$(readlink -f "$f" 2>/dev/null || echo "$f")"
        [[ "$target" == "$ours" ]] && continue
        [[ -n "$upstream" && "$target" == "$upstream" ]] && continue
        grep -qE "^[[:space:]]*server_name[^;]*[[:space:]]${domain_re}[[:space:];]" "$f" 2>/dev/null || continue
        if [[ -L "$f" ]]; then
            rm -f "$f"
        else
            mv "$f" "${f}.disabled-by-spartan-${stamp}"
        fi
        echo "Disabled conflicting vhost $(basename "$f") (server_name ${DOMAIN})"
    done
}

nginx_write_octane_upstream() {
    if ! octane_wanted; then
        rm -f "$NGINX_UPSTREAM_CONF"
        return 0
    fi
    mkdir -p /var/cache/nginx
    octane_runtime_defaults
    cat >"$NGINX_UPSTREAM_CONF" <<EOF
map \$http_upgrade \$spartan_connection_upgrade {
    default upgrade;
    ''      '';
}

map \$http_x_forwarded_proto \$spartan_forwarded_proto {
    default \$scheme;
    https   https;
    http    http;
}

upstream spartan_octane {
    server ${OCTANE_HOST}:${OCTANE_PORT} fail_timeout=0;
    keepalive 64;
}

proxy_cache_path /var/cache/nginx/spartan levels=1:2 keys_zone=spartan_micro:10m max_size=256m inactive=60s use_temp_path=off;

map \$http_cookie \$spartan_skip_cache {
    default 0;
    "~*(^|;\\s*)(remember_[^=]*|[^=;]*_session)=" 1;
}
EOF
}

nginx_performance_block() {
    cat <<'EOF'
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 5;
    gzip_min_length 1024;
    gzip_types text/plain text/css text/xml text/javascript application/javascript application/json application/xml application/rss+xml application/wasm image/svg+xml;

    open_file_cache max=10000 inactive=60s;
    open_file_cache_valid 60s;
    open_file_cache_min_uses 2;
    open_file_cache_errors on;

    location /build/ {
        try_files $uri =404;
        access_log off;
        sendfile on;
        gzip_static on;
        add_header Cache-Control "public, max-age=31536000, immutable";
    }
EOF
}

nginx_app_location_block() {
    if octane_wanted; then
        cat <<'EOF'
    location = /index.php {
        try_files /__octane_only__ @octane;
    }

    location / {
        try_files $uri $uri/ @octane;
    }

    location @octane {
        set $suffix "";

        if ($uri = /index.php) {
            set $suffix ?$query_string;
        }

        proxy_http_version 1.1;
        proxy_set_header Host $http_host;
        proxy_set_header Scheme $spartan_forwarded_proto;
        proxy_set_header SERVER_PORT $server_port;
        proxy_set_header REMOTE_ADDR $remote_addr;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $spartan_forwarded_proto;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $spartan_connection_upgrade;
        proxy_buffering off;
        proxy_cache spartan_micro;
        proxy_cache_key "$scheme$host$request_uri|$http_x_inertia|$http_x_inertia_version|$cookie_appearance|$cookie_sidebar_state";
        proxy_cache_bypass $spartan_skip_cache $http_authorization;
        proxy_no_cache $spartan_skip_cache $http_authorization;
        proxy_ignore_headers Cache-Control Expires;
        proxy_cache_use_stale updating;
        proxy_connect_timeout 30s;
        proxy_send_timeout 300s;
        proxy_read_timeout 300s;
        proxy_pass http://spartan_octane$suffix;
    }
EOF
    else
        cat <<EOF
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass $(php_fpm_socket);
        fastcgi_index index.php;
        include /etc/nginx/fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize=100M \n post_max_size=100M \n max_execution_time=300";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 64k;
        fastcgi_buffers 8 64k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
    }
EOF
    fi
}

# nginx_render_vhost <http|ssl> - prints the Spartan vhost.
nginx_render_vhost() {
    local mode="$1" app_block perf_block
    app_block="$(nginx_app_location_block)"
    perf_block="$(nginx_performance_block)"
    local listen_80="    listen 80;"
    ((ENABLE_IPV6)) && listen_80+=$'\n'"    listen [::]:80;"

    if [[ "$mode" == http ]]; then
        cat <<EOF
server {
${listen_80}
    server_name ${DOMAIN};

    root ${APP_DIR}/public;
    index index.php index.html;

    charset utf-8;

    access_log /var/log/nginx/dezerx.app-access.log;
    error_log  /var/log/nginx/dezerx.app-error.log error;

    client_max_body_size 100m;
    client_body_timeout 120s;

${perf_block}

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

${app_block}

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
EOF
        return 0
    fi

    # "listen ... http2" is deprecated since nginx 1.25.1 (warning on every reload).
    local listen_443 http2_line=""
    if version_ge "$(nginx_version)" "1.25.1"; then
        listen_443="    listen 443 ssl;"
        ((ENABLE_IPV6)) && listen_443+=$'\n'"    listen [::]:443 ssl;"
        http2_line=$'\n'"    http2 on;"
    else
        listen_443="    listen 443 ssl http2;"
        ((ENABLE_IPV6)) && listen_443+=$'\n'"    listen [::]:443 ssl http2;"
    fi

    cat <<EOF
server {
${listen_80}
    server_name ${DOMAIN};

    # Certificate renewals are answered over HTTP before the redirect.
    location ^~ /.well-known/acme-challenge/ {
        root ${APP_DIR}/public;
        default_type text/plain;
    }

    location / {
        return 301 https://\$server_name\$request_uri;
    }
}

server {
${listen_443}${http2_line}
    server_name ${DOMAIN};

    root ${APP_DIR}/public;
    index index.php index.html;

    charset utf-8;

    access_log /var/log/nginx/dezerx.app-access.log;
    error_log  /var/log/nginx/dezerx.app-error.log error;

    client_max_body_size 100m;
    client_body_timeout 120s;

    sendfile off;

    ssl_certificate ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/privkey.pem;
    ssl_session_cache shared:SSL:10m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384";
    ssl_prefer_server_ciphers on;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains";
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Robots-Tag none;
    add_header Content-Security-Policy "frame-ancestors 'self'";
    add_header X-Frame-Options DENY;
    add_header Referrer-Policy same-origin;

${perf_block}

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

${app_block}

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
EOF
}

# configure_nginx <http|ssl> - writes the vhost and reloads Nginx. The new
# config is tested first; if `nginx -t` fails the previous files are put back
# and Nginx keeps serving (1.x restarted a broken config and took sites down).
configure_nginx() {
    local mode="$1"
    nginx_layout_detect
    local keep_vhost="" keep_up=""
    work_dir nginx || return 1
    local saved="$REPLY"
    [[ -f "$NGINX_CONF_PATH" ]] && cp -a "$NGINX_CONF_PATH" "${saved}/vhost" && keep_vhost=1
    [[ -f "$NGINX_UPSTREAM_CONF" ]] && cp -a "$NGINX_UPSTREAM_CONF" "${saved}/upstream" && keep_up=1

    php_fpm_start || true
    nginx_remove_defaults
    nginx_disable_conflicting_sites
    nginx_write_octane_upstream || return 1
    nginx_render_vhost "$mode" >"$NGINX_CONF_PATH" || return 1
    nginx_enable_site
    [[ -n "$NGINX_CONF_OLD_PATH" && -f "$NGINX_CONF_OLD_PATH" ]] && rm -f "$NGINX_CONF_OLD_PATH"
    [[ -n "$NGINX_CONF_OLD_SYMLINK" && -L "$NGINX_CONF_OLD_SYMLINK" ]] && rm -f "$NGINX_CONF_OLD_SYMLINK"

    if ! nginx -t; then
        echo "The new Nginx configuration does not pass nginx -t; restoring the previous one."
        if [[ -n "$keep_vhost" ]]; then cp -a "${saved}/vhost" "$NGINX_CONF_PATH"; else rm -f "$NGINX_CONF_PATH" "${NGINX_ENABLED:-/nonexistent}/spartan.conf"; fi
        if [[ -n "$keep_up" ]]; then cp -a "${saved}/upstream" "$NGINX_UPSTREAM_CONF"; else rm -f "$NGINX_UPSTREAM_CONF"; fi
        return 1
    fi
    systemctl enable nginx >/dev/null 2>&1
    if svc_active nginx; then
        systemctl reload nginx || systemctl restart nginx
    else
        systemctl restart nginx
    fi
}

# The certificate path an existing vhost uses (1.x vhosts or ours).
nginx_existing_cert_dir() {
    local f p
    for f in "$NGINX_CONF_OLD_PATH" "$NGINX_CONF_PATH"; do
        [[ -n "$f" && -f "$f" ]] || continue
        p="$(grep -Eo 'ssl_certificate[[:space:]]+[^;]+' "$f" | head -n1 | awk '{ print $2 }')"
        [[ -n "$p" ]] && { dirname "$p"; return 0; }
    done
    return 1
}

nginx_restart() {
    nginx -t >/dev/null 2>&1 || { nginx -t; return 1; }
    systemctl restart nginx
}
