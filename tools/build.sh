#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="$(tr -d '[:space:]' <"${root}/VERSION")"
tag="v${version}"
repo="dezerx-spartan/SPARTAN-INSTALLER"

while (($#)); do
    case "$1" in
        --tag) tag="$2"; shift 2 ;;
        --repo) repo="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

dist="${root}/dist"
bundle="${dist}/spartan_installer.bundle.sh"
mkdir -p "$dist"

{
    echo '#!/usr/bin/env bash'
    echo 'if [ -n "${SPARTAN_BUNDLE_TMP:-}" ]; then rm -f -- "$SPARTAN_BUNDLE_TMP"; unset SPARTAN_BUNDLE_TMP; fi'
    echo 'if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then'
    echo '    echo "The DezerX Spartan installer needs bash 4.4 or newer." >&2'
    echo '    exit 1'
    echo 'fi'
    echo "SPARTAN_VERSION=\"${version}\""
    echo "SPARTAN_RELEASE_REPO=\"${repo}\""
    echo "SPARTAN_BUNDLED=1"
    while IFS= read -r module || [[ -n "$module" ]]; do
        [[ -z "$module" || "$module" == \#* ]] && continue
        echo
        cat "${root}/src/${module}"
    done <"${root}/src/modules.list"
    echo
    echo 'spartan_main "$@"'
} >"$bundle"
chmod 755 "$bundle"
bash -n "$bundle"

sha="$(sha256sum "$bundle" | cut -d' ' -f1)"
echo "${sha}  spartan_installer.bundle.sh" >"${bundle}.sha256"

loader="${dist}/spartan_installer.sh"
sed -e "s|^SPARTAN_RELEASE_TAG=\"\"|SPARTAN_RELEASE_TAG=\"${tag}\"|" \
    -e "s|^SPARTAN_RELEASE_REPO=\"[^\"]*\"|SPARTAN_RELEASE_REPO=\"${repo}\"|" \
    -e "s|^SPARTAN_BUNDLE_SHA256=\"\"|SPARTAN_BUNDLE_SHA256=\"${sha}\"|" \
    "${root}/spartan_installer.sh" >"$loader"
chmod 755 "$loader"
bash -n "$loader"
grep -q "^SPARTAN_BUNDLE_SHA256=\"${sha}\"" "$loader" || { echo "Failed to pin the bootstrap." >&2; exit 1; }

size="$(stat -c %s "$loader")"
if ((size > 65536)); then
    echo "The bootstrap is ${size} bytes; keep it well under 128 KiB for bash -c \"\$(curl ...)\"." >&2
    exit 1
fi

printf 'Built %s (%s)\n' "$version" "$tag"
printf '  %-44s %s bytes\n' "dist/spartan_installer.sh" "$size"
printf '  %-44s %s bytes\n' "dist/spartan_installer.bundle.sh" "$(stat -c %s "$bundle")"
printf '  sha256 %s\n' "$sha"
