# shellcheck shell=bash
# Screen composition. Every frame is built in FB and written in one go so the
# screen never flickers, even over slow SSH links.
#
#   ┌ header  █▀▀▀▄ ▄▀▀  DezerX Spartan  Installer 2.0.0                        ┐
#   │         █   ▀▄▀    Website  https://dezerx.com                            │
#   │         █   ▄▀▄    Discord  https://discord.dezerx.com                    │
#   │         █▄▄▄▀ ▀▄▄  ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄  Step 2 of 7  │
#   │                                                                              │
#   │          INSTALLER                                                          │
#   │         ┌─────────────────────┤ Title ├─────────────────────┐              │
#   │         │ dialog                                             │▌             │
#   │         └────────────────────────────────────────────────────┘▌             │
#   │          ▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀              │
#   └ footer ─ key hints ──────────────────────────────────────────────────────────┘

FB=""
UI_STEP=""      # "2/7" while a wizard runs (wizard_run)
UI_FLOW=""      # Installer, Updater, ...: the tab above the dialogs
UI_HINTS=""
UI_BASE_KEY=""
UI_DANGER=0

# Dialog geometry (set by ui_layout_dialog)
DLG_R=0 DLG_C=0 DLG_H=0 DLG_W=0
DLG_IR=0 DLG_IC=0 DLG_IW=0 DLG_IH=0
HEADER_H=1 HEADER_LOGO=0 HEADER_TOP=1

fb_flush() {
    [[ -n "$TTY_FD" ]] || return 0
    printf '%s' "$FB" >&"$TTY_FD"
    FB=""
}

# fb_text <row> <col> <style> <text>
fb_text() { FB+=$'\e['"$1;$2H$3$4"; }

# fb_rect <row> <col> <height> <width> <style> - solid area.
fb_rect() {
    local r="$1" c="$2" h="$3" w="$4" st="$5" line i
    ((h > 0 && w > 0)) || return 0
    printf -v line '%*s' "$w" ''
    for ((i = 0; i < h; i++)); do
        FB+=$'\e['"$((r + i));${c}H${st}${line}"
    done
}

# fb_hline <row> <col> <width> <style> <char>
fb_hline() {
    local line
    ((${3} > 0)) || return 0
    printf -v line '%*s' "$3" ''
    FB+=$'\e['"$1;$2H$4${line// /$5}"
}

# The header shrinks with the terminal so the dialogs keep the room they need
# (the tallest form is 17 rows):
#   34+ rows  5-row logo with a blank row above and below
#   28+ rows  4-row logo with a blank row above
#   24+ rows  4-row logo
#   smaller   a single line
ui_header_height() {
    HEADER_TOP=1
    if ((TERM_ROWS >= 34)); then
        HEADER_LOGO=5 HEADER_TOP=2 HEADER_H=7
    elif ((TERM_ROWS >= 24)); then
        HEADER_LOGO=4
        ((TERM_ROWS >= 28)) && HEADER_TOP=2
        HEADER_H=$((HEADER_TOP + 3))
    else
        HEADER_LOGO=0 HEADER_H=1
    fi
}

# ui_track - what the progress bar in the header shows: the wizard step,
# then the plan. Sets TRACK_PCT (0-100), TRACK_LABEL and TRACK_STATE (run,
# ok or fail); returns 1 when there is nothing to track (menus, tools
# without a plan).
TRACK_PCT=0 TRACK_LABEL="" TRACK_STATE=""
ui_track() {
    TRACK_PCT=0 TRACK_LABEL="" TRACK_STATE="run"
    if ((PLAN_EXECUTED && ${#PROG_IDS[@]})); then
        progress_percent
        TRACK_PCT=$PROG_PCT
        if ((PLAN_RUNNING)); then
            TRACK_LABEL="${TRACK_PCT}%"
        elif ((PLAN_FAILED_INDEX < 0 && SUMMARY_OK)); then
            TRACK_PCT=100 TRACK_LABEL="" TRACK_STATE="ok"
        else
            TRACK_STATE="fail" TRACK_LABEL="${G_FAIL} Failed"
            ((PLAN_ABORTED)) && TRACK_LABEL="${G_FAIL} Stopped"
        fi
    elif [[ "$UI_STEP" =~ ^([0-9]+)/([1-9][0-9]*)$ ]]; then
        TRACK_PCT=$((BASH_REMATCH[1] * 100 / BASH_REMATCH[2]))
        TRACK_LABEL="Step ${BASH_REMATCH[1]} of ${BASH_REMATCH[2]}"
    else
        TRACK_STATE=""
        return 1
    fi
    return 0
}

# ui_track_gradient <cells> - TRACK_GRAD[i]: foregrounds running from deep
# blue to the light blue of the X in the logo, so the filled part of the bar
# brightens towards its leading edge (24-bit and 256 colours).
declare -a TRACK_GRAD=()
TRACK_GRAD_KEY=""
ui_track_gradient() {
    local n="$1" i g b bg
    ((UI_DEPTH == 24 || UI_DEPTH == 256)) || return 1
    ((n > 1)) || n=2
    [[ "$TRACK_GRAD_KEY" == "${n}|${UI_DEPTH}" ]] && return 0
    TRACK_GRAD_KEY="${n}|${UI_DEPTH}"
    TRACK_GRAD=()
    bg="$(_ui_bg root)"
    for ((i = 0; i < n; i++)); do
        g=$((72 + 100 * i / (n - 1)))
        b=$((248 + 7 * i / (n - 1)))
        if ((UI_DEPTH == 24)); then
            TRACK_GRAD+=($'\e[0;38;2;2;'"${g};${b}m${bg}")
        else
            _ui_rgb256 2 "$g" "$b"
            TRACK_GRAD+=($'\e[0;38;5;'"${REPLY}m${bg}")
        fi
    done
}

# _ui_draw_track <row> <col> <width> - the bar, then its label. The label has
# a fixed slot so the bar keeps its length from step to step.
_ui_draw_track() {
    local row="$1" col="$2" w="$3" slot=14 bw fill i cells="" rest
    [[ -n "$TRACK_STATE" ]] || return 0
    bw=$((w - slot))
    ((bw >= 8)) || return 0
    fill=$(((bw * TRACK_PCT + 50) / 100))
    local on="$S_TRACK_ON" lst="$S_TRACK_TEXT" g_on="$G_HALF_DOWN" g_off="$G_HALF_DOWN"
    case "$TRACK_STATE" in
        ok) on="$S_TRACK_OK" lst="$S_TRACK_OK" ;;
        fail) on="$S_TRACK_ERR" lst="$S_TRACK_ERR" ;;
    esac
    # A half-height bar where colours tell its parts apart; otherwise glyphs.
    if ((!UI_UTF8 || UI_DEPTH == 0)); then
        g_on="$G_BAR_ON" g_off="$G_BAR_OFF"
    fi
    if [[ "$TRACK_STATE" == run ]] && ((fill)) && ui_track_gradient "$fill"; then
        for ((i = 0; i < fill; i++)); do cells+="${TRACK_GRAD[i]}${g_on}"; done
        fb_text "$row" "$col" "" "$cells"
    else
        printf -v cells '%*s' "$fill" ''
        fb_text "$row" "$col" "$on" "${cells// /$g_on}"
    fi
    printf -v rest '%*s' $((bw - fill)) ''
    fb_text "$row" $((col + fill)) "$S_TRACK" "${rest// /$g_off}"
    text_trunc "$TRACK_LABEL" $((slot - 2))
    fb_text "$row" $((col + bw + 2)) "$lst" "$TEXT_OUT"
}

# _ui_header_link <row> <col> <width> <label> <url>
_ui_header_link() {
    fb_text "$1" "$2" "$S_HDR_MUTED" "$4"
    text_trunc "$5" $(($3 - 9))
    fb_text "$1" $(($2 + 9)) "$S_HDR_LINK" "$TEXT_OUT"
}

# The header: the DezerX mark with the name, the links and the progress bar
# beside it, lined up with a standard dialog below.
ui_draw_header() {
    ui_header_height
    local w=$UI_WIDTH left right
    ((w > TERM_COLS - 4)) && w=$((TERM_COLS - 4))
    # The columns of a standard dialog's border.
    left=$(((TERM_COLS - w) / 2 + 2))
    right=$((left + w - 3))
    fb_rect 1 1 "$HEADER_H" "$TERM_COLS" "$S_ROOT"

    if ((HEADER_LOGO == 0)); then
        # One line: the mark as text, the name, then the progress bar or,
        # when nothing runs, the links.
        local col=$((left + 4 + ${#PRODUCT_LABEL} + 2))
        local room=$((right - col + 1))
        fb_text 1 "$left" "$S_BRAND" "D"
        fb_text 1 $((left + 1)) "$S_HDR_X" "X"
        fb_text 1 $((left + 4)) "$S_BRAND" "$PRODUCT_LABEL"
        if [[ -n "$TRACK_STATE" ]]; then
            _ui_draw_track 1 "$col" "$room"
        elif ((room >= ${#WEBSITE_URL} + ${#DISCORD_URL} + 3)); then
            fb_text 1 "$col" "$S_HDR_LINK" "$WEBSITE_URL"
            fb_text 1 $((col + ${#WEBSITE_URL})) "$S_HDR_MUTED" " ${G_DOT} "
            fb_text 1 $((col + ${#WEBSITE_URL} + 3)) "$S_HDR_LINK" "$DISCORD_URL"
        fi
        return 0
    fi

    # Sit directly above the dialog (and its tab), one blank row between.
    local top=$((DLG_R - HEADER_LOGO - 1 - (${#UI_FLOW} > 0 ? 1 : 0))) i
    ((top < HEADER_TOP)) && top=$HEADER_TOP
    logo_render "$HEADER_LOGO"
    for ((i = 0; i < ${#LOGO_ROWS[@]}; i++)); do
        fb_text $((top + i)) "$left" "" "${LOGO_ROWS[i]}"
    done

    local tc=$((left + LOGO_W + 3))
    local tw=$((right - tc + 1)) sub="Installer ${SPARTAN_VERSION}" r=$top
    fb_text "$r" "$tc" "$S_BRAND" "$PRODUCT_LABEL"
    if ((HEADER_LOGO == 5)); then
        r=$((r + 1))
        fb_text "$r" "$tc" "$S_HDR_MUTED" "$sub"
    elif ((${#PRODUCT_LABEL} + 2 + ${#sub} <= tw)); then
        fb_text "$r" $((tc + ${#PRODUCT_LABEL} + 2)) "$S_HDR_MUTED" "$sub"
    fi
    _ui_header_link $((r + 1)) "$tc" "$tw" "Website" "$WEBSITE_URL"
    _ui_header_link $((r + 2)) "$tc" "$tw" "Discord" "$DISCORD_URL"
    _ui_draw_track $((r + 3)) "$tc" "$tw"
}

ui_draw_footer() {
    local hints=" ${UI_HINTS:-Arrow keys move ${G_DOT} Enter selects ${G_DOT} Esc goes back}"
    text_trunc "$hints" "$TERM_COLS"
    fb_rect "$TERM_ROWS" 1 1 "$TERM_COLS" "$S_FOOT"
    fb_text "$TERM_ROWS" 1 "$S_FOOT" "$TEXT_OUT"
}

# Background, header and footer. Rebuilt when the terminal size, progress
# or hints change; otherwise reused between key presses.
ui_draw_base() {
    fb_rect 1 1 "$TERM_ROWS" "$TERM_COLS" "$S_ROOT"
    ui_draw_header
    ui_draw_footer
}

# ui_layout_dialog <content rows> [preferred width] - centres a dialog in the
# body area. Content rows exclude the border, padding and button row.
ui_layout_dialog() {
    local content_h="$1" want_w="${2:-72}"
    ui_header_height
    local body_top=$((HEADER_H + 1)) body_h=$((TERM_ROWS - HEADER_H - 1))
    local max_w=$((TERM_COLS - 4))
    ((want_w > max_w)) && want_w=$max_w
    ((want_w < 30)) && want_w=30
    DLG_W=$want_w
    # border + blank + content + blank + buttons + blank + border
    DLG_H=$((content_h + 6))
    local max_h=$((body_h - 2))
    ((DLG_H > max_h)) && DLG_H=$max_h
    ((DLG_H < 7)) && DLG_H=7
    DLG_R=$((body_top + (body_h - DLG_H) / 2))
    DLG_C=$(((TERM_COLS - DLG_W) / 2 + 1))
    # Nudge the dialog up a little, like a window manager would.
    ((DLG_R > body_top + 1 && body_h - DLG_H > 6)) && DLG_R=$((DLG_R - 1))
    DLG_IR=$((DLG_R + 2))
    DLG_IC=$((DLG_C + 4))
    DLG_IW=$((DLG_W - 8))
    DLG_IH=$((DLG_H - 6))
}

# ui_draw_box <title> - panel, border, title and shadow at the current layout.
ui_draw_box() {
    local title="$1" border="$S_BORDER" title_style="$S_TITLE"
    if ((UI_DANGER)); then
        border="$S_DANGER"
        title_style="${S_DANGER}"$'\e[1m'
    fi
    local r=$DLG_R c=$DLG_C h=$DLG_H w=$DLG_W i

    # The flow the dialog belongs to, as a tab above its top left corner.
    if ((r - 1 > HEADER_H)); then
        fb_rect $((r - 1)) "$c" 1 "$w" "$S_ROOT"
        if [[ -n "$UI_FLOW" ]]; then
            local tab="$S_TAB"
            ((UI_DANGER)) && tab="$S_TAB_DANGER"
            fb_text $((r - 1)) $((c + 1)) "$tab" " ${UI_FLOW^^} "
        fi
    fi

    # Shadow: half-height strip below, one column on the right.
    if ((UI_DEPTH != 0 && UI_DEPTH != 16)); then
        if ((UI_UTF8)); then
            fb_text "$r" $((c + w)) "$S_SHADE" "$G_HALF_DOWN"
            for ((i = 1; i < h; i++)); do fb_text $((r + i)) $((c + w)) "$S_SHADOW" " "; done
            fb_hline $((r + h)) $((c + 1)) "$w" "$S_SHADE" "$G_HALF_UP"
        else
            fb_rect $((r + 1)) $((c + w)) "$h" 1 "$S_SHADOW"
            fb_rect $((r + h)) $((c + 1)) 1 "$w" "$S_SHADOW"
        fi
    fi

    fb_rect "$r" "$c" "$h" "$w" "$S_PANEL"

    # Border sits one column inside the panel edge.
    local bw=$((w - 2)) inner
    printf -v inner '%*s' $((bw - 2)) ''
    inner="${inner// /$G_H}"
    fb_text "$r" $((c + 1)) "$border" "${G_TL}${inner}${G_TR}"
    for ((i = 1; i < h - 1; i++)); do
        fb_text $((r + i)) $((c + 1)) "$border" "$G_V"
        fb_text $((r + i)) $((c + w - 2)) "$border" "$G_V"
    done
    fb_text $((r + h - 1)) $((c + 1)) "$border" "${G_BL}${inner}${G_BR}"

    if [[ -n "$title" ]]; then
        text_trunc "$title" $((bw - 8))
        local t=" ${TEXT_OUT} "
        local tc=$((c + 1 + (bw - ${#t} - 2) / 2))
        fb_text "$r" "$tc" "$border" "$G_TITLE_L"
        fb_text "$r" $((tc + 1)) "$title_style" "$t"
        fb_text "$r" $((tc + 1 + ${#t})) "$border" "$G_TITLE_R"
    fi
}

# ui_draw_lines <row> <first index> <count> - draws WRAP_LINES inside the dialog.
ui_draw_lines() {
    local row="$1" first="$2" count="$3" i
    for ((i = 0; i < count; i++)); do
        local idx=$((first + i))
        ((idx < ${#WRAP_LINES[@]})) || break
        text_render "${WRAP_LINES[idx]}" "$S_PANEL"
        fb_text $((row + i)) "$DLG_IC" "$S_PANEL" "$TEXT_OUT"
    done
}

# ui_draw_buttons <row> <active index> <label>... - centred button row.
ui_draw_buttons() {
    local row="$1" active="$2"
    shift 2
    local -a labels=("$@")
    local total=0 gap=4 l
    for l in "${labels[@]}"; do total=$((total + ${#l} + 2)); done
    total=$((total + gap * (${#labels[@]} - 1)))
    local col=$((DLG_C + (DLG_W - total) / 2)) i
    for i in "${!labels[@]}"; do
        local st="$S_BTN"
        ((i == active)) && st="$S_BTN_ON"
        fb_text "$row" "$col" "$st" " ${labels[i]} "
        col=$((col + ${#labels[i]} + 2 + gap))
    done
}

# ui_draw_scrollmarks <row top> <row bottom> <can up> <can down>
ui_draw_scrollmarks() {
    local col=$((DLG_C + DLG_W - 3))
    (($3)) && fb_text "$1" "$col" "$S_ACCENT" "$G_UP"
    (($4)) && fb_text "$2" "$col" "$S_ACCENT" "$G_DOWN"
}

# Full repaint of base + dialog happens through ui_frame_begin/ui_frame_end so
# widgets only describe their own content.
ui_frame_begin() {
    ui_track || true
    local key="${TERM_ROWS}x${TERM_COLS}|${TRACK_STATE}:${TRACK_PCT}:${TRACK_LABEL}|${UI_HINTS}|${DLG_R},${DLG_C},${DLG_H},${DLG_W}"
    if [[ "$key" != "$UI_BASE_KEY" ]]; then
        FB=$'\e[0m\e[H'
        ui_draw_base
        UI_BASE_KEY="$key"
    else
        FB=""
    fi
}

ui_frame_end() { fb_flush; }

ui_force_redraw() { UI_BASE_KEY=""; }
