INTERACTIVE=0
UI_MODE="plain"
LOCK_FD=""
SPARTAN_MAIN_PID=$$
declare -a ROLLBACK_WARNINGS=()
declare -a SUMMARY_LINES=()
SUMMARY_TITLE=""
SUMMARY_OK=1

core_locale() {
    local l have_list
    have_list="$(locale -a 2>/dev/null)"
    for l in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
        if grep -qix -- "$l" <<<"$have_list"; then
            export LC_ALL="$l"
            return 0
        fi
    done
    export LC_ALL=C
}

need_root() {
    [[ $EUID -eq 0 ]] && return 0
    printf 'Please run the installer as root, for example:\n  sudo bash spartan_installer.sh\n' >&2
    exit 1
}

lock_acquire() {
    exec {LOCK_FD}>"$RUN_LOCK" || return 0
    if ! flock -n "$LOCK_FD"; then
        printf 'Another DezerX Spartan installer is already running on this server.\n' >&2
        return 1
    fi
}

run_dir_init() {
    RUN_DIR="$(mktemp -d "${WORK_BASE}/spartan-installer.XXXXXX")" || {
        echo "Cannot create a work directory in ${WORK_BASE}." >&2
        exit 1
    }
    chmod 700 "$RUN_DIR"
    cleanup_add "$RUN_DIR"
}

ui_mode_init() {
    ui_theme_init
    if ((NONINTERACTIVE)) || ! term_open; then
        INTERACTIVE=0
        if [[ -t 1 ]]; then UI_MODE="line"; else UI_MODE="plain"; fi
    else
        INTERACTIVE=1
        term_size
        if ((FORCE_PLAIN)) || [[ "${TERM:-dumb}" == dumb ]] || ((TERM_COLS < 70 || TERM_ROWS < 20)); then
            UI_MODE="line"
        else
            UI_MODE="tui"
        fi
    fi
    [[ "$UI_MODE" == plain ]] && UI_DEPTH=0
    line_styles_init
}

ui_start() {
    if [[ "$UI_MODE" == tui ]]; then
        term_enter
        ui_force_redraw
    else
        printf '\n%s%s %s%s\n' "$L_A" "$TITLE" "$SPARTAN_VERSION" "$L_R" >&"$UI_FD"
    fi
}

ui_stop() {
    ticker_stop
    [[ "$UI_MODE" == tui ]] && term_leave
}

spartan_exit() {
    local code="${1:-0}" reason="${2:-}"
    trap - EXIT HUP TERM INT
    ui_stop
    if [[ "$reason" == cancelled ]]; then
        printf '%s\n' "Installer closed. Nothing was changed." >&"${UI_FD:-1}"
    fi
    swap_temp_off >/dev/null 2>&1
    cleanup_run
    log_close "$code"
    exit "$code"
}

spartan_on_exit() {
    local code="$1"
    trap - EXIT
    ui_stop
    if ((code != 0)); then
        printf '\nThe installer stopped unexpectedly (exit code %s). Details: %s\n' "$code" "$LOG" 1>&"${UI_FD:-2}" 2>/dev/null
        if ((APP_IN_MAINTENANCE)); then
            artisan up >/dev/null 2>&1
        fi
    fi
    swap_temp_off >/dev/null 2>&1
    cleanup_run
    log_close "$code"
}

spartan_on_hup() {
    if ((PLAN_RUNNING)); then
        log "Terminal disconnected; continuing without output."
        ticker_stop
        TERM_ACTIVE=0
        exec {TTY_FD}>/dev/null {UI_FD}>/dev/null
        UI_MODE="plain"
        return 0
    fi
    spartan_exit 129 "hangup"
}

spartan_on_term() {
    log "Received SIGTERM."
    if ((PLAN_RUNNING)); then
        echo force >"$ABORT_FILE"
        return 0
    fi
    spartan_exit 143
}

CHOICE_VARS=(APP_DIR USED_APP_DIR DOMAIN LICENSE_KEY PRODUCT_ID PRODUCT_NAME WEB DB_ENGINE DB_HOST DB_PORT DB_NAME
    DB_USER DB_PASS DB_ROOT_PASS DB_PASS_GENERATED SSL_MODE SSL_EMAIL OCTANE_ENABLED OCTANE_CHOICE OCTANE_PORT
    OCTANE_WORKERS QUEUE_WORKERS KEEP_NGINX KEEP_CSS KEEP_THEMES KEEP_PORTALS KEEP_EMAILS KEEP_FAVICON OVERWRITE
    INSTALLED_VERSION AVAILABLE_VERSION LICENSE_DOMAIN RM_FINAL_BACKUP RM_DATABASE RM_BACKUPS RM_CERT)
CHOICES_SNAPSHOT=""

choices_save() { CHOICES_SNAPSHOT="$(declare -p "${CHOICE_VARS[@]}" 2>/dev/null | sed 's/^declare /declare -g /')"; }

choices_restore() {
    [[ -n "$CHOICES_SNAPSHOT" ]] || return 0
    eval "$CHOICES_SNAPSHOT"
}

wizard_run() {
    local -a screens=("$@")
    local i=0 dir=1 rc n=${#screens[@]}
    while ((i >= 0 && i < n)); do
        local s="${screens[i]}"
        if declare -F "${s}_applies" >/dev/null && ! "${s}_applies"; then
            i=$((i + dir))
            continue
        fi
        local pos=0 total=0 k
        for ((k = 0; k < n; k++)); do
            if declare -F "${screens[k]}_applies" >/dev/null && ! "${screens[k]}_applies"; then continue; fi
            total=$((total + 1))
            ((k <= i)) && pos=$((pos + 1))
        done
        UI_STEP="${pos}/${total}"
        "$s"
        rc=$?
        case "$rc" in
            0) dir=1 i=$((i + 1)) ;;
            1) dir=-1 i=$((i - 1)) ;;
            255) spartan_exit 1 "hangup" ;;
            *) return "$rc" ;;
        esac
    done
    UI_STEP=""
    ((i >= n))
}

startup_checks() {
    db_server_detect || true
    app_detect || true
    preflight_run
}

screen_menu() {
    UI_STEP="" UI_FLOW=""
    local text="Welcome to the DezerX Spartan installer. What would you like to do?"
    local def="install"
    if [[ -n "$DETECTED_APP_DIR" ]]; then
        text+="\n\n{d}Installed:{/} DezerX Spartan ${DETECTED_VERSION:-} at {b}$(tx "$DETECTED_APP_DIR"){/}"
        [[ -n "$DETECTED_DOMAIN" ]] && text+=" {d}(${DETECTED_DOMAIN}){/}"
        def="update"
    fi
    UI_LIST_BACK="Quit" UI_LIST_NEXT="Select ${G_NEXT}"
    ui_menu "DezerX Spartan" "$text" "$def" \
        install "Install" "Set up DezerX Spartan on this server" \
        update "Update" "Update an installation to the latest release" \
        uninstall "Uninstall" "Remove DezerX Spartan from this server" \
        tools "Tools" "Permissions, SSL, health check, support bundle"
    local rc=$?
    UI_LIST_BACK="" UI_LIST_NEXT=""
    return "$rc"
}

PICK_TITLE="Installation"

_validate_existing_dir() {
    local d="${FORM_VALUES[0]%/}"
    if [[ "$d" != /* ]]; then
        FORM_ERROR="Enter an absolute path, for example ${APP_DEFAULT_DIR}."
        return 1
    fi
    if ! app_looks_like_spartan "$d"; then
        FORM_ERROR="No DezerX Spartan installation in ${d} (artisan and .env are needed)."
        return 1
    fi
    FORM_VALUES[0]="$d"
    return 0
}

screen_pick_install() {
    local def="${DETECTED_APP_DIR:-$APP_DIR}"
    ((USED_APP_DIR)) && def="$APP_DIR"
    local text="Which installation? The directory that contains artisan and .env."
    [[ -n "$DETECTED_APP_DIR" ]] && text+="\n\n{d}Found:{/} $(tx "$DETECTED_APP_DIR") {d}${DETECTED_DOMAIN:+(${DETECTED_DOMAIN})}{/}"
    form_reset
    form_add "Directory" "$def" text "Tab moves to the buttons; Enter continues"
    FORM_VALIDATE=_validate_existing_dir
    ui_form "$PICK_TITLE" "$text" || return $?
    APP_DIR="${FORM_VALUES[0]}"
    return 0
}

site_scheme() {
    if [[ "$(env_read_value APP_URL)" == https://* ]]; then echo https; else echo http; fi
}

smoke_test() {
    local scheme port code i
    scheme="$(site_scheme)"
    port=80
    [[ "$scheme" == https ]] && port=443
    for i in 1 2 3 4 5; do
        code="$(curl -sk -o /dev/null -m 15 -w '%{http_code}' --resolve "${DOMAIN}:${port}:127.0.0.1" "${scheme}://${DOMAIN}/" 2>/dev/null)"
        if [[ "$code" =~ ^[23] ]]; then
            echo "The site answers HTTP ${code}."
            return 0
        fi
        echo "Attempt ${i}: HTTP ${code:-000}, retrying."
        sleep 3
    done
    echo "The site answered HTTP ${code:-000}. Check /var/log/nginx/dezerx.app-error.log and ${APP_DIR}/storage/logs/."
    return 1
}

summary_reset() {
    SUMMARY_TITLE="$1"
    SUMMARY_OK="${2:-1}"
    SUMMARY_LINES=()
}

summary_add() { SUMMARY_LINES+=("$1"); }

summary_kv() {
    local k="$1" v="$2"
    [[ -n "$v" ]] || return 0
    local pad
    printf -v pad '%-13s' "$k"
    SUMMARY_LINES+=("  {d}${pad}{/}$(tx "$v")")
}

summary_text() {
    local out="" l
    for l in "${SUMMARY_LINES[@]}"; do out+="${l}"$'\n'; done
    printf '%s' "${out%$'\n'}"
}

summary_warnings_text() {
    local out="" w
    for w in "${WARNINGS[@]}"; do out+="- $(tx "$w")"$'\n'; done
    printf '%s' "${out%$'\n'}"
}

summary_show() {
    local text
    text="$(summary_text)"
    if ((${#WARNINGS[@]})); then
        text+="\n\n{w}${G_WARN} ${#WARNINGS[@]} warning(s):{/}\n$(summary_warnings_text)"
    fi
    text+="\n\n{d}Log: ${LOG}{/}"
    if [[ "$UI_MODE" == tui ]]; then
        UI_STEP=""
        if ((SUMMARY_OK)); then
            ui_msgbox "$SUMMARY_TITLE" "$text" "Finish"
        else
            ui_error "$SUMMARY_TITLE" "$text" "Close"
        fi
    fi
    SUMMARY_FINAL_TEXT="$text"
}

summary_print_plain() {
    [[ -n "${SUMMARY_FINAL_TEXT:-}" ]] || return 0
    local mark="" col="$L_OK"
    ((SUMMARY_OK)) || { mark="${G_FAIL} "; col="$L_E"; }
    printf '\n%s%s%s%s\n' "$col" "$mark" "$(text_strip "$SUMMARY_TITLE")" "$L_R" >&"$UI_FD"
    line_text "$SUMMARY_FINAL_TEXT"
    printf '\n' >&"$UI_FD"
}

show_failure() {
    local title="$1" note="$2" tail
    tail="$(task_fail_tail 12)"
    local text
    text="{e}${G_FAIL}{/} $(tx "$(plan_fail_reason)")"
    [[ -n "$tail" ]] && text+="\n\n{d}Last output:{/}\n$(tx "$tail" | sed 's/^/  /')"
    [[ -n "$note" ]] && text+="\n\n${note}"
    summary_reset "$title" 0
    summary_add "$text"
}
