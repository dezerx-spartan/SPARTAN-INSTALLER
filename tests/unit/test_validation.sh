# shellcheck shell=bash

test_domain_normalize() {
    assert_eq dash.example.com "$(domain_normalize '  https://Dash.Example.COM/login?x=1 ')" "url"
    assert_eq example.com "$(domain_normalize 'example.com.')" "trailing dot"
    assert_eq example.com "$(domain_normalize 'http://example.com:8080')" "port"
}

test_domain_valid() {
    assert_ok "simple" domain_valid example.com
    assert_ok "sub" domain_valid dash.my-host.co.uk
    assert_ok "punycode" domain_valid xn--bcher-kva.example
    assert_ok "ipv4" domain_valid 203.0.113.10
    assert_fail "no dot" domain_valid localhost
    assert_fail "underscore" domain_valid bad_name.com
    assert_fail "space" domain_valid "a b.com"
    assert_fail "leading dash" domain_valid -x.com
}

test_path_is_protected() {
    local p
    for p in / /var /var/www /var/www/ /etc /etc/nginx /usr/local /home /home/alice /root /tmp /var/lib/mysql /opt; do
        assert_ok "protected ${p}" path_is_protected "$p"
    done
    for p in /var/www/spartan /srv/spartan /opt/spartan /home/alice/spartan /var/www/html; do
        assert_fail "allowed ${p}" path_is_protected "$p"
    done
    assert_ok "relative path" path_is_protected "var/www/spartan"
    assert_ok "empty" path_is_protected ""
    assert_ok "dot-dot escape" path_is_protected "/var/www/spartan/../.."
}

test_safe_rm_refuses_protected() {
    assert_fail "rm /var/www" safe_rm_rf /var/www
    local d="${T_TMP}/x/y"
    mkdir -p "$d"
    WORK_BASE="$T_TMP"
    safe_rm_rf "$d"
    [[ ! -e "$d" ]]
    assert_eq 0 $? "removes normal paths"
}

test_db_ident_and_ports() {
    assert_ok "dezerx" db_ident_valid dezerx
    assert_ok "under_score" db_ident_valid my_db_2
    assert_fail "dash" db_ident_valid my-db
    assert_fail "backtick" db_ident_valid 'a`b'
    assert_ok "3306" port_valid 3306
    assert_fail "0" port_valid 0
    assert_fail "70000" port_valid 70000
}

test_version_compare() {
    assert_ok "8.4 >= 8.2" version_ge 8.4 8.2
    assert_ok "8.10 >= 8.9" version_ge 8.10 8.9
    assert_fail "8.1 >= 8.2" version_ge 8.1 8.2
    assert_ok "6.0.3 > 6.0.2" version_gt 6.0.3 6.0.2
    assert_fail "equal not greater" version_gt 6.0.2 6.0.2
    assert_eq 8.4 "$(version_minor 8.4.13)" "minor"
}

test_swap_size_to_mb() {
    assert_eq 2048 "$(swap_size_to_mb 2G)" "2G"
    assert_eq 1024 "$(swap_size_to_mb 1024)" "1024"
    assert_eq 512 "$(swap_size_to_mb 512m)" "512m"
    assert_fail "garbage" swap_size_to_mb lots
}

test_license_products() {
    license_apply_key SPARTANDEV_ABCD1234
    assert_eq 6 "$PRODUCT_ID" "dev is product 6"
    assert_eq "Spartan Developer" "$PRODUCT_NAME" "dev name"
    license_apply_key SPARTANULTIMATE_Z9
    assert_eq "Spartan Ultimate" "$PRODUCT_NAME" "ultimate"
    assert_fail "prefix only" license_apply_key SPARTANSTARTER_
    UI_UTF8=0
    ui_glyphs_init
    assert_eq "SPARTANULTIMATE_~CUZ9" "$(license_masked SPARTANULTIMATE_ABCUZ9)" "masked keeps product and last 4"
}

test_ip_cidr() {
    assert_ok "in /20" ip4_in_cidr 173.245.50.1 173.245.48.0/20
    assert_fail "outside" ip4_in_cidr 173.245.64.1 173.245.48.0/20
    assert_ok "cloudflare" ip4_is_cloudflare 104.21.3.4
    assert_fail "not cloudflare" ip4_is_cloudflare 203.0.113.10
}
