# shellcheck shell=bash
# Dialog widgets. Each one draws a centred dialog, handles the keyboard and
# returns:  0 = confirm / next   1 = back / no / Esc   255 = terminal closed
# The chosen value, where there is one, is left in UI_RESULT.
#
# Outside the full-screen mode every widget falls back to the line prompts in
# ui/line.sh, so callers never need to care which mode is active.

UI_RESULT=""
UI_WIDTH=74
UI_WIDTH_SMALL=58

ui_hint_text() { UI_HINTS="Enter continue ${G_DOT} Esc back"; }
ui_hint_list() { UI_HINTS="${G_ARROWS} move ${G_DOT} Enter choose ${G_DOT} Esc back"; }
ui_hint_check() { UI_HINTS="${G_ARROWS} move ${G_DOT} Space toggle ${G_DOT} Enter continue ${G_DOT} Esc back"; }

UI_IN_QUIT=0

# ui_confirm_quit - asked on Ctrl+C. Exits the program when confirmed.
ui_confirm_quit() {
    ((UI_IN_QUIT)) && return 0
    local saved_hints="$UI_HINTS" saved_danger="$UI_DANGER" saved_result="$UI_RESULT"
    UI_DANGER=0
    UI_IN_QUIT=1
    local text="Quit the installer?\n\nNothing on this server has been changed yet."
    [[ -n "${UI_QUIT_TEXT:-}" ]] && text="$UI_QUIT_TEXT"
    if _ui_choice_dialog "Quit" "$text" "$UI_WIDTH_SMALL" 1 "Quit" "Stay"; then
        [[ "$UI_RESULT" == 0 ]] && spartan_exit 130 "cancelled"
    fi
    UI_IN_QUIT=0
    UI_HINTS="$saved_hints"
    UI_DANGER="$saved_danger"
    UI_RESULT="$saved_result"
    ui_force_redraw
    return 0
}

# _ui_choice_dialog <title> <text> <width> <default button> <label>...
# Text dialog with a row of buttons. UI_RESULT = index of the pressed button.
# Returns 0 when a button was pressed, 1 on Esc, 255 when the terminal closed.
_ui_choice_dialog() {
    local title="$1" text="$2" width="$3" active="$4"
    shift 4
    local -a labels=("$@")
    local top=0 n_lines visible
    text="${text//\\n/$'\n'}"

    while :; do
        ui_layout_dialog 3 "$width"
        text_wrap "$DLG_IW" "$text"
        n_lines=${#WRAP_LINES[@]}
        ui_layout_dialog "$n_lines" "$width"
        visible=$DLG_IH
        ((top > n_lines - visible)) && top=$((n_lines - visible))
        ((top < 0)) && top=0
        if ((n_lines > visible)); then
            UI_HINTS="${G_ARROWS} scroll ${G_DOT} ${G_BACK}${G_NEXT} choose ${G_DOT} Enter confirm ${G_DOT} Esc back"
        elif ((${#labels[@]} > 1)); then
            UI_HINTS="${G_BACK}${G_NEXT} choose ${G_DOT} Enter confirm ${G_DOT} Esc back"
        else
            UI_HINTS="Enter continue ${G_DOT} Esc back"
        fi

        ui_frame_begin
        ui_draw_box "$title"
        ui_draw_lines "$DLG_IR" "$top" "$visible"
        ui_draw_scrollmarks "$DLG_IR" $((DLG_IR + visible - 1)) $((top > 0)) $((top + visible < n_lines))
        ui_draw_buttons $((DLG_R + DLG_H - 3)) "$active" "${labels[@]}"
        ui_frame_end

        term_read_key
        case "$KEY" in
            LEFT | BTAB) ((active > 0)) && active=$((active - 1)) ;;
            RIGHT | TAB) ((active < ${#labels[@]} - 1)) && active=$((active + 1)) ;;
            UP) ((top > 0)) && top=$((top - 1)) ;;
            DOWN) ((top + visible < n_lines)) && top=$((top + 1)) ;;
            PGUP) top=$((top - visible)) ;;
            PGDN) top=$((top + visible)) ;;
            HOME) top=0 ;;
            END) top=$n_lines ;;
            ENTER | SPACE)
                UI_RESULT="$active"
                return 0
                ;;
            ESC) return 1 ;;
            CTRL_C)
                if ((UI_IN_QUIT)); then
                    UI_RESULT=0
                    return 0
                fi
                ui_confirm_quit
                ;;
            RESIZE | CTRL_L) ui_force_redraw ;;
            EOF) return 255 ;;
            CHAR)
                local i lc="${KEY_CHAR,,}"
                for i in "${!labels[@]}"; do
                    local l="${labels[i]#"$G_BACK" }"
                    l="${l,,}"
                    if [[ "${l:0:1}" == "$lc" ]]; then
                        UI_RESULT="$i"
                        return 0
                    fi
                done
                ;;
        esac
    done
}

# ui_msgbox <title> <text> [button label]
ui_msgbox() {
    [[ "$UI_MODE" == tui ]] || { line_msgbox "$@"; return; }
    _ui_choice_dialog "$1" "$2" "$UI_WIDTH" 0 "${3:-OK}"
}

# ui_nav <title> <text> [next label] [back label] - wizard page with Back/Next.
ui_nav() {
    [[ "$UI_MODE" == tui ]] || { line_nav "$@"; return; }
    local next="${3:-Next ${G_NEXT}}" back="${4:-${G_BACK} Back}"
    _ui_choice_dialog "$1" "$2" "$UI_WIDTH" 1 "$back" "$next"
    local rc=$?
    ((rc == 0)) || return "$rc"
    [[ "$UI_RESULT" == 1 ]] && return 0
    return 1
}

# ui_confirm <title> <text> [yes label] [no label] [default: yes|no]
ui_confirm() {
    [[ "$UI_MODE" == tui ]] || { line_confirm "$@"; return; }
    local yes="${3:-Yes}" no="${4:-No}" def=0
    [[ "${5:-yes}" == no ]] && def=1
    _ui_choice_dialog "$1" "$2" "$UI_WIDTH_SMALL" "$def" "$yes" "$no"
    local rc=$?
    ((rc == 0)) || return "$rc"
    [[ "$UI_RESULT" == 0 ]]
}

# ui_error <title> <text> - red dialog with a single button.
ui_error() {
    [[ "$UI_MODE" == tui ]] || { line_msgbox "$@"; return; }
    local saved="$UI_DANGER"
    UI_DANGER=1
    _ui_choice_dialog "$1" "$2" "$UI_WIDTH" 0 "${3:-OK}"
    local rc=$?
    UI_DANGER="$saved"
    ui_force_redraw
    return "$rc"
}

# ---------------------------------------------------------------------------
# Lists
# ---------------------------------------------------------------------------

# _ui_list <mode> <title> <text> <default> <tag> <label> <desc|state>...
#   mode: menu | radio | check
# Menu and radio return the highlighted tag in UI_RESULT. Checklists return
# the checked tags separated by spaces.
_ui_list() {
    local mode="$1" title="$2" text="$3" def="$4"
    shift 4
    local -a tags=() labels=() extra=() checked=()
    while (($# >= 3)); do
        tags+=("$1")
        labels+=("$2")
        extra+=("$3")
        if [[ "$mode" == check ]]; then
            if is_true "$3"; then checked+=(1); else checked+=(0); fi
        fi
        shift 3
    done
    local n=${#tags[@]} sel=0 first=0 i btn=1
    for i in "${!tags[@]}"; do [[ "${tags[i]}" == "$def" ]] && sel=$i; done
    text="${text//\\n/$'\n'}"

    local back_label="${G_BACK} Back" next_label="Next ${G_NEXT}"
    [[ -n "${UI_LIST_BACK:-}" ]] && back_label="$UI_LIST_BACK"
    [[ -n "${UI_LIST_NEXT:-}" ]] && next_label="$UI_LIST_NEXT"

    local label_w=0
    for i in "${!labels[@]}"; do ((${#labels[i]} > label_w)) && label_w=${#labels[i]}; done

    while :; do
        ui_layout_dialog 3 "$UI_WIDTH"
        text_wrap "$DLG_IW" "$text"
        local text_n=${#WRAP_LINES[@]}
        local want=$((text_n + n + 1))
        [[ -z "$text" ]] && want=$n && text_n=0
        ui_layout_dialog "$want" "$UI_WIDTH"
        local list_top=$((DLG_IR + text_n + (text_n > 0 ? 1 : 0)))
        local list_h=$((DLG_IH - text_n - (text_n > 0 ? 1 : 0)))
        ((list_h < 1)) && list_h=1
        ((sel < first)) && first=$sel
        ((sel >= first + list_h)) && first=$((sel - list_h + 1))
        ((first < 0)) && first=0

        if [[ "$mode" == check ]]; then ui_hint_check; else ui_hint_list; fi
        ui_frame_begin
        ui_draw_box "$title"
        ((text_n > 0)) && ui_draw_lines "$DLG_IR" 0 "$text_n"

        for ((i = 0; i < list_h && first + i < n; i++)); do
            local idx=$((first + i)) row=$((list_top + i)) marker="" st="$S_PANEL" dst="$S_MUTED"
            case "$mode" in
                radio) if ((idx == sel)); then marker="${G_RADIO_ON} "; else marker="${G_RADIO_OFF} "; fi ;;
                check) if ((checked[idx])); then marker="[${G_CHECK_ON}] "; else marker="[${G_CHECK_OFF}] "; fi ;;
            esac
            if ((idx == sel)); then
                st="$S_SEL"
                dst="$S_SEL"
            fi
            local label="${labels[idx]}" desc=""
            [[ "$mode" != check ]] && desc="${extra[idx]}"
            [[ "$mode" == check ]] && desc="${UI_CHECK_DESC[idx]:-}"
            local padded
            printf -v padded "%-${label_w}s" "$label"
            local left=" ${marker}${padded}"
            local room=$((DLG_IW + 2 - ${#left} - 3))
            fb_rect "$row" $((DLG_IC - 1)) 1 $((DLG_IW + 2)) "$st"
            fb_text "$row" $((DLG_IC - 1)) "$st" "$left"
            if [[ -n "$desc" ]] && ((room > 4)); then
                text_trunc "$desc" "$room"
                fb_text "$row" $((DLG_IC - 1 + ${#left} + 3)) "$dst" "$TEXT_OUT"
            fi
        done
        ui_draw_scrollmarks "$list_top" $((list_top + list_h - 1)) $((first > 0)) $((first + list_h < n))
        ui_draw_buttons $((DLG_R + DLG_H - 3)) "$btn" "$back_label" "$next_label"
        ui_frame_end

        term_read_key
        case "$KEY" in
            UP) if ((sel > 0)); then sel=$((sel - 1)); else sel=$((n - 1)); fi ;;
            DOWN) if ((sel < n - 1)); then sel=$((sel + 1)); else sel=0; fi ;;
            HOME) sel=0 ;;
            END) sel=$((n - 1)) ;;
            PGUP) sel=$((sel - list_h)); ((sel < 0)) && sel=0 ;;
            PGDN) sel=$((sel + list_h)); ((sel > n - 1)) && sel=$((n - 1)) ;;
            LEFT | BTAB) btn=0 ;;
            RIGHT | TAB) btn=1 ;;
            SPACE)
                if [[ "$mode" == check ]]; then
                    checked[sel]=$((1 - checked[sel]))
                fi
                ;;
            ENTER)
                ((btn == 0)) && return 1
                if [[ "$mode" == check ]]; then
                    UI_RESULT=""
                    for i in "${!tags[@]}"; do ((checked[i])) && UI_RESULT+="${tags[i]} "; done
                    UI_RESULT="${UI_RESULT% }"
                else
                    UI_RESULT="${tags[sel]}"
                fi
                return 0
                ;;
            ESC) return 1 ;;
            CTRL_C) ui_confirm_quit ;;
            RESIZE | CTRL_L) ui_force_redraw ;;
            EOF) return 255 ;;
            CHAR)
                local lc="${KEY_CHAR,,}" j
                for ((j = 1; j <= n; j++)); do
                    local cand=$(((sel + j) % n))
                    local lbl="${labels[cand],,}"
                    if [[ "${lbl:0:1}" == "$lc" ]]; then
                        sel=$cand
                        break
                    fi
                done
                ;;
        esac
    done
}

# ui_menu <title> <text> <default tag> <tag> <label> <description>...
ui_menu() {
    [[ "$UI_MODE" == tui ]] || { line_menu "$@"; return; }
    _ui_list menu "$@"
}

# ui_radio <title> <text> <selected tag> <tag> <label> <description>...
ui_radio() {
    [[ "$UI_MODE" == tui ]] || { line_menu "$@"; return; }
    _ui_list radio "$@"
}

# ui_checklist <title> <text> <tag> <label> <on|off>...  (UI_CHECK_DESC[i] optional)
ui_checklist() {
    [[ "$UI_MODE" == tui ]] || { line_checklist "$@"; return; }
    local title="$1" text="$2"
    shift 2
    _ui_list check "$title" "$text" "" "$@"
}
