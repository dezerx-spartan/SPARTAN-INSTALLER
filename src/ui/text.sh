# shellcheck shell=bash
# Text layout for dialogs: word wrapping, inline style tags and truncation.
#
# Dialog text may contain these tags (they take no space on screen):
#   {b} bold   {d} muted   {a} accent   {ok} green   {w} yellow   {e} red   {/} normal
# Untrusted strings (API messages, file contents) go through tx first so they
# cannot inject tags.

declare -a WRAP_LINES=()

# tx <string> - neutralises tag braces in text that did not come from us.
tx() {
    local s="$1"
    s="${s//\{/(}"
    s="${s//\}/)}"
    printf '%s' "$s"
}

# text_strip <string> - prints the string without tags.
text_strip() {
    local v="$1"
    v="${v//\{b\}/}"
    v="${v//\{d\}/}"
    v="${v//\{a\}/}"
    v="${v//\{ok\}/}"
    v="${v//\{w\}/}"
    v="${v//\{e\}/}"
    v="${v//\{\/\}/}"
    printf '%s' "$v"
}

# text_vlen <string> - visible length (tags excluded). Result in TEXT_VLEN.
text_vlen() {
    local v="$1"
    v="${v//\{b\}/}"
    v="${v//\{d\}/}"
    v="${v//\{a\}/}"
    v="${v//\{ok\}/}"
    v="${v//\{w\}/}"
    v="${v//\{e\}/}"
    v="${v//\{\/\}/}"
    TEXT_VLEN=${#v}
}

# text_render <tagged line> <base style> - converts tags to escape sequences.
# Result in TEXT_OUT.
text_render() {
    local s="$1" base="$2"
    s="${s//\{b\}/$T_B}"
    s="${s//\{d\}/$T_D}"
    s="${s//\{a\}/$T_A}"
    s="${s//\{ok\}/$T_OK}"
    s="${s//\{w\}/$T_W}"
    s="${s//\{e\}/$T_E}"
    s="${s//\{\/\}/$base}"
    TEXT_OUT="${base}${s}${base}"
}

# text_trunc <plain string> <width> - shortens with an ellipsis. Result in TEXT_OUT.
text_trunc() {
    local s="$1" w="$2"
    if ((${#s} <= w)); then
        TEXT_OUT="$s"
    elif ((w <= 1)); then
        TEXT_OUT="${s:0:w}"
    else
        TEXT_OUT="${s:0:w-1}${G_ELLIPSIS}"
    fi
}

# text_trunc_left <plain string> <width> - keeps the end ("…/var/www/spartan").
text_trunc_left() {
    local s="$1" w="$2"
    if ((${#s} <= w)); then
        TEXT_OUT="$s"
    else
        TEXT_OUT="${G_ELLIPSIS}${s: -$((w - 1))}"
    fi
}

# text_wrap <width> <text> - wraps tagged text into WRAP_LINES.
# Leading spaces are kept, and list items ("- ", "* ", "1. ") get a hanging
# indent so continuation lines line up with the item text.
text_wrap() {
    local width="$1" text="$2"
    WRAP_LINES=()
    ((width < 8)) && width=8

    local para
    while IFS= read -r para || [[ -n "$para" ]]; do
        if [[ -z "${para//[[:space:]]/}" ]]; then
            WRAP_LINES+=("")
            continue
        fi
        local lead="${para%%[![:space:]]*}"
        local body="${para#"$lead"}"
        local hang="$lead"
        if [[ "$body" =~ ^([-*•]|[0-9]+\.)[[:space:]]+ ]]; then
            local marker="${BASH_REMATCH[0]}"
            text_vlen "$marker"
            printf -v hang '%*s' $((${#lead} + TEXT_VLEN)) ''
        fi

        local line="$lead" linelen=${#lead} open="" word wl
        local -a words
        # Split on single spaces with a non-whitespace IFS, so runs of spaces
        # (column alignment) survive as empty words.
        IFS=$'\x1f' read -ra words <<<"${body// /$'\x1f'}"
        local first=1
        for word in "${words[@]}"; do
            text_vlen "$word"
            wl=$TEXT_VLEN
            if ((!first)) && ((linelen + 1 + wl > width)); then
                WRAP_LINES+=("$line")
                line="${hang}${open}"
                linelen=${#hang}
                first=1
            fi
            # A single word longer than the line is split hard (paths, URLs).
            if ((wl > width - ${#hang})) && [[ "$word" != *"{"* ]]; then
                while ((wl > width - ${#hang})); do
                    local room=$((width - linelen - (first ? 0 : 1)))
                    ((room < 1)) && { WRAP_LINES+=("$line"); line="$hang"; linelen=${#hang}; first=1; room=$((width - linelen)); }
                    if ((first)); then line+="${word:0:room}"; else line+=" ${word:0:room}"; fi
                    WRAP_LINES+=("$line")
                    word="${word:room}"
                    wl=${#word}
                    line="$hang"
                    linelen=${#hang}
                    first=1
                done
                [[ -z "$word" ]] && continue
            fi
            if ((first)); then
                line+="$word"
                linelen=$((linelen + wl))
            else
                line+=" $word"
                linelen=$((linelen + 1 + wl))
            fi
            first=0
            # Remember the style that is still open so the next line continues it.
            if [[ "$word" == *"{"* ]]; then
                local t="${word##*\{}"
                t="${t%%\}*}"
                case "$t" in
                    /) open="" ;;
                    b | d | a | ok | w | e) open="{$t}" ;;
                esac
            fi
        done
        WRAP_LINES+=("$line")
    done <<<"$text"
}
