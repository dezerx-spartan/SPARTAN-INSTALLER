declare -a FORM_LABELS=() FORM_VALUES=() FORM_TYPES=() FORM_CHOICES=() FORM_HELP=() FORM_DISABLED=()
FORM_VALIDATE=""
FORM_ON_CHANGE=""
FORM_ERROR=""
FORM_ERROR_FIELD=""

form_reset() {
    FORM_LABELS=() FORM_VALUES=() FORM_TYPES=() FORM_CHOICES=() FORM_HELP=() FORM_DISABLED=()
    FORM_VALIDATE=""
    FORM_ON_CHANGE=""
    FORM_ERROR=""
    FORM_ERROR_FIELD=""
}

form_add() {
    FORM_LABELS+=("$1")
    FORM_VALUES+=("$2")
    FORM_TYPES+=("${3:-text}")
    if [[ "${3:-text}" == choice ]]; then
        FORM_CHOICES+=("${4:-}")
        FORM_HELP+=("${5:-}")
    else
        FORM_CHOICES+=("")
        FORM_HELP+=("${4:-}")
    fi
    FORM_DISABLED+=(0)
}

_form_choice_step() {
    local i="$1" dir="$2"
    local -a opts
    IFS='|' read -ra opts <<<"${FORM_CHOICES[i]}"
    local n=${#opts[@]} cur=0 k
    ((n > 0)) || return 0
    for k in "${!opts[@]}"; do [[ "${opts[k]}" == "${FORM_VALUES[i]}" ]] && cur=$k; done
    cur=$(((cur + dir + n) % n))
    FORM_VALUES[i]="${opts[cur]}"
    [[ -n "$FORM_ON_CHANGE" ]] && "$FORM_ON_CHANGE"
}

_form_next_field() {
    local from="$1" dir="$2" n=${#FORM_LABELS[@]} i k
    for ((k = 1; k <= n + 2; k++)); do
        i=$(((from + dir * k + (n + 2) * 4) % (n + 2)))
        ((i >= n)) && { echo "$i"; return; }
        ((${FORM_DISABLED[i]:-0})) || { echo "$i"; return; }
    done
    echo "$from"
}

ui_form() {
    [[ "$UI_MODE" == tui ]] || { line_form "$@"; return; }
    local title="$1" text="$2"
    text="${text//\\n/$'\n'}"
    local n=${#FORM_LABELS[@]} focus=0 i
    local -a cursor=()
    for i in "${!FORM_VALUES[@]}"; do cursor[i]=${#FORM_VALUES[i]}; done
    while ((focus < n)) && ((${FORM_DISABLED[focus]:-0})); do focus=$((focus + 1)); done
    FORM_ERROR=""

    local label_w=0
    for i in "${!FORM_LABELS[@]}"; do ((${#FORM_LABELS[i]} > label_w)) && label_w=${#FORM_LABELS[i]}; done
    label_w=$((label_w + 3))

    while :; do
        ui_layout_dialog 3 "$UI_WIDTH"
        text_wrap "$DLG_IW" "$text"
        local text_n=${#WRAP_LINES[@]}
        [[ -z "$text" ]] && text_n=0
        ui_layout_dialog $((text_n + (text_n > 0 ? 1 : 0) + n + 2)) "$UI_WIDTH"
        local frow=$((DLG_IR + text_n + (text_n > 0 ? 1 : 0)))
        local field_w=$((DLG_IW - label_w))
        ((field_w > 46)) && field_w=46
        ((field_w < 8)) && field_w=8

        UI_HINTS="${G_ARROWS} field ${G_DOT} type to edit ${G_DOT} Enter continue ${G_DOT} Esc back"
        if ((focus < n)) && [[ "${FORM_TYPES[focus]}" == choice ]]; then
            UI_HINTS="${G_ARROWS} field ${G_DOT} ${G_BACK}${G_NEXT} or Space change ${G_DOT} Enter continue ${G_DOT} Esc back"
        fi

        ui_frame_begin
        ui_draw_box "$title"
        ((text_n > 0)) && ui_draw_lines "$DLG_IR" 0 "$text_n"

        local cur_col=0 cur_row=0
        for ((i = 0; i < n; i++)); do
            local row=$((frow + i)) lst="$S_MUTED" fst="$S_INPUT" disabled=${FORM_DISABLED[i]:-0}
            ((i == focus)) && lst="$S_BOLD" && fst="$S_INPUT_ON"
            ((disabled)) && lst="$S_DIM" && fst="$S_INPUT_OFF"
            fb_text "$row" "$DLG_IC" "$lst" "${FORM_LABELS[i]}"

            local shown="${FORM_VALUES[i]}" off=0
            case "${FORM_TYPES[i]}" in
                password)
                    printf -v shown '%*s' "${#FORM_VALUES[i]}" ''
                    shown="${shown// /$G_MASK}"
                    ;;
                choice)
                    if ((i == focus)); then shown="${G_BACK} ${shown} ${G_NEXT}"; fi
                    ;;
            esac
            ((disabled)) && shown="${G_SKIP}"
            if [[ "${FORM_TYPES[i]}" != choice ]] && ((cursor[i] > field_w - 2)); then
                off=$((cursor[i] - field_w + 2))
            fi
            local vis="${shown:off:field_w-1}"
            fb_rect "$row" $((DLG_IC + label_w)) 1 "$field_w" "$fst"
            fb_text "$row" $((DLG_IC + label_w + 1)) "$fst" "$vis"
            if ((i == focus)) && [[ "${FORM_TYPES[i]}" != choice ]]; then
                cur_row=$row
                cur_col=$((DLG_IC + label_w + 1 + cursor[i] - off))
                local under="${shown:cursor[i]:1}"
                fb_text "$cur_row" "$cur_col" "$S_CURSOR" "${under:- }"
            fi
        done

        local info_row=$((frow + n + 1))
        if [[ -n "$FORM_ERROR" ]]; then
            text_trunc "${G_WARN} ${FORM_ERROR}" "$DLG_IW"
            fb_text "$info_row" "$DLG_IC" "$S_ERR" "$TEXT_OUT"
        elif ((focus < n)) && [[ -n "${FORM_HELP[focus]:-}" ]]; then
            text_trunc "${FORM_HELP[focus]}" "$DLG_IW"
            fb_text "$info_row" "$DLG_IC" "$S_MUTED" "$TEXT_OUT"
        fi

        local btn_active=-1
        ((focus == n)) && btn_active=0
        ((focus == n + 1)) && btn_active=1
        ((focus < n)) && btn_active=1
        ui_draw_buttons $((DLG_R + DLG_H - 3)) "$btn_active" "${G_BACK} Back" "${UI_FORM_NEXT:-Next ${G_NEXT}}"
        ui_frame_end

        term_read_key
        local type="text" val=""
        if ((focus < n)); then
            type="${FORM_TYPES[focus]}"
            val="${FORM_VALUES[focus]}"
        fi
        case "$KEY" in
            UP | BTAB) focus=$(_form_next_field "$focus" -1) ;;
            DOWN | TAB) focus=$(_form_next_field "$focus" 1) ;;
            LEFT)
                if ((focus < n)); then
                    if [[ "$type" == choice ]]; then _form_choice_step "$focus" -1
                    elif ((cursor[focus] > 0)); then cursor[focus]=$((cursor[focus] - 1)); fi
                elif ((focus == n + 1)); then
                    focus=$n
                fi
                ;;
            RIGHT)
                if ((focus < n)); then
                    if [[ "$type" == choice ]]; then _form_choice_step "$focus" 1
                    elif ((cursor[focus] < ${#val})); then cursor[focus]=$((cursor[focus] + 1)); fi
                elif ((focus == n)); then
                    focus=$((n + 1))
                fi
                ;;
            HOME) ((focus < n)) && cursor[focus]=0 ;;
            END) ((focus < n)) && cursor[focus]=${#val} ;;
            BACKSPACE)
                if ((focus < n)) && [[ "$type" != choice ]] && ((cursor[focus] > 0)); then
                    local c=${cursor[focus]}
                    FORM_VALUES[focus]="${val:0:c-1}${val:c}"
                    cursor[focus]=$((c - 1))
                    FORM_ERROR=""
                fi
                ;;
            DEL)
                if ((focus < n)) && [[ "$type" != choice ]]; then
                    local c=${cursor[focus]}
                    FORM_VALUES[focus]="${val:0:c}${val:c+1}"
                    FORM_ERROR=""
                fi
                ;;
            CTRL_U)
                if ((focus < n)) && [[ "$type" != choice ]]; then
                    FORM_VALUES[focus]=""
                    cursor[focus]=0
                fi
                ;;
            CTRL_W)
                if ((focus < n)) && [[ "$type" != choice ]]; then
                    local c=${cursor[focus]} head="${val:0:${cursor[focus]}}"
                    head="${head%"${head##*[![:space:]]}"}"
                    head="${head%[![:space:]]*}"
                    [[ "$head" == "${val:0:c}" ]] && head=""
                    FORM_VALUES[focus]="${head}${val:c}"
                    cursor[focus]=${#head}
                fi
                ;;
            SPACE | CHAR)
                if ((focus < n)); then
                    if [[ "$type" == choice ]]; then
                        _form_choice_step "$focus" 1
                    elif [[ "$type" == number && "$KEY_CHAR" != [0-9] ]]; then
                        :
                    elif ((${#val} < 255)); then
                        local c=${cursor[focus]}
                        FORM_VALUES[focus]="${val:0:c}${KEY_CHAR}${val:c}"
                        cursor[focus]=$((c + 1))
                        FORM_ERROR=""
                    fi
                elif [[ "$KEY" == SPACE ]]; then
                    ((focus == n)) && return 1
                    _form_submit && return 0
                fi
                ;;
            ENTER)
                ((focus == n)) && return 1
                _form_submit && return 0
                ;;
            ESC) return 1 ;;
            CTRL_C) ui_confirm_quit ;;
            RESIZE | CTRL_L) ui_force_redraw ;;
            EOF) return 255 ;;
        esac
    done
}

_form_submit() {
    [[ -n "$FORM_VALIDATE" ]] || return 0
    FORM_ERROR=""
    FORM_ERROR_FIELD=""
    "$FORM_VALIDATE" && return 0
    if [[ "$FORM_ERROR_FIELD" =~ ^[0-9]+$ ]] && ((FORM_ERROR_FIELD < ${#FORM_LABELS[@]})); then
        focus=$FORM_ERROR_FIELD
        cursor[focus]=${#FORM_VALUES[focus]}
    fi
    [[ -n "$FORM_ERROR" ]] || FORM_ERROR="Please check the values above."
    return 1
}

ui_input() {
    local title="$1" text="$2" label="$3" def="$4" type="${5:-text}" help="${6:-}"
    local saved_validate="${FORM_VALIDATE_INPUT:-}"
    form_reset
    form_add "$label" "$def" "$type" "$help"
    FORM_VALIDATE="$saved_validate"
    ui_form "$title" "$text"
    local rc=$?
    UI_RESULT="${FORM_VALUES[0]}"
    return "$rc"
}
