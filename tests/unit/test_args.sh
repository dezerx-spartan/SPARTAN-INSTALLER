# shellcheck shell=bash
# Command line compatibility with 1.x.

test_args_readme_noninteractive_install() {
    # The 1.x README one-liner appends "-- flags" after the script.
    parse_args -- --non-interactive --install --license=SPARTANPROFESSIONAL_ABC123 --domain dash.example.com \
        --webserver=nginx --ssl-mode=install --db-type=mariadb
    assert_eq 1 "$NONINTERACTIVE" "non-interactive"
    assert_eq install "$ACTION" "action"
    assert_eq SPARTANPROFESSIONAL_ABC123 "$LICENSE_KEY" "license"
    assert_eq 5 "$PRODUCT_ID" "product id"
    assert_eq dash.example.com "$DOMAIN" "domain"
    assert_eq nginx "$WEB" "webserver"
    assert_eq install "$SSL_MODE" "ssl mode"
    assert_eq mariadb "$DB_ENGINE" "db type"
}

test_args_spartan_autoupdater_command() {
    # AutoUpdaterCommand.php: bash -c "$(curl ...)" -- --non-interactive --update --app-dir="<base_path>"
    parse_args --non-interactive --update --app-dir=/var/www/spartan
    assert_eq update "$ACTION" "action"
    assert_eq /var/www/spartan "$APP_DIR" "app dir"
    assert_eq 1 "$USED_APP_DIR" "app dir flag"
    assert_eq 0 "${#ARG_WARNINGS[@]}" "no warnings"
}

test_args_spaced_forms() {
    parse_args --app-dir /srv/spartan/ --license SPARTANSTARTER_X1 --domain HTTPS://Dash.Example.com/ --db-type mysql --ssl-mode later
    assert_eq /srv/spartan "$APP_DIR" "trailing slash removed"
    assert_eq 1 "$PRODUCT_ID" "starter product"
    assert_eq dash.example.com "$DOMAIN" "domain normalised"
    assert_eq mysql "$DB_ENGINE" "db engine"
    assert_eq later "$SSL_MODE" "ssl later"
}

test_args_add_swap_does_not_eat_next_flag() {
    parse_args --add-swap --install
    assert_eq 1 "$FORCE_SWAP" "force swap"
    assert_eq 2048 "$SWAP_SIZE_MB" "default size"
    assert_eq install "$ACTION" "next flag kept"
}

test_args_add_swap_sizes() {
    parse_args --add-swap 4G
    assert_eq 4096 "$SWAP_SIZE_MB" "4G"
    parse_args --add-swap=1024
    assert_eq 1024 "$SWAP_SIZE_MB" "plain number is MB"
    parse_args --add-swap 512M
    assert_eq 512 "$SWAP_SIZE_MB" "512M"
}

test_args_ipv6_forms() {
    parse_args --ipv6
    assert_eq 1 "$ENABLE_IPV6" "bare --ipv6"
    ENABLE_IPV6=0
    parse_args --ipv6 --install
    assert_eq 1 "$ENABLE_IPV6" "--ipv6 before another flag"
    assert_eq install "$ACTION" "flag after --ipv6 kept"
    parse_args --ipv6 false
    assert_eq 0 "$ENABLE_IPV6" "--ipv6 false"
    parse_args --ipv6=enable
    assert_eq 1 "$ENABLE_IPV6" "--ipv6=enable"
}

test_args_octane_forms() {
    parse_args --octane=no
    assert_eq 0 "$OCTANE_ENABLED" "--octane=no"
    parse_args --octane
    assert_eq 1 "$OCTANE_ENABLED" "--octane"
    parse_args --no-octane --octane-workers 6 --queue-workers=3 --octane-port 8100
    assert_eq 0 "$OCTANE_ENABLED" "--no-octane"
    assert_eq 6 "$OCTANE_WORKERS" "octane workers"
    assert_eq 3 "$QUEUE_WORKERS" "queue workers"
    assert_eq 8100 "$OCTANE_PORT" "octane port"
}

test_args_keep_flags() {
    parse_args --keep-nginx --no-keep-css
    assert_eq 1 "$KEEP_NGINX" "keep nginx"
    assert_eq 0 "$KEEP_CSS" "no keep css"
    assert_eq 1 "${KEEP_FROM_CLI[NGINX]:-}" "nginx from cli"
    assert_eq 1 "${KEEP_FROM_CLI[CSS]:-}" "css from cli"
}

test_args_rejects_bad_values() {
    assert_fail "invalid license" parse_args --license NOTAKEY 2>/dev/null
    assert_fail "apache" parse_args --webserver apache 2>/dev/null
    assert_fail "octane workers 0" parse_args --octane-workers 0 2>/dev/null
    assert_fail "octane port too low" parse_args --octane-port 80 2>/dev/null
    assert_fail "missing domain value" parse_args --domain 2>/dev/null
    assert_fail "db name injection" parse_args --db-name 'x`;drop' 2>/dev/null
}

test_args_unknown_option_warns_and_continues() {
    parse_args --frobnicate --update
    assert_eq update "$ACTION" "parsing continued"
    assert_eq "Unknown option: --frobnicate" "${ARG_WARNINGS[0]}" "warning recorded"
}

test_args_aliases() {
    parse_args --delete
    assert_eq uninstall "$ACTION" "--delete"
    parse_args --setup-perms
    assert_eq setup_perms "$ACTION" "--setup-perms"
    parse_args --upload-logs
    assert_eq support_bundle "$ACTION" "--upload-logs"
    parse_args --test
    assert_eq 1 "$DEMO" "--test is the demo"
}

test_args_secrets_masked_in_log_text() {
    parse_args --db-pass hunter2secret --license SPARTANULTIMATE_SECRETKEY99
    [[ "$SPARTAN_ARGS_TEXT" != *hunter2secret* ]]
    assert_eq 0 $? "db password masked"
    [[ "$SPARTAN_ARGS_TEXT" != *SECRETKEY99* ]]
    assert_eq 0 $? "license masked"
}
