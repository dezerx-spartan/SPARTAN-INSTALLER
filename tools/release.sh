#!/usr/bin/env bash
# Builds dist/ and uploads it as a GitHub release (draft unless --publish).
#
# Usage: GITHUB_TOKEN=... tools/release.sh [--publish] [--repo owner/name] [--tag vX.Y.Z]

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="$(tr -d '[:space:]' <"${root}/VERSION")"
tag="v${version}"
repo="dezerx-spartan/SPARTAN-INSTALLER-NEW"
draft=true

while (($#)); do
    case "$1" in
        --publish) draft=false; shift ;;
        --repo) repo="$2"; shift 2 ;;
        --tag) tag="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

: "${GITHUB_TOKEN:?Set GITHUB_TOKEN to a token with repo scope.}"
command -v jq >/dev/null || { echo "jq is required." >&2; exit 1; }

bash "${root}/tools/build.sh" --tag "$tag" --repo "$repo"

api() {
    curl -fsS -H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" "$@"
}

notes="$(awk -v v="## ${version}" '$0 == v { on = 1; next } /^## / && on { exit } on' "${root}/CHANGELOG.md")"
[[ -n "$notes" ]] || notes="DezerX Spartan Installer ${version}"

release="$(api -X POST "https://api.github.com/repos/${repo}/releases" \
    -d "$(jq -n --arg tag "$tag" --arg name "$version" --arg body "$notes" --argjson draft "$draft" \
        '{tag_name: $tag, name: $name, body: $body, draft: $draft}')")"
id="$(jq -r .id <<<"$release")"
[[ "$id" =~ ^[0-9]+$ ]] || { echo "Creating the release failed: ${release}" >&2; exit 1; }

for f in spartan_installer.sh spartan_installer.bundle.sh spartan_installer.bundle.sh.sha256; do
    api -X POST -H "Content-Type: application/octet-stream" --data-binary @"${root}/dist/${f}" \
        "https://uploads.github.com/repos/${repo}/releases/${id}/assets?name=${f}" >/dev/null
    echo "Uploaded ${f}"
done

echo "Release ${tag}: $(jq -r .html_url <<<"$release")$([[ "$draft" == true ]] && echo " (draft)")"
