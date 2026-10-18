# shellcheck shell=bash
# The progress view used while a plan runs: one row per phase with its state
# and time, the task that is running right now, its latest output line and an
# overall progress bar.
#
#   ✔ Preparing the system                                   12s
#   ⠼ Installing PHP 8.4                                      41s
#   ○ Installing Nginx
#   ...
#   Installing PHP extensions · 18s
#   Setting up php8.4-intl (8.4.13-1) ...
#   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━──────────────────────  34%

PROG_TITLE=""
declare -a PROG_IDS=() PROG_LABELS=() PROG_STATE=() PROG_DUR=() PROG_WEIGHT=()
PROG_CUR=-1
PROG_PHASE_T0=0
PROG_NOTICE=""

# Geometry of the moving parts (set by _prog_layout)
PROG_FIRST=0 PROG_VIS=0 PROG_ROW0=0 PROG_TASK_ROW=0 PROG_BAR_ROW=0

progress_reset() {
    PROG_TITLE="$1"
    PROG_IDS=() PROG_LABELS=() PROG_STATE=() PROG_DUR=() PROG_WEIGHT=()
    PROG_CUR=-1
    PROG_NOTICE=""
}

progress_add() {
    PROG_IDS+=("$1")
    PROG_LABELS+=("$2")
    PROG_WEIGHT+=("${3:-5}")
    PROG_STATE+=("pending")
    PROG_DUR+=("")
}

progress_percent() {
    local total=0 done_w=0 i
    for i in "${!PROG_IDS[@]}"; do
        total=$((total + PROG_WEIGHT[i]))
        case "${PROG_STATE[i]}" in
            ok | warn | skip | fail) done_w=$((done_w + PROG_WEIGHT[i])) ;;
        esac
    done
    ((total > 0)) || { echo 0; return; }
    echo $((done_w * 100 / total))
}

_prog_layout() {
    local n=${#PROG_IDS[@]}
    ui_layout_dialog $((n + 5)) "$UI_WIDTH"
    PROG_VIS=$((DLG_IH - 5))
    ((PROG_VIS > n)) && PROG_VIS=$n
    ((PROG_VIS < 1)) && PROG_VIS=1
    PROG_FIRST=0
    if ((PROG_CUR >= 0 && n > PROG_VIS)); then
        PROG_FIRST=$((PROG_CUR - PROG_VIS / 2))
        ((PROG_FIRST < 0)) && PROG_FIRST=0
        ((PROG_FIRST > n - PROG_VIS)) && PROG_FIRST=$((n - PROG_VIS))
    fi
    PROG_ROW0=$DLG_IR
    PROG_TASK_ROW=$((DLG_IR + PROG_VIS + 1))
    PROG_BAR_ROW=$((PROG_TASK_ROW + 3))
}

_prog_phase_row() {
    local i="$1" frame="${2:-0}" row
    row=$((PROG_ROW0 + i - PROG_FIRST))
    local icon st lst="$S_PANEL" dur="${PROG_DUR[i]}"
    case "${PROG_STATE[i]}" in
        pending) icon="$G_PENDING" st="$S_DIM" lst="$S_MUTED" ;;
        run)
            icon="${G_SPIN[frame % ${#G_SPIN[@]}]}" st="$S_ACCENT" lst="$S_BOLD"
            dur="$(fmt_duration $(($(now) - PROG_PHASE_T0)))"
            ;;
        ok) icon="$G_OK" st="$S_OK" ;;
        warn) icon="$G_WARN" st="$S_WARN" ;;
        fail) icon="$G_FAIL" st="$S_ERR" lst="$S_ERR" ;;
        skip) icon="$G_SKIP" st="$S_DIM" lst="$S_DIM" ;;
    esac
    local label="${PROG_LABELS[i]}"
    [[ "${PROG_STATE[i]}" == skip ]] && label+=" (skipped)"
    text_trunc "$label" $((DLG_IW - 12))
    fb_rect "$row" "$DLG_IC" 1 "$DLG_IW" "$S_PANEL"
    fb_text "$row" "$DLG_IC" "$st" "$icon"
    fb_text "$row" $((DLG_IC + 2)) "$lst" "$TEXT_OUT"
    [[ -n "$dur" ]] && fb_text "$row" $((DLG_IC + DLG_IW - ${#dur})) "$S_MUTED" "$dur"
}

_prog_task_area() {
    local t0="" desc="" out=""
    if [[ -n "$TASK_STATE_FILE" && -s "$TASK_STATE_FILE" ]]; then
        IFS=$'\t' read -r t0 desc out <"$TASK_STATE_FILE"
    fi
    fb_rect "$PROG_TASK_ROW" "$DLG_IC" 2 "$DLG_IW" "$S_PANEL"
    if [[ -n "$PROG_NOTICE" ]]; then
        text_trunc "$PROG_NOTICE" "$DLG_IW"
        fb_text "$PROG_TASK_ROW" "$DLG_IC" "$S_WARN" "$TEXT_OUT"
    elif [[ -e "$ABORT_FILE" ]]; then
        text_trunc "Stopping after this step${G_ELLIPSIS} press Ctrl+C again to stop now" "$DLG_IW"
        fb_text "$PROG_TASK_ROW" "$DLG_IC" "$S_WARN" "$TEXT_OUT"
    elif [[ -n "$desc" ]]; then
        local el=""
        [[ -n "$t0" ]] && el=" ${G_DOT} $(fmt_duration $(($(now) - t0)))"
        text_trunc "$desc" $((DLG_IW - ${#el}))
        fb_text "$PROG_TASK_ROW" "$DLG_IC" "$S_PANEL" "${TEXT_OUT}"
        fb_text "$PROG_TASK_ROW" $((DLG_IC + ${#TEXT_OUT})) "$S_MUTED" "$el"
    fi
    if [[ -n "$out" ]]; then
        tick_last_line "$out"
        if [[ -n "$TICK_LAST" ]]; then
            text_trunc "$TICK_LAST" "$DLG_IW"
            fb_text $((PROG_TASK_ROW + 1)) "$DLG_IC" "$S_DIM" "$TEXT_OUT"
        fi
    fi
}

_prog_bar() {
    local pct w filled bar_on bar_off
    pct="$(progress_percent)"
    w=$((DLG_IW - 5))
    filled=$((w * pct / 100))
    printf -v bar_on '%*s' "$filled" ''
    printf -v bar_off '%*s' $((w - filled)) ''
    fb_text "$PROG_BAR_ROW" "$DLG_IC" "$S_BAR" "${bar_on// /$G_BAR_ON}"
    fb_text "$PROG_BAR_ROW" $((DLG_IC + filled)) "$S_BAR_BG" "${bar_off// /$G_BAR_OFF}"
    local p="${pct}%"
    fb_text "$PROG_BAR_ROW" $((DLG_IC + DLG_IW - ${#p})) "$S_BOLD" "$p"
}

progress_draw_full() {
    [[ "$UI_MODE" == tui ]] || return 0
    _prog_layout
    UI_HINTS="${PROG_HINTS:-Ctrl+C stops after the current step}"
    ui_force_redraw
    ui_frame_begin
    ui_draw_box "$PROG_TITLE"
    local i
    for ((i = PROG_FIRST; i < PROG_FIRST + PROG_VIS; i++)); do _prog_phase_row "$i" 0; done
    _prog_task_area
    _prog_bar
    ui_frame_end
}

# Ticker callback: redraws only what moves.
_prog_tick() {
    local frame="$1"
    if ((frame < 0)); then
        progress_draw_full
        return
    fi
    FB=""
    ((PROG_CUR >= PROG_FIRST && PROG_CUR < PROG_FIRST + PROG_VIS)) && _prog_phase_row "$PROG_CUR" "$frame"
    ((frame % 3 == 0)) && _prog_task_area
    fb_flush
}

# ---------------------------------------------------------------------------
# Line and plain output
# ---------------------------------------------------------------------------

LINE_TASK_DESC=""
LINE_TASK_T0=0

_line_tick() {
    local frame="$1"
    ((frame < 0)) && return
    local t0="" desc="" out=""
    [[ -s "$TASK_STATE_FILE" ]] && IFS=$'\t' read -r t0 desc out <"$TASK_STATE_FILE"
    [[ -n "$desc" ]] || return
    local g="${G_SPIN[frame % ${#G_SPIN[@]}]}" el=""
    [[ -n "$t0" ]] && el="$(fmt_duration $(($(now) - t0)))"
    local cols=${TERM_COLS:-80} tail=""
    if ((frame % 3 == 0)) && [[ -n "$out" ]]; then
        tick_last_line "$out"
        tail="$TICK_LAST"
    fi
    local text="${desc} ${el}"
    text_trunc "$text" $((cols - 8))
    local line="$TEXT_OUT"
    if [[ -n "$tail" ]] && ((cols - 10 - ${#line} > 12)); then
        text_trunc "$tail" $((cols - 10 - ${#line}))
        printf '\r\e[K    %s%s%s %s %s%s%s' "$L_A" "$g" "$L_R" "$line" "$L_D" "$TEXT_OUT" "$L_R" >&"$UI_FD"
    else
        printf '\r\e[K    %s%s%s %s' "$L_A" "$g" "$L_R" "$line" >&"$UI_FD"
    fi
}

# ---------------------------------------------------------------------------
# Hooks used by the plan runner
# ---------------------------------------------------------------------------

ui_plan_begin() {
    case "$UI_MODE" in
        tui) progress_draw_full ;;
        line) printf '\n%s%s%s\n' "$L_A" "$PROG_TITLE" "$L_R" >&"$UI_FD" ;;
        *) lp "== ${PROG_TITLE}" ;;
    esac
}

ui_phase_begin() {
    local i="$1"
    PROG_CUR=$i
    PROG_STATE[i]="run"
    PROG_PHASE_T0=$(now)
    task_state_write "" "" ""
    case "$UI_MODE" in
        tui)
            progress_draw_full
            ticker_start _prog_tick
            ;;
        line) printf '\n  %s%s%s %s%s%s\n' "$L_A" "$G_BULLET" "$L_R" "$L_B" "${PROG_LABELS[i]}" "$L_R" >&"$UI_FD" ;;
        *) lp "==> ${PROG_LABELS[i]}" ;;
    esac
}

ui_phase_end() {
    local i="$1" state="$2"
    [[ "$UI_MODE" == tui ]] && ticker_stop
    PROG_STATE[i]="$state"
    PROG_DUR[i]="$(fmt_duration $(($(now) - PROG_PHASE_T0)))"
    case "$UI_MODE" in
        tui) task_state_write "" "" "" && progress_draw_full ;;
        line)
            case "$state" in
                skip) printf '    %s%s skipped%s\n' "$L_D" "$G_SKIP" "$L_R" >&"$UI_FD" ;;
            esac
            ;;
        *) [[ "$state" == skip ]] && lp "    skipped" ;;
    esac
}

ui_task_begin() {
    LINE_TASK_DESC="$1"
    LINE_TASK_T0=$(now)
    [[ "$UI_MODE" == line ]] && ticker_start _line_tick
}

ui_task_end() {
    local desc="$1" rc="$2" dur
    dur="$(fmt_duration $(($(now) - LINE_TASK_T0)))"
    case "$UI_MODE" in
        line)
            ticker_stop
            if ((rc == 0)); then
                printf '\r\e[K    %s%s%s %s %s(%s)%s\n' "$L_OK" "$G_OK" "$L_R" "$desc" "$L_D" "$dur" "$L_R" >&"$UI_FD"
            else
                printf '\r\e[K    %s%s%s %s %s(failed)%s\n' "$L_E" "$G_FAIL" "$L_R" "$desc" "$L_E" "$L_R" >&"$UI_FD"
            fi
            ;;
        plain)
            if ((rc == 0)); then lp "  [ ok ] ${desc} (${dur})"; else lp "  [FAIL] ${desc}"; fi
            ;;
    esac
}

# ui_task_note <message> - a warning line while a plan runs (line/plain only;
# the full-screen view shows warnings on the phase and at the end).
ui_task_note() {
    case "$UI_MODE" in
        line) printf '\r\e[K    %s%s %s%s\n' "$L_W" "$G_WARN" "$1" "$L_R" >&"$UI_FD" ;;
        plain) lp "  [warn] $1" ;;
    esac
}
