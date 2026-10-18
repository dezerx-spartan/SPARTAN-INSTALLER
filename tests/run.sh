#!/usr/bin/env bash
# Unit tests for the installer's pure functions. No root needed, nothing on the
# system is changed (temporary files live in a private directory).
#
# Usage: tests/run.sh [pattern]

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPARTAN_VERSION="0.0.0-test"

while IFS= read -r _m || [[ -n "$_m" ]]; do
    [[ -z "$_m" || "$_m" == \#* ]] && continue
    # shellcheck source=/dev/null
    source "${ROOT}/src/${_m}"
done <"${ROOT}/src/modules.list"

T_PASS=0
T_FAIL=0
T_CURRENT=""
T_TMP="$(mktemp -d)"
trap 'rm -rf "$T_TMP"' EXIT
UI_MODE="plain"
UI_FD=1
ui_glyphs_init

assert_eq() {
    local expected="$1" actual="$2" msg="${3:-}"
    if [[ "$expected" == "$actual" ]]; then
        T_PASS=$((T_PASS + 1))
    else
        T_FAIL=$((T_FAIL + 1))
        printf '  FAIL %s: %s\n    expected: %q\n    actual:   %q\n' "$T_CURRENT" "$msg" "$expected" "$actual"
    fi
}

assert_ok() {
    local msg="$1"
    shift
    if "$@"; then T_PASS=$((T_PASS + 1)); else
        T_FAIL=$((T_FAIL + 1))
        printf '  FAIL %s: %s (expected success)\n' "$T_CURRENT" "$msg"
    fi
}

assert_fail() {
    local msg="$1"
    shift
    if "$@"; then
        T_FAIL=$((T_FAIL + 1))
        printf '  FAIL %s: %s (expected failure)\n' "$T_CURRENT" "$msg"
    else T_PASS=$((T_PASS + 1)); fi
}

for _t in "${ROOT}"/tests/unit/*.sh; do
    # shellcheck source=/dev/null
    source "$_t"
done

for _fn in $(declare -F | awk '{ print $3 }' | grep '^test_' | sort); do
    [[ -n "${1:-}" && "$_fn" != *"$1"* ]] && continue
    T_CURRENT="$_fn"
    echo "0 1" >"${T_TMP}/result"
    (
        T_PASS=0
        T_FAIL=0
        "$_fn"
        echo "$T_PASS $T_FAIL" >"${T_TMP}/result"
    )
    read -r p f <"${T_TMP}/result"
    T_PASS=$((T_PASS + p))
    T_FAIL=$((T_FAIL + f))
    if ((f)); then printf 'not ok %s\n' "$_fn"; else printf 'ok     %s\n' "$_fn"; fi
done

printf '\n%d passed, %d failed\n' "$T_PASS" "$T_FAIL"
((T_FAIL == 0))
