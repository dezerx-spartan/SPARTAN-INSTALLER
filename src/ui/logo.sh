# shellcheck shell=bash
# The DX mark as a background watermark (bottom right, like the AMP installer).
#
# The bitmaps were sampled from the official logo PNG: D = the white "D",
# X = the blue strokes, . = transparent. Two vertical pixels share one
# character cell using half blocks, so pixels come out roughly square.

LOGO_LARGE=(
    "DDDDDDDDDDDDDDD..............XXXXXXX"
    "DDDDDDDDDDDDDDDD............XXXXXXX."
    "DDDDDDDDDDDDDDDDD..........XXXXXXX.."
    "DDDDDDDDDDDDDDDDDD........XXXXXXX..."
    "DDDD.........DDDDDD......XXXXXXX...."
    "DDDD..........DDDDDD....XXXXXXX....."
    "DDDD...........DDDDDD..XXXXXXX......"
    "DDDD............DDDDDD.XXXXXX......."
    "DDDD.............DDDDDD.XXXX........"
    "DDDD.............DDDDDDD.XX........."
    "DDDD..............DDDDDDD..........."
    "DDDD..............DDDDDDD..........."
    "DDDD.............DDDDDDD.XX........."
    "DDDD............DDDDDDD.XXXX........"
    "DDDD...........DDDDDDD.XXXXXX......."
    "DDDD..........DDDDDDD..XXXXXXX......"
    "DDDD.........DDDDDDD....XXXXXXX....."
    "DDDDDDDDDDDDDDDDDDD.....XXXXXXXX...."
    "DDDDDDDDDDDDDDDDDD.......XXXXXXXX..."
    "DDDDDDDDDDDDDDDDD.........XXXXXXXX.."
    "DDDDDDDDDDDDDDDD...........XXXXXXXX."
    "DDDDDDDDDDDDDD..............XXXXXXXX"
)

LOGO_SMALL=(
    "DDDDDDDDDD.........XXXXX"
    "DDDDDDDDDDD.......XXXXX."
    "DDDDDDDDDDDD.....XXXXX.."
    "DDD......DDDD...XXXXX..."
    "DDD.......DDDD.XXXXX...."
    "DDD........DDDD.XXX....."
    "DDD.........DDDD.X......"
    "DDD.........DDDD.X......"
    "DDD........DDDD.XXX....."
    "DDD.......DDDD.XXXXX...."
    "DDD......DDDD...XXXXX..."
    "DDDDDDDDDDDD.....XXXXX.."
    "DDDDDDDDDDD.......XXXXX."
    "DDDDDDDDDD.........XXXXX"
)

# The same mark, small enough for the 3-row header bar (11 x 6 pixels).
LOGO_MINI=(
    "DDDDD...XXX"
    "D...DD.XXX."
    "D....DDX..."
    "D....DDX..."
    "D...DD.XXX."
    "DDDDD...XXX"
)

declare -a LOGO_ROWS=()
declare -a HEADER_LOGO_ROWS=()
LOGO_CACHE_KEY=""
HEADER_LOGO_KEY=""

# logo_render <fg D> <fg X> <bg empty> <bg D> <bg X> <bitmap name> <output array name>
logo_render() {
    local fd="$1" fx="$2" bg="$3" bgd="$4" bgx="$5"
    local -n bmp="$6" logo_out="$7"
    logo_out=()
    local y x top bot line ch
    for ((y = 0; y < ${#bmp[@]}; y += 2)); do
        local row_a="${bmp[y]}" row_b="${bmp[y + 1]:-}"
        line=""
        for ((x = 0; x < ${#row_a}; x++)); do
            top="${row_a:x:1}"
            bot="${row_b:x:1}"
            [[ -z "$bot" ]] && bot="."
            if [[ "$top" == "." && "$bot" == "." ]]; then
                line+="${bg} "
            elif [[ "$top" == "$bot" ]]; then
                ch="$fd"
                [[ "$top" == X ]] && ch="$fx"
                line+="${bg}${ch}${G_FULL}"
            elif [[ "$bot" == "." ]]; then
                ch="$fd"
                [[ "$top" == X ]] && ch="$fx"
                line+="${bg}${ch}${G_HALF_UP}"
            elif [[ "$top" == "." ]]; then
                ch="$fd"
                [[ "$bot" == X ]] && ch="$fx"
                line+="${bg}${ch}${G_HALF_DOWN}"
            else
                # Different colours in one cell: top as foreground, bottom as background.
                local tfg="$fd" bbg="$bgd"
                [[ "$top" == X ]] && tfg="$fx"
                [[ "$bot" == X ]] && bbg="$bgx"
                line+="${bbg}${tfg}${G_HALF_UP}"
            fi
        done
        logo_out+=("$line")
    done
}

logo_mini_available() {
    ((UI_UTF8)) && ((UI_DEPTH == 24 || UI_DEPTH == 256)) && ((HEADER_H == 3))
}

# Draws the small mark at <row> <col> on the header bar.
ui_draw_header_logo() {
    local r="$1" c="$2" i
    if [[ "$HEADER_LOGO_KEY" != "$UI_DEPTH" ]]; then
        logo_render "$(_ui_fg hdrd)" "$(_ui_fg hdrx)" "$(_ui_bg accent)" "$(_ui_bg hdrd)" "$(_ui_bg hdrx)" LOGO_MINI HEADER_LOGO_ROWS
        HEADER_LOGO_KEY="$UI_DEPTH"
    fi
    for ((i = 0; i < ${#HEADER_LOGO_ROWS[@]}; i++)); do
        FB+=$'\e['"$((r + i));${c}H"$'\e[0m'"${HEADER_LOGO_ROWS[i]}"
    done
}

ui_draw_logo() {
    ((UI_UTF8)) || return 0
    ((UI_DEPTH == 24 || UI_DEPTH == 256)) || return 0
    [[ -z "${SPARTAN_NO_LOGO:-}" ]] || return 0

    # Only where it fits beside a centred standard-width dialog, so the
    # watermark never hides behind (or shows through) a dialog and stays in
    # the same place on every screen.
    local name="" w h
    if ((TERM_COLS >= 2 * 36 + UI_WIDTH + 12 && TERM_ROWS >= 30)); then
        name="LOGO_LARGE"
    elif ((TERM_COLS >= 2 * 24 + UI_WIDTH + 12 && TERM_ROWS >= 24)); then
        name="LOGO_SMALL"
    else
        return 0
    fi

    if [[ "$LOGO_CACHE_KEY" != "$name|$UI_DEPTH" ]]; then
        logo_render "$(_ui_fg logod)" "$(_ui_fg logox)" "$(_ui_bg root)" "$(_ui_bg logod)" "$(_ui_bg logox)" "$name" LOGO_ROWS
        LOGO_CACHE_KEY="$name|$UI_DEPTH"
    fi

    local -n bmp_ref="$name"
    w=${#bmp_ref[0]}
    h=${#LOGO_ROWS[@]}
    local r0=$((TERM_ROWS - 2 - h)) c0=$((TERM_COLS - 3 - w)) i
    for ((i = 0; i < h; i++)); do
        FB+=$'\e['"$((r0 + i));${c0}H"$'\e[0m'"${LOGO_ROWS[i]}"
    done
}
