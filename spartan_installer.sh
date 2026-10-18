#!/usr/bin/env bash
SPARTAN_RELEASE_TAG=""
SPARTAN_RELEASE_REPO="dezerx-spartan/SPARTAN-INSTALLER"
SPARTAN_BUNDLE_SHA256=""

spartan_fail() {
    printf 'DezerX Spartan Installer: %s\n' "$*" >&2
    exit 1
}

spartan_exec() {
    if [ ! -t 0 ] && { : </dev/tty; } 2>/dev/null; then
        exec "$@" </dev/tty
    fi
    exec "$@"
}

spartan_download() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 -o "$2" "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -q --tries=3 -O "$2" "$1"
    else
        spartan_fail "curl or wget is required."
    fi
}

spartan_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    else
        openssl dgst -sha256 -r "$1" | cut -d' ' -f1
    fi
}

spartan_bootstrap() {
    if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ] ||
        { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
        spartan_fail "bash 4.4 or newer is required."
    fi

    local self="${BASH_SOURCE[0]:-}" dir
    if [ -z "${SPARTAN_BUNDLE_FILE:-}${SPARTAN_BUNDLE_URL:-}" ] && [ -n "$self" ] && [ -f "$self" ]; then
        dir="$(cd "$(dirname "$self")" && pwd)"
        if [ -f "${dir}/src/main.sh" ] && [ -f "${dir}/src/modules.list" ]; then
            spartan_exec bash "${dir}/src/main.sh" "$@"
        fi
    fi

    if [ -n "${SPARTAN_BUNDLE_FILE:-}" ]; then
        [ -r "$SPARTAN_BUNDLE_FILE" ] || spartan_fail "Cannot read ${SPARTAN_BUNDLE_FILE}."
        spartan_exec bash "$SPARTAN_BUNDLE_FILE" "$@"
    fi

    local base url expected="${SPARTAN_BUNDLE_SHA256}"
    if [ -n "$SPARTAN_RELEASE_TAG" ]; then
        base="https://github.com/${SPARTAN_RELEASE_REPO}/releases/download/${SPARTAN_RELEASE_TAG}"
    else
        base="https://github.com/${SPARTAN_RELEASE_REPO}/releases/latest/download"
    fi
    url="${SPARTAN_BUNDLE_URL:-${base}/spartan_installer.bundle.sh}"

    local tmp
    tmp="$(mktemp "${TMPDIR:-/tmp}/spartan_installer.XXXXXX")" || spartan_fail "Cannot create a temporary file."
    chmod 600 "$tmp"
    printf 'Downloading the DezerX Spartan installer %s...\n' "${SPARTAN_RELEASE_TAG:-(latest)}"
    if ! spartan_download "$url" "$tmp" || [ ! -s "$tmp" ]; then
        rm -f "$tmp"
        spartan_fail "Download failed: ${url}"
    fi

    if [ -z "$expected" ]; then
        local sumfile="${tmp}.sha256"
        if spartan_download "${url}.sha256" "$sumfile" 2>/dev/null; then
            expected="$(cut -d' ' -f1 <"$sumfile")"
        fi
        rm -f "$sumfile"
    fi
    if [ -n "$expected" ]; then
        local actual
        actual="$(spartan_sha256 "$tmp")"
        if [ "$actual" != "$expected" ]; then
            rm -f "$tmp"
            spartan_fail "Checksum mismatch for the downloaded installer (expected ${expected}, got ${actual}). Nothing was changed."
        fi
    fi

    export SPARTAN_BUNDLE_TMP="$tmp"
    spartan_exec bash "$tmp" "$@"
}

spartan_bootstrap "$@"
