# shellcheck shell=bash
# .env writing must round-trip every value phpdotenv reads back unchanged.

_roundtrip() {
    local v="$1" f="${T_TMP}/rt.env"
    : >"$f"
    env_write_value KEY "$v" "$f"
    assert_eq "$v" "$(env_read_value KEY "$f")" "roundtrip of [$v] (stored as $(cat "$f"))"
}

test_env_roundtrip() {
    _roundtrip "simple"
    _roundtrip "DezerX Spartan"
    _roundtrip "https://dash.example.com"
    _roundtrip 'pa$word'
    _roundtrip 'quote"inside'
    _roundtrip 'back\slash'
    _roundtrip "it's"
    _roundtrip 'has # hash'
    _roundtrip ""
}

test_env_format_quoting() {
    assert_eq "A=plain" "$(_env_format A plain)" "plain"
    assert_eq 'A="two words"' "$(_env_format A 'two words')" "double quoted like 1.x"
    assert_eq "A='pa\$\$w0rd'" "$(_env_format A 'pa$$w0rd')" "dollar uses single quotes"
    assert_eq 'A="x\\y"' "$(_env_format A 'x\y')" "backslash escaped"
}

test_env_write_replaces_in_place() {
    local f="${T_TMP}/a.env"
    printf '# comment\nAPP_NAME=Old\nDB_HOST=127.0.0.1\nAPP_NAME_SUFFIX=keep\n' >"$f"
    chmod 640 "$f"
    env_write_value APP_NAME "New Name" "$f"
    assert_eq '# comment
APP_NAME="New Name"
DB_HOST=127.0.0.1
APP_NAME_SUFFIX=keep' "$(cat "$f")" "only APP_NAME changed"
    assert_eq 640 "$(stat -c %a "$f")" "mode kept"
}

test_env_write_appends_after_missing_newline() {
    local f="${T_TMP}/b.env"
    printf 'A=1' >"$f"
    env_write_value B 2 "$f"
    assert_eq $'A=1\nB=2' "$(cat "$f")" "newline added"
}

test_env_merge_keeps_custom_keys() {
    APP_DIR="${T_TMP}/app"
    mkdir -p "$APP_DIR"
    printf '# my settings\nAPP_KEY=base64:abc\nSTRIPE_SECRET=sk_live_1\nOCTANE_HTTPS=true\n' >"${APP_DIR}/.env"
    printf 'APP_KEY=\nNEW_FEATURE=on\nCACHE_STORE=redis\nQUEUE_CONNECTION=redis\nOCTANE_HTTPS=false\n' >"${APP_DIR}/.env.example"
    env_merge >/dev/null
    local out
    out="$(cat "${APP_DIR}/.env")"
    [[ "$out" == *"STRIPE_SECRET=sk_live_1"* ]]
    assert_eq 0 $? "custom key kept"
    [[ "$out" == *"# my settings"* ]]
    assert_eq 0 $? "comment kept"
    assert_eq base64:abc "$(env_read_value APP_KEY)" "existing value wins"
    assert_eq true "$(env_read_value OCTANE_HTTPS)" "installer key kept"
    assert_eq on "$(env_read_value NEW_FEATURE)" "new key added"
    assert_eq database "$(env_read_value CACHE_STORE)" "cache defaults to database until Redis is verified"
    assert_eq database "$(env_read_value QUEUE_CONNECTION)" "queue defaults to database"
    env_merge >/dev/null
    assert_eq 1 "$(grep -c '^NEW_FEATURE=' "${APP_DIR}/.env")" "second merge adds nothing"
}
