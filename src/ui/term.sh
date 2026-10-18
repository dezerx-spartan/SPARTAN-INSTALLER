# shellcheck shell=bash
# Terminal control for the full-screen interface: size, raw keyboard input,
# alternate screen and restoring the user's terminal on every exit path.

TTY_FD=""
TERM_ROWS=24
TERM_COLS=80
TERM_ACTIVE=0
TERM_STTY=""
TERM_RESIZED=0
KEY=""
KEY_CHAR=""

term_open() {
    [[ -n "$TTY_FD" ]] && return 0
    { exec {TTY_FD}<>/dev/tty; } 2>/dev/null || { TTY_FD=""; return 1; }
}

term_size() {
    local s=""
    [[ -n "$TTY_FD" ]] && s="$(stty size <&"$TTY_FD" 2>/dev/null)"
    local r="${s% *}" c="${s#* }"
    if [[ "$r" =~ ^[0-9]+$ && "$c" =~ ^[0-9]+$ ]] && ((r > 0 && c > 0)); then
        TERM_ROWS=$r
        TERM_COLS=$c
    fi
}

term_enter() {
    term_open || return 1
    TERM_STTY="$(stty -g <&"$TTY_FD" 2>/dev/null)"
    # No echo, keys arrive one at a time, Ctrl+C/Ctrl+Z/Ctrl+S reach us as
    # plain bytes instead of signals (the installer decides what they mean).
    stty -echo -icanon -isig -ixon -icrnl min 1 time 0 <&"$TTY_FD" 2>/dev/null
    printf '\e[?1049h\e[?25l\e[?7l\e[H' >&"$TTY_FD"
    TERM_ACTIVE=1
    trap 'TERM_RESIZED=1' WINCH
    term_size
}

term_leave() {
    ((TERM_ACTIVE)) || return 0
    TERM_ACTIVE=0
    printf '\e[0m\e[?7h\e[?25h\e[?1049l' 1>&"$TTY_FD" 2>/dev/null
    [[ -n "$TERM_STTY" ]] && stty "$TERM_STTY" <&"$TTY_FD" 2>/dev/null
    trap - WINCH
}

# Temporarily hand the terminal back (cooked mode, normal screen).
term_suspend() {
    ((TERM_ACTIVE)) || return 0
    printf '\e[0m\e[?7h\e[?25h\e[?1049l' >&"$TTY_FD"
    [[ -n "$TERM_STTY" ]] && stty "$TERM_STTY" <&"$TTY_FD" 2>/dev/null
}

term_resume() {
    ((TERM_ACTIVE)) || return 0
    stty -echo -icanon -isig -ixon -icrnl min 1 time 0 <&"$TTY_FD" 2>/dev/null
    printf '\e[?1049h\e[?25l\e[?7l' >&"$TTY_FD"
    term_size
}

# Keys are read with plain timed reads (no -n/-s/-d): bash switches the
# terminal into its own one-character mode for those, and that mode turns
# signal keys back on, so Ctrl+C would kill the installer instead of asking.
# A timed read keeps whatever arrived when it times out, so bytes are collected
# into TERM_INBUF and split into keys here.
TERM_INBUF=""

# _term_fill [timeout] - appends pending input to TERM_INBUF. Returns 1 on EOF.
_term_fill() {
    local chunk="" rc
    IFS= read -r -t "${1:-0.05}" chunk <&"$TTY_FD"
    rc=$?
    TERM_INBUF+="$chunk"
    ((rc == 0)) && TERM_INBUF+=$'\n'
    ((rc == 1)) && [[ -z "$chunk" ]] && return 1
    return 0
}

# term_read_key - waits for one key press and sets KEY to a name:
#   UP DOWN LEFT RIGHT HOME END PGUP PGDN DEL TAB BTAB ENTER ESC SPACE BACKSPACE
#   CTRL_C CTRL_U CTRL_W CTRL_L RESIZE IGNORE EOF CHAR (KEY_CHAR holds it)
term_read_key() {
    KEY=""
    KEY_CHAR=""
    while [[ -z "$TERM_INBUF" ]]; do
        if ((TERM_RESIZED)); then
            TERM_RESIZED=0
            term_size
            KEY="RESIZE"
            return 0
        fi
        _term_fill 0.05 || { KEY="EOF"; return 0; }
    done

    local k="${TERM_INBUF:0:1}"
    if [[ "$k" == $'\e' ]]; then
        # A lone Esc, or the start of a sequence that may still be arriving.
        [[ ${#TERM_INBUF} -eq 1 ]] && _term_fill 0.03
        local rest="${TERM_INBUF:1}" seq=""
        if [[ -z "$rest" ]]; then
            TERM_INBUF=""
            KEY="ESC"
            return 0
        fi
        if [[ "${rest:0:1}" == "[" || "${rest:0:1}" == "O" ]]; then
            local i c
            for ((i = 1; i < ${#rest}; i++)); do
                c="${rest:i:1}"
                [[ "$c" == [A-Za-z~] ]] && break
            done
            seq="${rest:0:i+1}"
        else
            # Alt+key arrives as Esc followed by the key: treat it as the key.
            TERM_INBUF="$rest"
            KEY="IGNORE"
            return 0
        fi
        TERM_INBUF="${TERM_INBUF:1+${#seq}}"
        [[ "$seq" =~ ^\[1\;[0-9]+([A-H])$ ]] && seq="[${BASH_REMATCH[1]}"
        case "$seq" in
            "[A" | "OA") KEY="UP" ;;
            "[B" | "OB") KEY="DOWN" ;;
            "[C" | "OC") KEY="RIGHT" ;;
            "[D" | "OD") KEY="LEFT" ;;
            "[H" | "OH" | "[1~" | "[7~") KEY="HOME" ;;
            "[F" | "OF" | "[4~" | "[8~") KEY="END" ;;
            "[5~") KEY="PGUP" ;;
            "[6~") KEY="PGDN" ;;
            "[3~") KEY="DEL" ;;
            "[Z") KEY="BTAB" ;;
            *) KEY="IGNORE" ;;
        esac
        return 0
    fi

    TERM_INBUF="${TERM_INBUF:1}"
    case "$k" in
        $'\r' | $'\n') KEY="ENTER" ;;
        $'\t') KEY="TAB" ;;
        " ") KEY="SPACE" KEY_CHAR=" " ;;
        $'\x7f' | $'\b') KEY="BACKSPACE" ;;
        $'\x03') KEY="CTRL_C" ;;
        $'\x04') KEY="CTRL_D" ;;
        $'\x15') KEY="CTRL_U" ;;
        $'\x17') KEY="CTRL_W" ;;
        $'\x0c') KEY="CTRL_L" ;;
        $'\x01') KEY="HOME" ;;
        $'\x05') KEY="END" ;;
        *)
            if [[ "$k" == [[:print:]] ]]; then
                KEY="CHAR"
                KEY_CHAR="$k"
            else
                KEY="IGNORE"
            fi
            ;;
    esac
    return 0
}
