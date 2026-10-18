# shellcheck shell=bash
# One palette for every screen, rendered at the colour depth the terminal supports.
#
#   24-bit  COLORTERM=truecolor|24bit
#   256     TERM=*256color* (the default over SSH, where COLORTERM is not forwarded)
#   16      the Linux console and unknown terminals
#   none    NO_COLOR or --no-color

UI_DEPTH=256
UI_UTF8=1

# name           truecolor        256   16 (fg code)
_ui_palette() {
    cat <<'EOF'
root         17 21 28        233   0
panel        28 34 44        235   0
input        14 18 24        232   0
shadow       7 9 12          16    0
text         226 232 240     254   7
bright       255 255 255     231   7
muted        139 150 168     246   7
dim          79 90 107       241   8
accent       45 140 255      33    4
accentdim    23 52 89        24    4
accentfg     255 255 255     231   7
ok           58 217 138      42    2
warn         255 184 77      215   3
err          255 97 97       203   1
EOF
}

declare -A UI_RGB=()
declare -A UI_C256=()
declare -A UI_C16=()

_ui_fg() {
    case "$UI_DEPTH" in
        24) printf '\e[38;2;%sm' "${UI_RGB[$1]// /;}" ;;
        256) printf '\e[38;5;%sm' "${UI_C256[$1]}" ;;
        16)
            local c="${UI_C16[$1]}"
            if ((c >= 8)); then printf '\e[1;3%sm' $((c - 8)); else printf '\e[3%sm' "$c"; fi
            ;;
        *) printf '' ;;
    esac
}

_ui_bg() {
    case "$UI_DEPTH" in
        24) printf '\e[48;2;%sm' "${UI_RGB[$1]// /;}" ;;
        256) printf '\e[48;5;%sm' "${UI_C256[$1]}" ;;
        16) printf '\e[4%sm' $((${UI_C16[$1]} % 8)) ;;
        *) printf '' ;;
    esac
}

ui_detect_depth() {
    if ((UI_NO_COLOR)) || [[ -n "${NO_COLOR:-}" ]]; then
        UI_DEPTH=0
    elif [[ "${COLORTERM:-}" == *truecolor* || "${COLORTERM:-}" == *24bit* ]]; then
        UI_DEPTH=24
    elif [[ "${TERM:-}" == *256col* || "${TERM:-}" == xterm-kitty || "${TERM:-}" == alacritty* || "${TERM:-}" == *ghostty* || "${TERM:-}" == wezterm ]]; then
        UI_DEPTH=256
    else
        UI_DEPTH=16
    fi
}

# Glyphs follow the locale the user started us with (SPARTAN_USER_LOCALE is
# captured before the installer switches its own locale to C.UTF-8). The Linux
# console fonts lack braille and check marks, so it gets the ASCII set.
ui_detect_utf8() {
    UI_UTF8=0
    ((FORCE_ASCII)) && return 0
    [[ "${TERM:-}" == linux ]] && return 0
    local lc="${SPARTAN_USER_LOCALE:-}"
    [[ "${lc,,}" == *utf-8* || "${lc,,}" == *utf8* ]] && UI_UTF8=1
    return 0
}

ui_theme_init() {
    local name r g b c256 c16
    while read -r name r g b c256 c16; do
        [[ -n "$name" ]] || continue
        UI_RGB[$name]="$r $g $b"
        UI_C256[$name]="$c256"
        UI_C16[$name]="$c16"
    done < <(_ui_palette)

    ui_detect_depth
    ui_detect_utf8
    ui_glyphs_init

    local R=$'\e[0m'
    if ((UI_DEPTH == 0)); then
        S_ROOT=$R S_HEAD=$'\e[0;7;1m' S_HEAD_META=$R S_FOOT=$'\e[0;7m'
        S_PANEL=$R S_MUTED=$'\e[0;2m' S_DIM=$'\e[0;2m' S_BORDER=$R S_TITLE=$'\e[0;1m'
        S_BTN=$R S_BTN_ON=$'\e[0;7;1m' S_SEL=$'\e[0;7m' S_SEL_OFF=$'\e[0;4m' S_INPUT=$'\e[0;4m' S_INPUT_ON=$'\e[0;4;1m'
        S_INPUT_OFF=$'\e[0;2m' S_OK=$'\e[0;1m' S_WARN=$'\e[0;1m' S_ERR=$'\e[0;1m' S_ACCENT=$'\e[0;1m' S_BOLD=$'\e[0;1m'
        S_SHADOW=$R S_SHADE=$R S_BAR=$'\e[0;1m' S_BAR_BG=$'\e[0;2m' S_DANGER=$'\e[0;1m' S_CURSOR=$'\e[0;7m'
        T_B=$'\e[1m' T_D=$'\e[22;2m' T_A=$'\e[1m' T_OK=$'\e[1m' T_W=$'\e[1m' T_E=$'\e[1m'
        return 0
    fi

    local f_text f_bright f_muted f_dim f_accent f_accentfg f_ok f_warn f_err f_root f_shadow
    local b_root b_panel b_input b_shadow b_accent b_accentdim
    f_text="$(_ui_fg text)"; f_bright="$(_ui_fg bright)"; f_muted="$(_ui_fg muted)"; f_dim="$(_ui_fg dim)"
    f_accent="$(_ui_fg accent)"; f_accentfg="$(_ui_fg accentfg)"; f_ok="$(_ui_fg ok)"; f_warn="$(_ui_fg warn)"
    f_err="$(_ui_fg err)"; f_root="$(_ui_fg root)"; f_shadow="$(_ui_fg shadow)"
    b_root="$(_ui_bg root)"; b_panel="$(_ui_bg panel)"; b_input="$(_ui_bg input)"; b_shadow="$(_ui_bg shadow)"
    b_accent="$(_ui_bg accent)"; b_accentdim="$(_ui_bg accentdim)"

    if ((UI_DEPTH == 16)); then
        # Eight background colours only: panels share the black root and are
        # framed by their border, shadows are left out.
        b_panel="$b_root"
        b_input=$'\e[44m'
        b_shadow="$b_root"
        b_accentdim=$'\e[44m'
    fi

    S_ROOT="${R}${f_text}${b_root}"
    S_HEAD="${R}${f_accentfg}${b_accent}"$'\e[1m'
    S_HEAD_META="${R}${f_muted}${b_root}"
    S_FOOT="${R}${f_accentfg}${b_accent}"
    S_PANEL="${R}${f_text}${b_panel}"
    S_MUTED="${R}${f_muted}${b_panel}"
    S_DIM="${R}${f_dim}${b_panel}"
    S_BORDER="${R}${f_accent}${b_panel}"
    S_TITLE="${R}${f_accent}${b_panel}"$'\e[1m'
    S_BTN="${R}${f_muted}${b_panel}"
    S_BTN_ON="${R}${f_accentfg}${b_accent}"$'\e[1m'
    S_SEL="${R}${f_accentfg}${b_accent}"
    S_SEL_OFF="${R}${f_text}${b_accentdim}"
    S_INPUT="${R}${f_text}${b_input}"
    S_INPUT_ON="${R}${f_bright}${b_accentdim}"
    S_INPUT_OFF="${R}${f_dim}${b_input}"
    S_OK="${R}${f_ok}${b_panel}"
    S_WARN="${R}${f_warn}${b_panel}"
    S_ERR="${R}${f_err}${b_panel}"
    S_ACCENT="${R}${f_accent}${b_panel}"
    S_BOLD="${R}${f_bright}${b_panel}"$'\e[1m'
    S_SHADOW="${R}${f_shadow}${b_shadow}"
    S_SHADE="${R}${f_shadow}${b_root}"
    S_BAR="${R}${f_accent}${b_panel}"
    S_BAR_BG="${R}${f_dim}${b_panel}"
    S_DANGER="${R}${f_err}${b_panel}"
    S_CURSOR="${R}${f_root}"$'\e[48;5;254m'
    ((UI_DEPTH == 24)) && S_CURSOR="${R}${f_root}"$'\e[48;2;226;232;240m'
    ((UI_DEPTH == 16)) && S_CURSOR=$'\e[0;7m'

    # Inline text tags (fg and weight only, so the panel background is kept).
    T_B="${f_bright}"$'\e[1m'
    T_D=$'\e[22m'"${f_muted}"
    T_A="${f_accent}"$'\e[1m'
    T_OK=$'\e[22m'"${f_ok}"
    T_W=$'\e[22m'"${f_warn}"
    T_E=$'\e[22m'"${f_err}"
}

# _ui_rgb256 <r> <g> <b> - nearest xterm-256 colour (6x6x6 cube or grey ramp).
_ui_rgb256() {
    local v ci=() d_cube=0 grey gi gv d
    for v in "$1" "$2" "$3"; do
        if ((v < 48)); then ci+=(0); elif ((v < 115)); then ci+=(1); else ci+=($(((v - 35) / 40))); fi
        d=$((v - (ci[-1] ? ci[-1] * 40 + 55 : 0)))
        d_cube=$((d_cube + d * d))
    done
    grey=$((($1 + $2 + $3) / 3))
    gi=$(((grey - 3) / 10)); ((gi < 0)) && gi=0; ((gi > 23)) && gi=23
    gv=$((gi * 10 + 8))
    local dg=$((($1 - gv) ** 2 + ($2 - gv) ** 2 + ($3 - gv) ** 2))
    if ((dg < d_cube)); then REPLY=$((232 + gi)); else REPLY=$((16 + ci[0] * 36 + ci[1] * 6 + ci[2])); fi
}

# ui_fade_init <cells> - HEAD_FADE[0..cells-1]: styles easing from the accent
# (index 0, next to the title block) into the background. 24-bit and 256
# colour terminals get a background gradient; 16 colours get shade glyphs.
declare -a HEAD_FADE=()
HEAD_FADE_KEY=""
ui_fade_init() {
    local n="$1" i t e r g b
    [[ "$HEAD_FADE_KEY" != "$n|$UI_DEPTH|$UI_UTF8" ]] || return 0
    HEAD_FADE_KEY="$n|$UI_DEPTH|$UI_UTF8"
    HEAD_FADE=()
    local -a a z
    read -ra a <<<"${UI_RGB[accent]}"
    read -ra z <<<"${UI_RGB[root]}"
    for ((i = 0; i < n; i++)); do
        # smoothstep over 0..1000, so both ends blend in without a visible edge
        t=$(((i + 1) * 1000 / (n + 1)))
        e=$((t * t * (3000 - 2 * t) / 1000000))
        r=$((a[0] + (z[0] - a[0]) * e / 1000))
        g=$((a[1] + (z[1] - a[1]) * e / 1000))
        b=$((a[2] + (z[2] - a[2]) * e / 1000))
        case "$UI_DEPTH" in
            24) HEAD_FADE+=($'\e[0;48;2;'"$r;$g;${b}m ") ;;
            256) _ui_rgb256 "$r" "$g" "$b"; HEAD_FADE+=($'\e[0;48;5;'"${REPLY}m ") ;;
            16)
                local gl=" "
                if ((e < 250)); then gl="$G_SHADE1"; elif ((e < 500)); then gl="$G_SHADE2"; elif ((e < 750)); then gl="$G_SHADE3"; fi
                HEAD_FADE+=("$(_ui_fg accent)$(_ui_bg root)${gl}")
                ;;
            *) HEAD_FADE+=($'\e[0m ') ;;
        esac
    done
}

ui_glyphs_init() {
    if ((UI_UTF8)); then
        G_H='─' G_V='│' G_TL='┌' G_TR='┐' G_BL='└' G_BR='┘' G_TITLE_L='┤' G_TITLE_R='├'
        G_OK='✔' G_FAIL='✘' G_WARN='!' G_PENDING='○' G_SKIP='–' G_DOT='·' G_BULLET='•'
        G_NEXT='›' G_BACK='‹' G_RADIO_ON='●' G_RADIO_OFF='○' G_CHECK_ON='✔' G_CHECK_OFF=' '
        G_BAR_ON='━' G_BAR_OFF='─' G_ELLIPSIS='…' G_UP='▲' G_DOWN='▼' G_MASK='•'
        G_HALF_UP='▀' G_HALF_DOWN='▄' G_FULL='█' G_SHADE1='▓' G_SHADE2='▒' G_SHADE3='░'
        G_SPIN=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
        G_ARROWS='↑↓'
    else
        G_H='-' G_V='|' G_TL='+' G_TR='+' G_BL='+' G_BR='+' G_TITLE_L='[' G_TITLE_R=']'
        G_OK='+' G_FAIL='x' G_WARN='!' G_PENDING='.' G_SKIP='-' G_DOT='-' G_BULLET='*'
        G_NEXT='>' G_BACK='<' G_RADIO_ON='*' G_RADIO_OFF=' ' G_CHECK_ON='x' G_CHECK_OFF=' '
        G_BAR_ON='#' G_BAR_OFF='-' G_ELLIPSIS='~' G_UP='^' G_DOWN='v' G_MASK='*'
        G_HALF_UP='' G_HALF_DOWN='' G_FULL='#' G_SHADE1='#' G_SHADE2='=' G_SHADE3='-'
        G_SPIN=('|' '/' '-' '\')
        G_ARROWS='Arrows'
    fi
}
