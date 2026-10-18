#!/usr/bin/env bash
# Syntax-checks every module and runs shellcheck on the built bundle (modules
# reference each other's functions and variables, so they are checked together).

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
status=0

while IFS= read -r m || [[ -n "$m" ]]; do
    [[ -z "$m" || "$m" == \#* ]] && continue
    bash -n "${root}/src/${m}" || status=1
done <"${root}/src/modules.list"
for f in spartan_installer.sh src/main.sh tools/*.sh tests/run.sh tests/unit/*.sh; do
    bash -n "${root}/${f}" || status=1
done

if ! command -v shellcheck >/dev/null 2>&1; then
    echo "shellcheck is not installed; only syntax was checked." >&2
    exit "$status"
fi

bash "${root}/tools/build.sh" >/dev/null
# SC2034: variables used in other modules; SC2317: functions defined for demo mode.
shellcheck -s bash -S warning -e SC2034,SC2317 "${root}/dist/spartan_installer.bundle.sh" || status=1
shellcheck -s bash -S warning -e SC2034 "${root}/spartan_installer.sh" "${root}/tools/"*.sh "${root}/tests/run.sh" || status=1
((status == 0)) && echo "Lint OK"
exit "$status"
