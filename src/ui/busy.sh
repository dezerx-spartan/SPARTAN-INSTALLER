TICKER_PID=""
TASK_STATE_FILE=""
ABORT_FILE=""

ticker_files_init() {
    TASK_STATE_FILE="${RUN_DIR}/task.state"
    ABORT_FILE="${RUN_DIR}/abort"
    : >"$TASK_STATE_FILE"
}

task_state_write() {
    [[ -n "$TASK_STATE_FILE" ]] || return 0
    printf '%s\t%s\t%s\n' "$1" "$2" "$3" >"$TASK_STATE_FILE"
}

abort_requested() { [[ -n "$ABORT_FILE" && -e "$ABORT_FILE" ]]; }

_ticker_ctrl_c() {
    if [[ -e "$ABORT_FILE" ]]; then
        echo force >"$ABORT_FILE"
        local p
        for p in $(ps -o pid= --ppid "$SPARTAN_MAIN_PID" 2>/dev/null); do
            [[ "$p" == "$BASHPID" ]] && continue
            kill -TERM "$p" 2>/dev/null
        done
    else
        echo stop >"$ABORT_FILE"
    fi
}

ticker_start() {
    ticker_stop
    local fn="$1"
    (
        trap 'exit 0' TERM
        trap 'TERM_RESIZED=1' WINCH
        trap '' INT HUP
        local frame=0 k sfd
        exec {sfd}<> <(:)
        while :; do
            if ((TERM_RESIZED)); then
                TERM_RESIZED=0
                term_size
                "$fn" -1
            fi
            "$fn" "$frame"
            frame=$((frame + 1))
            if [[ "$UI_MODE" == tui && -n "$TTY_FD" ]]; then
                k=""
                IFS= read -r -t 0.1 k <&"$TTY_FD" 2>/dev/null
                [[ "$k" == *$'\x03'* ]] && _ticker_ctrl_c
            else
                read -r -t 0.1 -u "$sfd" k 2>/dev/null
            fi
        done
    ) &
    TICKER_PID=$!
}

ticker_stop() {
    [[ -n "$TICKER_PID" ]] || return 0
    kill -TERM "$TICKER_PID" 2>/dev/null
    wait "$TICKER_PID" 2>/dev/null
    TICKER_PID=""
}

tick_last_line() {
    TICK_LAST=""
    [[ -s "$1" ]] || return 0
    TICK_LAST="$(tail -c 2048 "$1" 2>/dev/null | tr '\r' '\n' | awk '
        { gsub(/\033\[[0-9;?]*[ -\/]*[@-~]/, ""); gsub(/[^[:print:]\t]/, ""); gsub(/\t/, " ") }
        NF { last = $0 }
        END { sub(/^[ ]+/, "", last); print last }')"
}

BUSY_MSG=""
BUSY_ROW=0
BUSY_COL=0

_busy_render() {
    local frame="$1"
    case "$UI_MODE" in
        tui)
            if ((frame < 0)); then
                _busy_draw_full
                return
            fi
            local g="${G_SPIN[frame % ${#G_SPIN[@]}]}"
            printf '\e[%d;%dH%s%s' "$BUSY_ROW" "$BUSY_COL" "$S_ACCENT" "$g" >&"$TTY_FD"
            ;;
        line)
            ((frame < 0)) && return
            local g="${G_SPIN[frame % ${#G_SPIN[@]}]}"
            printf '\r  %s%s%s %s' "$L_A" "$g" "$L_R" "$BUSY_MSG" >&"$UI_FD"
            ;;
    esac
}

_busy_draw_full() {
    ui_layout_dialog 1 "$UI_WIDTH_SMALL"
    UI_HINTS="Please wait${G_ELLIPSIS}"
    ui_force_redraw
    ui_frame_begin
    ui_draw_box "Please wait"
    text_trunc "$BUSY_MSG" $((DLG_IW - 3))
    BUSY_ROW=$DLG_IR
    BUSY_COL=$DLG_IC
    fb_text "$DLG_IR" $((DLG_IC + 2)) "$S_PANEL" "$TEXT_OUT"
    fb_text "$DLG_IR" "$DLG_IC" "$S_ACCENT" "${G_SPIN[0]}"
    ui_frame_end
}

ui_busy() {
    BUSY_MSG="$1"
    shift
    local out="${RUN_DIR:-/tmp}/busy.out" rc
    log "Check: ${BUSY_MSG}"
    case "$UI_MODE" in
        tui)
            _busy_draw_full
            ticker_start _busy_render
            ;;
        line) ticker_start _busy_render ;;
        *) lp "  ${BUSY_MSG}" ;;
    esac
    "$@" >"$out" 2>&1 </dev/null
    rc=$?
    ticker_stop
    log_file "$out"
    if [[ "$UI_MODE" == tui ]] && ((!PLAN_RUNNING)) && abort_requested; then
        rm -f "$ABORT_FILE"
        ui_confirm_quit
    fi
    if [[ "$UI_MODE" == line ]]; then
        if ((rc == 0)); then
            printf '\r\e[K  %s%s%s %s\n' "$L_A" "$G_DONE" "$L_R" "$BUSY_MSG" >&"$UI_FD"
        else
            printf '\r\e[K  %s%s%s %s\n' "$L_E" "$G_FAIL" "$L_R" "$BUSY_MSG" >&"$UI_FD"
        fi
    fi
    ui_force_redraw
    return "$rc"
}
