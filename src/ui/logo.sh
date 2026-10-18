# shellcheck shell=bash
# The DezerX mark at the top of the screen, sampled from the official logo at
# two sizes (5 and 4 terminal rows). Each bitmap row is one pixel row; two
# share a character cell through half blocks, so the pixels come out square.
#
#   .      transparent
#   A..Z   shades of the white D (including its anti-aliased edges)
#   a..z   shades of the blue X
#
# LOGO_PAL holds "r g b alpha" for each shade. 24-bit and 256 colour terminals
# blend the edges into the background; 16 colours get plain white and blue,
# and terminals without UTF-8 get the ASCII version below.

declare -A LOGO_PAL=(
    [A]="238 239 242 23" [B]="223 230 240 64" [C]="243 245 249 61" [D]="244 244 247 77"
    [E]="238 242 246 107" [F]="245 246 248 129" [G]="244 245 248 155" [H]="228 233 241 191"
    [I]="246 246 249 188" [J]="205 215 230 223" [K]="245 245 248 197" [L]="223 229 239 226"
    [M]="236 238 244 223" [N]="247 247 249 221" [O]="247 247 249 234" [P]="228 233 241 255"
    [Q]="247 247 249 244" [R]="247 247 249 255" [a]="5 106 242 79" [b]="7 151 242 72"
    [c]="5 69 241 112" [d]="4 104 245 108" [e]="34 165 247 93" [f]="8 161 245 106"
    [g]="2 76 248 147" [h]="6 137 242 129" [i]="6 162 246 135" [j]="12 117 246 153"
    [k]="6 152 246 153" [l]="24 159 247 157" [m]="4 152 248 182" [n]="2 70 249 255"
    [o]="1 109 252 251" [p]="1 128 252 251" [q]="1 146 252 255" [r]="1 161 253 252"
)

LOGO_5=(
    "PRRRRRRMD.....brrqh"
    "PPONNNORRE...errqd."
    "PPB....GRRF.frrpa.."
    "RPB.....GRRFmqoa..."
    "RRC......FRRGja...."
    "RRC......GRRGkb...."
    "RRC....AKRREmrqb..."
    "RRECCCDMRQD.hqqpa.."
    "RPPQRRRROB...doood."
    "LJLNNNNGA.....cnnnc"
)

LOGO_4=(
    "PRRRRQG....frqh"
    "PLFFFIRH..irqd."
    "QH....GRKeqpa.."
    "RI.....GRKja..."
    "RI.....HRKlb..."
    "RK...AKRGfrqb.."
    "RNHIKORF..jpod."
    "LJMNNLE....gnnc"
)

# The same mark in ASCII; "@" separates the D (white) from the X (blue).
LOGO_ASCII_5=(
    ' _______@    ____'
    '|  ___  \@  /   /'
    '| |   \  \@/   /'
    '| |___/  /@\   \'
    '|_______/@  \___\'
)

LOGO_ASCII_4=(
    ' ______@   ___'
    '| |   \ \@/  /'
    '| |   / /@\  \'
    '|_|__/_/@  \__\'
)

declare -a LOGO_ROWS=()
LOGO_W=0
LOGO_KEY=""

# _logo_c256 <r> <g> <b> <D|x> - xterm-256 colour for a shade. The D is
# neutral and uses the grey ramp; the X takes the nearest blue of the colour
# cube (plain nearest-colour matching turns its dark edges teal).
_logo_c256() {
    if [[ "$4" == x ]]; then
        local -a lv=(0 95 135 175 215 255)
        local gc bc d bd=-1
        for ((gc = 0; gc < 5; gc++)); do
            for ((bc = gc + 1; bc < 6; bc++)); do
                d=$(($1 * $1 + ($2 - lv[gc]) ** 2 + ($3 - lv[bc]) ** 2))
                if ((bd < 0 || d < bd)); then
                    bd=$d
                    REPLY=$((16 + gc * 6 + bc))
                fi
            done
        done
        return
    fi
    local v=$((($1 + $2 + $3) / 3)) gi
    if ((v > 246)); then
        REPLY=231
    elif ((v < 4)); then
        REPLY=16
    else
        gi=$(((v - 3) / 10))
        ((gi > 23)) && gi=23
        REPLY=$((232 + gi))
    fi
}

# logo_render <rows> - draws LOGO_<rows> for the current terminal into
# LOGO_ROWS (one printable string per terminal row) and sets LOGO_W.
logo_render() {
    local size="$1"
    [[ "$LOGO_KEY" == "${size}|${UI_DEPTH}|${UI_UTF8}" ]] && return 0
    LOGO_KEY="${size}|${UI_DEPTH}|${UI_UTF8}"
    LOGO_ROWS=()

    if ((!UI_UTF8)); then
        local -n art="LOGO_ASCII_${size}"
        local row fd="" fx=""
        if ((UI_DEPTH)); then
            fd=$'\e[0;1m'"$(_ui_fg bright)$(_ui_bg root)"
            fx=$'\e[0;1m'"$(_ui_fg accent)$(_ui_bg root)"
        fi
        LOGO_W=0
        for row in "${art[@]}"; do
            LOGO_ROWS+=($'\e[0m'"${fd}${row%%@*}${fx}${row#*@}")
            ((${#row} - 1 > LOGO_W)) && LOGO_W=$((${#row} - 1))
        done
        return 0
    fi

    # Style of each shade at this depth: foreground for its half of a
    # cell, background when it shares the cell with another colour. Shades
    # left out of fg[] are drawn as background.
    local -A fg=() bg=()
    local k r g b a rr=17 rg=21 rb=28 root_bg
    read -r rr rg rb <<<"${UI_RGB[root]:-17 21 28}"
    root_bg="$(_ui_bg root)"
    for k in "${!LOGO_PAL[@]}"; do
        read -r r g b a <<<"${LOGO_PAL[$k]}"
        local fam=D
        [[ "$k" == [a-z] ]] && fam=x
        case "$UI_DEPTH" in
            24 | 256)
                r=$(((r * a + rr * (255 - a) + 127) / 255))
                g=$(((g * a + rg * (255 - a) + 127) / 255))
                b=$(((b * a + rb * (255 - a) + 127) / 255))
                if ((UI_DEPTH == 24)); then
                    fg[$k]=$'\e[38;2;'"${r};${g};${b}m"
                    bg[$k]=$'\e[48;2;'"${r};${g};${b}m"
                else
                    _logo_c256 "$r" "$g" "$b" "$fam"
                    fg[$k]=$'\e[38;5;'"${REPLY}m"
                    bg[$k]=$'\e[48;5;'"${REPLY}m"
                fi
                ;;
            16)
                ((a >= 128)) || continue
                if [[ "$fam" == x ]]; then
                    fg[$k]=$'\e[1;34m' bg[$k]=$'\e[44m'
                else
                    fg[$k]=$'\e[1;37m' bg[$k]=$'\e[47m'
                fi
                ;;
            *)
                ((a >= 128)) || continue
                fg[$k]=$'\e[0m' bg[$k]=$'\e[0m'
                ;;
        esac
    done

    local -n bmp="LOGO_${size}"
    local y x t u cell prev line
    LOGO_W=${#bmp[0]}
    for ((y = 0; y < ${#bmp[@]}; y += 2)); do
        line=$'\e[0m' prev=""
        for ((x = 0; x < LOGO_W; x++)); do
            t="${bmp[y]:x:1}"
            u="${bmp[y + 1]:x:1}"
            [[ -n "${fg[$t]:-}" ]] || t="."
            [[ -n "${u}" && -n "${fg[$u]:-}" ]] || u="."
            if [[ "$t" == . && "$u" == . ]]; then
                cell="${root_bg}" t=" "
            elif [[ "$t" == . ]]; then
                cell="${root_bg}${fg[$u]}" t="$G_HALF_DOWN"
            elif [[ "$u" == . ]]; then
                cell="${root_bg}${fg[$t]}" t="$G_HALF_UP"
            elif [[ "${fg[$t]}" == "${fg[$u]}" ]]; then
                cell="${root_bg}${fg[$t]}" t="$G_FULL"
            else
                cell="${bg[$u]}${fg[$t]}" t="$G_HALF_UP"
            fi
            # Only write a style when it differs from the previous cell's.
            [[ "$cell" == "$prev" ]] || line+="$cell"
            prev="$cell"
            line+="$t"
        done
        LOGO_ROWS+=("$line")
    done
}
