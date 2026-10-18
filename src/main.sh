#!/usr/bin/env bash
# DezerX Spartan Installer - entry point for running from a git checkout.
#
# Release builds inline every module listed in modules.list into one file
# (see tools/build.sh), so this loader is only used during development and by
# `sudo bash spartan_installer.sh` inside a cloned repository.

if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ] ||
    { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
    echo "The DezerX Spartan installer needs bash 4.4 or newer." >&2
    exit 1
fi

SPARTAN_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${SPARTAN_VERSION:-}" && -r "${SPARTAN_SRC}/../VERSION" ]]; then
    read -r SPARTAN_VERSION <"${SPARTAN_SRC}/../VERSION"
    SPARTAN_VERSION="${SPARTAN_VERSION}-dev"
fi

while IFS= read -r _spartan_module || [[ -n "$_spartan_module" ]]; do
    [[ -z "$_spartan_module" || "$_spartan_module" == \#* ]] && continue
    # shellcheck source=/dev/null
    source "${SPARTAN_SRC}/${_spartan_module}" || {
        echo "Failed to load installer module ${_spartan_module}" >&2
        exit 1
    }
done <"${SPARTAN_SRC}/modules.list"
unset _spartan_module

spartan_main "$@"
