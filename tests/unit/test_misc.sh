# shellcheck shell=bash

test_options_clean_path() {
    APP_DIR="/var/www/spartan"
    assert_eq "resources/css" "$(opts_clean_path '/var/www/spartan/resources/css/')" "absolute inside app"
    assert_eq "Modules/Addons/X" "$(opts_clean_path 'Modules/Addons/X')" "relative"
    assert_eq "" "$(opts_clean_path '../etc/passwd')" "parent escape"
    assert_eq "" "$(opts_clean_path 'a/../../b')" "nested escape"
    assert_eq "" "$(opts_clean_path '/')" "root"
    assert_eq "" "$(opts_clean_path '.')" "dot"
}

test_options_keep_precedence() {
    have jq || return 0
    APP_DIR="$T_TMP"
    OPTIONS_JSON_NAME="opts.json"
    printf '{"keep":{"nginx":true,"css":false,"themes":false}}' >"${T_TMP}/opts.json"
    KEEP_NGINX=0 KEEP_CSS=1 KEEP_THEMES=1
    KEEP_FROM_CLI=([THEMES]=1)
    opts_load_keep
    assert_eq 1 "$KEEP_NGINX" "file turns nginx on"
    assert_eq 0 "$KEEP_CSS" "file turns css off"
    assert_eq 1 "$KEEP_THEMES" "command line wins over the file"
    KEEP_PORTALS=0
    opts_save_keep
    assert_eq false "$(jq -r .keep.portals "${T_TMP}/opts.json")" "choices saved"
    assert_eq true "$(jq -r .keep.nginx "${T_TMP}/opts.json")" "other keys kept"
}

test_json_get_with_and_without_jq() {
    local f="${T_TMP}/r.json"
    printf '{"success":true,"message":"OK","data":{"is_active":true,"download_url":"https:\\/\\/x.test\\/a?b=1","file_size":123}}' >"$f"
    assert_eq true "$(json_get "$f" .success)" "bool"
    assert_eq "https://x.test/a?b=1" "$(json_get "$f" .data.download_url)" "url"
    # Before the essentials are installed jq may be missing: the fallback parser.
    have() { [[ "$1" != jq && "$1" != python3 && "$1" != php ]] && command -v "$1" >/dev/null 2>&1; }
    assert_eq true "$(json_get "$f" .data.is_active)" "fallback bool"
    assert_eq "https://x.test/a?b=1" "$(json_get "$f" .data.download_url)" "fallback unescapes"
    assert_eq 123 "$(json_get "$f" .data.file_size)" "fallback number"
}

test_text_wrap_keeps_columns_and_indents() {
    UI_UTF8=1
    ui_glyphs_init
    text_wrap 30 "  {d}Label     {/} value
- a list item that is long enough to wrap"
    assert_eq "  {d}Label     {/} value" "${WRAP_LINES[0]}" "spacing kept"
    assert_eq "- a list item that is long" "${WRAP_LINES[1]}" "item"
    assert_eq "  enough to wrap" "${WRAP_LINES[2]}" "hanging indent"
    text_vlen "{b}abc{/}{e}d{/}"
    assert_eq 4 "$TEXT_VLEN" "tags take no space"
}

test_cron_regex_matches_only_this_app() {
    APP_DIR="/var/www/spartan"
    local line re
    line="$(cron_line)"
    re="$(cron_match_regex)"
    grep -qE "$re" <<<"$line"
    assert_eq 0 $? "matches our line"
    grep -qE "$re" <<<"* * * * * cd /var/www/spartan2 && php artisan schedule:run"
    assert_eq 1 $? "does not match another app"
    grep -qE "$re" <<<"* * * * * cd /var/www/spartan && php artisan schedule:run >> /dev/null 2>&1"
    assert_eq 0 $? "matches the 1.x line"
}

test_nginx_vhost_rendering() {
    APP_DIR="/var/www/spartan" DOMAIN="dash.example.com" CERT_DIR="/etc/letsencrypt/live/dash.example.com"
    OCTANE_ENABLED=1 OCTANE_HOST=127.0.0.1 OCTANE_PORT=8000 ENABLE_IPV6=0
    nginx_version() { echo 1.29.1; }
    local out
    out="$(nginx_render_vhost ssl)"
    [[ "$out" == *"http2 on;"* && "$out" != *"ssl http2"* ]]
    assert_eq 0 $? "modern http2 syntax"
    [[ "$out" == *"location ^~ /.well-known/acme-challenge/"* ]]
    assert_eq 0 $? "acme location before the redirect"
    [[ "$out" == *"proxy_pass http://spartan_octane"* ]]
    assert_eq 0 $? "octane proxy"
    [[ "$out" != *"[::]"* ]]
    assert_eq 0 $? "no ipv6 listen when disabled"
    nginx_version() { echo 1.24.0; }
    out="$(nginx_render_vhost ssl)"
    [[ "$out" == *"listen 443 ssl http2;"* ]]
    assert_eq 0 $? "old nginx keeps listen ... http2"
    OCTANE_ENABLED=0
    php_fpm_socket() { echo unix:/run/php/php8.4-fpm.sock; }
    out="$(nginx_render_vhost http)"
    [[ "$out" == *"fastcgi_pass unix:/run/php/php8.4-fpm.sock;"* ]]
    assert_eq 0 $? "php-fpm vhost"
}

test_db_option_file_works_for_dump_tools() {
    RUN_DIR="$T_TMP" DB_HOST=127.0.0.1 DB_PORT=1 DB_USER=dezer DB_PASS='p"a\ss' DB_ROOT_PASS=""
    db_app_cnf
    local cnf="$REPLY" client_section
    client_section="$(awk '/^\[/{s=$0} s=="[client]"' "$cnf")"
    [[ "$client_section" != *connect-timeout* ]]
    assert_eq 0 $? "[client] holds only options every client tool knows"
    assert_eq 600 "$(stat -c %a "$cnf")" "credentials file is private"
    # With a real dump tool installed, the file must get past option parsing
    # (port 1 is closed, so the run stops at "can't connect").
    local dump
    dump="$(command -v mariadb-dump || command -v mysqldump)" || return 0
    local out
    out="$(timeout 15 "$dump" --defaults-extra-file="$cnf" --no-tablespaces x 2>&1 >/dev/null)"
    [[ "$out" != *"unknown variable"* ]]
    assert_eq 0 $? "dump tool accepts the option file (${out%%$'\n'*})"
}
