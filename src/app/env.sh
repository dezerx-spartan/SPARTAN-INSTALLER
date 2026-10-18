_env_format() {
    local key="$1" v="$2"
    if [[ ! "$v" =~ [^a-zA-Z0-9_./-] ]]; then
        printf '%s=%s' "$key" "$v"
    elif [[ "$v" == *'$'* && "$v" != *"'"* ]]; then
        printf "%s='%s'" "$key" "$v"
    else
        v="${v//\\/\\\\}"
        v="${v//\"/\\\"}"
        printf '%s="%s"' "$key" "$v"
    fi
}

env_write_value() {
    local key="$1" value="$2" file="${3:-${APP_DIR}/.env}" line
    line="$(_env_format "$key" "$value")"
    [[ -f "$file" ]] || : >"$file"
    if grep -qE "^${key}=" "$file"; then
        local tmp="${file}.spartan.$$"
        KEY="$key" LINE="$line" awk '
            BEGIN { k = ENVIRON["KEY"] "="; l = ENVIRON["LINE"]; done = 0 }
            index($0, k) == 1 { if (!done) { print l; done = 1 }; next }
            { print }' "$file" >"$tmp" && cat "$tmp" >"$file"
        rm -f "$tmp"
        log "[env] Updated ${key}"
    else
        [[ -s "$file" && -n "$(tail -c1 "$file")" ]] && printf '\n' >>"$file"
        printf '%s\n' "$line" >>"$file"
        log "[env] Added ${key}"
    fi
}

env_read_value() {
    local key="$1" file="${2:-${APP_DIR}/.env}" val
    [[ -f "$file" ]] || return 0
    val="$(grep -E "^${key}=" "$file" | head -n 1 | cut -d'=' -f2-)"
    val="$(trim "$val")"
    if [[ "$val" =~ ^\"(.*)\"$ ]]; then
        val="${BASH_REMATCH[1]}"
        val="${val//\\\"/\"}"
        val="${val//\\\\/\\}"
    elif [[ "$val" =~ ^\'(.*)\'$ ]]; then
        val="${BASH_REMATCH[1]}"
    else
        val="${val%%[[:space:]]#*}"
    fi
    printf '%s' "$val"
}

app_env_setup() {
    local env="${APP_DIR}/.env"
    if [[ ! -f "$env" && -f "${APP_DIR}/.env.example" ]]; then
        cp "${APP_DIR}/.env.example" "$env" || return 1
    elif [[ ! -f "$env" ]]; then
        : >"$env"
    fi
    chmod 640 "$env"
    env_write_value APP_NAME "DezerX Spartan"
    env_write_value APP_ENV production
    env_write_value APP_DEBUG false
    env_write_value APP_URL "http://${DOMAIN}"
    env_write_value DOMAIN "$DOMAIN"
    env_write_value LICENSE_KEY "$LICENSE_KEY"
    env_write_value PRODUCT_ID "$PRODUCT_ID"
    env_write_value DB_CONNECTION mysql
    env_write_value DB_HOST "$DB_HOST"
    env_write_value DB_PORT "$DB_PORT"
    env_write_value DB_DATABASE "$DB_NAME"
    env_write_value DB_USERNAME "$DB_USER"
    env_write_value DB_PASSWORD "$DB_PASS"
}

env_merge() {
    local env="${APP_DIR}/.env" tmpl="${APP_DIR}/.env.example"
    [[ -f "$tmpl" ]] || { echo "No .env.example in the release; .env left untouched."; return 0; }
    if [[ ! -f "$env" ]]; then
        cp "$tmpl" "$env"
        return 0
    fi
    local -A have=()
    local line key
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)= ]] && have[${BASH_REMATCH[2]}]=1
    done <"$env"

    local -a added=() lines=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)= ]] || continue
        key="${BASH_REMATCH[1]}"
        [[ -n "${have[$key]:-}" ]] && continue
        have[$key]=1
        case "$key" in
            CACHE_STORE | QUEUE_CONNECTION) line="${key}=database" ;;
        esac
        added+=("$key")
        lines+=("$line")
    done <"$tmpl"

    ((${#added[@]})) || { echo ".env already has every key from .env.example."; return 0; }
    local lead=""
    [[ -s "$env" && -n "$(tail -c1 "$env")" ]] && lead=$'\n'
    {
        printf '%s\n# Added by the DezerX Spartan installer %s on %s\n' "$lead" "$SPARTAN_VERSION" "$(date +%F)"
        printf '%s\n' "${lines[@]}"
    } >>"$env"
    echo "Added to .env: ${added[*]}"
}

app_get_var() {
    local env="${APP_DIR}/.env"
    [[ -f "$env" ]] || { phase_fail "${env} does not exist."; return 1; }
    DOMAIN="$(app_domain_of "$APP_DIR")"
    LICENSE_KEY="$(env_read_value LICENSE_KEY)"
    PRODUCT_ID="$(env_read_value PRODUCT_ID)"
    DB_HOST="$(env_read_value DB_HOST)"
    DB_PORT="$(env_read_value DB_PORT)"
    DB_NAME="$(env_read_value DB_DATABASE)"
    DB_USER="$(env_read_value DB_USERNAME)"
    DB_PASS="$(env_read_value DB_PASSWORD)"
    local conn
    conn="$(env_read_value DB_CONNECTION)"
    DB_HOST="${DB_HOST:-127.0.0.1}"
    DB_PORT="${DB_PORT:-3306}"
    case "$conn" in
        mysql | mariadb) DB_ENGINE="${DB_ENGINE:-$conn}" ;;
        *) DB_ENGINE="${DB_ENGINE:-mariadb}" ;;
    esac
    PRODUCT_NAME="$(license_product_name "$PRODUCT_ID")"
    secret_add "$LICENSE_KEY" "$DB_PASS"

    local missing=() k
    for k in DOMAIN LICENSE_KEY PRODUCT_ID DB_NAME DB_USER DB_PASS; do
        [[ -n "${!k}" ]] || missing+=("$k")
    done
    if ((${#missing[@]})); then
        phase_fail "The .env of ${APP_DIR} is missing: ${missing[*]}."
        return 1
    fi
    INSTALLED_VERSION="$(app_version_of "$APP_DIR")"
    [[ -n "$WEB" ]] || WEB="nginx"
    log "Loaded .env: domain=${DOMAIN} product=${PRODUCT_ID} db=${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
    return 0
}
