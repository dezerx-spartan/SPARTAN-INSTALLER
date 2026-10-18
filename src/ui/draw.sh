# shellcheck shell=bash
# Screen composition. Every frame is built in FB and written in one go so the
# screen never flickers, even over slow SSH links.
#
#   ┌ header ──────── DezerX Spartan Installer ▓▓▒▒░░          v2.0.0 · step 2 of 7 ┐
#   │                                                                              │
#   │                ┌──────────────┤ Title ├──────────────┐                       │
#   │                │ dialog                              │▌                      │
#   │                └─────────────────────────────────────┘▌          DX logo     │
#   │                 ▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀                        │
#   └ footer ─ key hints ──────────────────────────────────────────────────────────┘

FB=""
UI_STEP_TEXT=""
UI_HINTS=""
UI_BASE_KEY=""
UI_DANGER=0

# Dialog geometry (set by ui_layout_dialog)
DLG_R=0 DLG_C=0 DLG_H=0 DLG_W=0
DLG_IR=0 DLG_IC=0 DLG_IW=0 DLG_IH=0
HEADER_H=1

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

ui_header_height() {
    if ((TERM_ROWS >= 30)); then HEADER_H=3; else HEADER_H=1; fi
}

# The header: brand block on the accent colour fading into the background,
# with the version and step on the right (in the spirit of the AMP 3 installer).
ui_draw_header() {
    ui_header_height
    local title="DezerX Spartan Installer"
    local tlen=${#title} r mid fade_w meta logo_w=0
    mid=$(((HEADER_H + 1) / 2))
    logo_mini_available && logo_w=$((${#LOGO_MINI[0]} + 2))
    local block_w=$((2 + logo_w + tlen + 3))
    fade_w=$((TERM_COLS / 4))
    ((fade_w > 40)) && fade_w=40
    ((fade_w < 6)) && fade_w=6

    meta="v${SPARTAN_VERSION%%-*}"
    [[ -n "$UI_STEP_TEXT" ]] && meta+="  ${G_DOT}  ${UI_STEP_TEXT}"
    meta+=" "

    local fade="" q=$((fade_w / 4)) i
    for ((i = 0; i < fade_w; i++)); do
        if ((i < q)); then fade+="$G_SHADE1"
        elif ((i < q * 2)); then fade+="$G_SHADE2"
        elif ((i < q * 3)); then fade+="$G_SHADE3"
        else fade+=" "
        fi
    done

    for ((r = 1; r <= HEADER_H; r++)); do
        fb_rect "$r" 1 1 "$TERM_COLS" "$S_ROOT"
        fb_rect "$r" 1 1 "$block_w" "$S_HEAD"
        ((UI_DEPTH == 0)) || fb_text "$r" $((block_w + 1)) "$S_HEAD_FADE" "$fade"
    done
    ((logo_w)) && ui_draw_header_logo 1 3
    fb_text "$mid" $((3 + logo_w)) "$S_HEAD" "$title"
    if ((${#meta} + block_w + fade_w < TERM_COLS)); then
        fb_text "$mid" $((TERM_COLS - ${#meta})) "$S_HEAD_META" "$meta"
    fi
}

ui_draw_footer() {
    local hints=" ${UI_HINTS:-Arrow keys move ${G_DOT} Enter selects ${G_DOT} Esc goes back}"
    text_trunc "$hints" "$TERM_COLS"
    fb_rect "$TERM_ROWS" 1 1 "$TERM_COLS" "$S_FOOT"
    fb_text "$TERM_ROWS" 1 "$S_FOOT" "$TEXT_OUT"
}

# Background, header, footer and watermark. Rebuilt when the terminal size,
# step text or hints change; otherwise reused between key presses.
ui_draw_base() {
    fb_rect 1 1 "$TERM_ROWS" "$TERM_COLS" "$S_ROOT"
    ui_draw_header
    ui_draw_logo
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
    local key="${TERM_ROWS}x${TERM_COLS}|${UI_STEP_TEXT}|${UI_HINTS}|${DLG_R},${DLG_C},${DLG_H},${DLG_W}"
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
