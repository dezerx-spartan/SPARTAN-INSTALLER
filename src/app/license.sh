LICENSE_MSG=""
DL_URL=""
DL_NAME=""
DL_SIZE=""
DL_EXPIRES=""

license_product_name() {
    case "$1" in
        1) echo "Spartan Starter" ;;
        5) echo "Spartan Professional" ;;
        6) echo "Spartan Ultimate" ;;
        *) echo "DezerX Spartan" ;;
    esac
}

license_apply_key() {
    local key
    key="$(trim "$1")"
    case "$key" in
        SPARTANSTARTER_?*) PRODUCT_ID="1" PRODUCT_NAME="Spartan Starter" ;;
        SPARTANPROFESSIONAL_?*) PRODUCT_ID="5" PRODUCT_NAME="Spartan Professional" ;;
        SPARTANULTIMATE_?*) PRODUCT_ID="6" PRODUCT_NAME="Spartan Ultimate" ;;
        SPARTANDEV_?*) PRODUCT_ID="6" PRODUCT_NAME="Spartan Developer" ;;
        *) return 1 ;;
    esac
    LICENSE_KEY="$key"
    secret_add "$LICENSE_KEY"
    return 0
}

license_masked() {
    local k="${1:-$LICENSE_KEY}"
    [[ -n "$k" ]] || return 0
    local prefix="${k%%_*}_"
    [[ "$prefix" == "${k}_" ]] && prefix=""
    printf '%s%s%s' "$prefix" "$G_ELLIPSIS" "${k: -4}"
}

_license_call() {
    local method="$1" url="$2" out="$3" ipopt code
    ipopt="$(license_curl_ip_opt)"
    local hdr="${RUN_DIR}/license.headers"
    (
        umask 077
        printf 'Authorization: Bearer %s\nX-Domain: %s\nX-Product-ID: %s\nContent-Type: application/json\nAccept: application/json\n' \
            "$LICENSE_KEY" "$DOMAIN" "$PRODUCT_ID" >"$hdr"
    )
    code="$(curl ${ipopt:+"$ipopt"} -sS -X "$method" --connect-timeout 15 --max-time 60 --retry 2 \
        -H @"$hdr" -o "$out" -w '%{http_code}' "$url" 2>/dev/null)" || code="000"
    rm -f "$hdr"
    printf '%s' "${code:-000}"
}

license_verify() {
    LICENSE_MSG=""
    local resp="${RUN_DIR}/license-verify.json" code
    code="$(_license_call GET "$LICENSE_API_VERIFY" "$resp")"
    log "License verify: HTTP ${code}"
    if [[ "$code" == 000 ]]; then
        LICENSE_MSG="Could not reach market.dezerx.com. Check the server's internet connection."
        return 1
    fi
    local success active msg
    success="$(json_get "$resp" .success)"
    active="$(json_get "$resp" .data.is_active)"
    msg="$(json_get "$resp" .message)"
    if [[ ! "$code" =~ ^2 || "$success" != true || "$active" != true ]]; then
        LICENSE_MSG="${msg:-The license server answered HTTP ${code}.}"
        [[ "$code" =~ ^2 ]] || LICENSE_MSG+=" (HTTP ${code})"
        log "License rejected: ${LICENSE_MSG}"
        return 1
    fi
    LICENSE_DOMAIN="$(json_get "$resp" .data.domain)"
    AVAILABLE_VERSION="$(json_get "$resp" .data.version)"
    local pname
    pname="$(json_get "$resp" .data.product_name)"
    [[ -n "$pname" ]] && PRODUCT_NAME="$pname"
    echo "License OK: ${PRODUCT_NAME} (product ${PRODUCT_ID})${LICENSE_DOMAIN:+, registered to ${LICENSE_DOMAIN}}${AVAILABLE_VERSION:+, latest version ${AVAILABLE_VERSION}}"
    return 0
}

license_request_download() {
    DL_URL=""
    local resp="${RUN_DIR}/license-download.json" code
    code="$(_license_call POST "$LICENSE_API_DOWNLOAD" "$resp")"
    log "License download link: HTTP ${code}"
    local success msg
    success="$(json_get "$resp" .success)"
    msg="$(json_get "$resp" .message)"
    DL_URL="$(json_get "$resp" .data.download_url)"
    DL_NAME="$(json_get "$resp" .data.product_name)"
    DL_SIZE="$(json_get "$resp" .data.file_size)"
    DL_EXPIRES="$(json_get "$resp" .data.expires_at)"
    if [[ ! "$code" =~ ^2 || "$success" != true || -z "$DL_URL" ]]; then
        echo "The license server did not return a download link: ${msg:-HTTP ${code}}"
        phase_fail "The license server did not return a download link: ${msg:-HTTP ${code}}"
        return 1
    fi
    secret_add "$DL_URL"
    echo "Download link received for ${DL_NAME:-DezerX Spartan}${DL_SIZE:+ ($(fmt_bytes "$DL_SIZE"))}."
}
