UI_FD=1

lp() { printf '%s\n' "$*" >&"$UI_FD"; }

L_B="" L_D="" L_A="" L_OK="" L_W="" L_E="" L_R=""

line_styles_init() {
    if [[ "$UI_MODE" != plain ]] && ((UI_DEPTH != 0)); then
        L_B=$'\e[1m'
        L_D=$'\e[2m'
        L_A="$(_ui_fg accent)"$'\e[1m'
        L_OK="$(_ui_fg ok)"
        L_W="$(_ui_fg warn)"
        L_E="$(_ui_fg err)"
        L_R=$'\e[0m'
    fi
}

line_text() {
    local text="${1//\\n/$'\n'}" line
    text_wrap 76 "$text"
    for line in "${WRAP_LINES[@]}"; do
        line="${line//\{b\}/$L_B}"
        line="${line//\{d\}/$L_D}"
        line="${line//\{a\}/$L_A}"
        line="${line//\{ok\}/$L_OK}"
        line="${line//\{w\}/$L_W}"
        line="${line//\{e\}/$L_E}"
        line="${line//\{\/\}/$L_R}"
        printf '  %s%s\n' "$line" "$L_R" >&"$UI_FD"
    done
}

line_title() { printf '\n%s%s%s\n' "$L_A" "$1" "$L_R" >&"$UI_FD"; }

line_read() {
    local prompt="$1" silent="${2:-0}" v=""
    printf '%s' "$prompt" >&"$UI_FD"
    if ((silent)); then
        IFS= read -rs v <&"$TTY_FD" || return 255
        printf '\n' >&"$UI_FD"
    else
        IFS= read -r v <&"$TTY_FD" || return 255
    fi
    UI_RESULT="$v"
}

line_msgbox() {
    line_title "$1"
    line_text "$2"
    line_read "  Press Enter to continue " || return 255
    return 0
}

line_nav() {
    local label="${3:-Continue}"
    label="${label//$G_NEXT/}"
    label="${label//$G_BACK/}"
    label="$(trim "$label")"
    line_title "$1"
    line_text "$2"
    line_read "  ${label}? [Y/n/b(ack)] " || return 255
    case "${UI_RESULT,,}" in
        b | back | n | no) return 1 ;;
    esac
    return 0
}

line_confirm() {
    line_title "$1"
    line_text "$2"
    local def="${5:-yes}" hint="[Y/n]"
    [[ "$def" == no ]] && hint="[y/N]"
    line_read "  ${3:-Yes}? ${hint} " || return 255
    case "${UI_RESULT,,}" in
        y | yes) return 0 ;;
        n | no) return 1 ;;
        "") [[ "$def" == yes ]] && return 0 || return 1 ;;
    esac
    return 1
}

line_menu() {
    local title="$1" text="$2" def="$3"
    shift 3
    local -a tags=() labels=() descs=()
    while (($# >= 3)); do tags+=("$1") labels+=("$2") descs+=("$3"); shift 3; done
    local i defn=1
    for i in "${!tags[@]}"; do [[ "${tags[i]}" == "$def" ]] && defn=$((i + 1)); done
    while :; do
        line_title "$title"
        [[ -n "$text" ]] && line_text "$text"
        for i in "${!tags[@]}"; do
            printf '  %s%2d)%s %-14s %s%s%s\n' "$L_B" $((i + 1)) "$L_R" "${labels[i]}" "$L_D" "${descs[i]}" "$L_R" >&"$UI_FD"
        done
        line_read "  Choose 1-${#tags[@]}, b to go back [${defn}]: " || return 255
        local v="${UI_RESULT,,}"
        [[ -z "$v" ]] && v=$defn
        [[ "$v" == b || "$v" == back ]] && return 1
        if is_uint "$v" && ((v >= 1 && v <= ${#tags[@]})); then
            UI_RESULT="${tags[v - 1]}"
            return 0
        fi
        lp "  Please enter a number between 1 and ${#tags[@]}."
    done
}

line_checklist() {
    local title="$1" text="$2"
    shift 2
    local -a tags=() labels=() on=()
    while (($# >= 3)); do
        tags+=("$1") labels+=("$2")
        if is_true "$3"; then on+=(1); else on+=(0); fi
        shift 3
    done
    while :; do
        line_title "$title"
        [[ -n "$text" ]] && line_text "$text"
        local i
        for i in "${!tags[@]}"; do
            local mark=" "
            ((on[i])) && mark="x"
            printf '  %2d) [%s] %s\n' $((i + 1)) "$mark" "${labels[i]}" >&"$UI_FD"
        done
        line_read "  Numbers to toggle (e.g. 1 3), Enter to continue, b to go back: " || return 255
        local v="${UI_RESULT,,}"
        [[ "$v" == b || "$v" == back ]] && return 1
        if [[ -z "$v" ]]; then
            UI_RESULT=""
            for i in "${!tags[@]}"; do ((on[i])) && UI_RESULT+="${tags[i]} "; done
            UI_RESULT="${UI_RESULT% }"
            return 0
        fi
        local t
        for t in $v; do
            is_uint "$t" && ((t >= 1 && t <= ${#tags[@]})) && on[t - 1]=$((1 - on[t - 1]))
        done
    done
}

line_form() {
    local title="$1" text="$2" i
    while :; do
        line_title "$title"
        [[ -n "$text" ]] && line_text "$text"
        for i in "${!FORM_LABELS[@]}"; do
            ((${FORM_DISABLED[i]:-0})) && continue
            local cur="${FORM_VALUES[i]}" shown
            case "${FORM_TYPES[i]}" in
                password)
                    shown=""
                    [[ -n "$cur" ]] && shown="keep current"
                    line_read "  ${FORM_LABELS[i]}${shown:+ [${shown}]}: " 1 || return 255
                    [[ -n "$UI_RESULT" ]] && FORM_VALUES[i]="$UI_RESULT"
                    ;;
                choice)
                    line_read "  ${FORM_LABELS[i]} (${FORM_CHOICES[i]//|/, }) [${cur}]: " || return 255
                    if [[ -n "$UI_RESULT" ]]; then
                        local -a opts
                        local o matched=""
                        IFS='|' read -ra opts <<<"${FORM_CHOICES[i]}"
                        for o in "${opts[@]}"; do [[ "${o,,}" == "${UI_RESULT,,}"* ]] && matched="$o" && break; done
                        [[ -n "$matched" ]] && FORM_VALUES[i]="$matched"
                        [[ -n "$FORM_ON_CHANGE" ]] && "$FORM_ON_CHANGE"
                    fi
                    ;;
                *)
                    line_read "  ${FORM_LABELS[i]} [${cur}]: " || return 255
                    [[ -n "$UI_RESULT" ]] && FORM_VALUES[i]="$UI_RESULT"
                    ;;
            esac
        done
        if [[ -n "$FORM_VALIDATE" ]]; then
            FORM_ERROR=""
            if ! "$FORM_VALIDATE"; then
                lp "  ${L_E}${FORM_ERROR:-Please check the values.}${L_R}"
                continue
            fi
        fi
        return 0
    done
}
