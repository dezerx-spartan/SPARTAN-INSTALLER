# shellcheck shell=bash
# Run log (/var/log/spartan_installer.log) with secret masking and rotation.
#
# The log is created with mode 600: it records command output that can include
# hostnames, paths and database names. Values registered with secret_add (license
# key, database passwords) are replaced with **** before anything is written.

LOG_FD=""
declare -a SECRETS=()

secret_add() {
    local s
    for s in "$@"; do
        [[ ${#s} -ge 4 ]] || continue
        local known
        for known in "${SECRETS[@]}"; do [[ "$known" == "$s" ]] && continue 2; done
        SECRETS+=("$s")
    done
}

# mask <string> - prints the string with every registered secret replaced.
mask() {
    local msg="$1" s
    for s in "${SECRETS[@]}"; do msg="${msg//"$s"/****}"; done
    printf '%s' "$msg"
}

log() {
    [[ -n "$LOG_FD" ]] || return 0
    local msg="$*" s
    for s in "${SECRETS[@]}"; do msg="${msg//"$s"/****}"; done
    printf '[%(%Y-%m-%d %H:%M:%S)T] %s\n' -1 "$msg" >&"$LOG_FD"
}

# log_file <file> - appends a command's captured output to the log (indented,
# secrets masked, carriage-return progress bars collapsed to their last frame).
log_file() {
    [[ -n "$LOG_FD" && -s "$1" ]] || return 0
    SPARTAN_MASK="$(printf '%s\n' "${SECRETS[@]}")" awk '
        BEGIN { n = split(ENVIRON["SPARTAN_MASK"], s, "\n") }
        {
            line = $0
            sub(/\r+$/, "", line)
            sub(/.*\r/, "", line)
            for (i = 1; i <= n; i++) {
                if (s[i] == "") continue
                out = ""
                while ((p = index(line, s[i])) > 0) {
                    out = out substr(line, 1, p - 1) "****"
                    line = substr(line, p + length(s[i]))
                }
                line = out line
            }
            print "    " line
        }' "$1" >&"$LOG_FD"
}

log_rotate() {
    local i
    for ((i = 4; i >= 1; i--)); do
        [[ -f "${LOG}.${i}.gz" ]] && mv -f "${LOG}.${i}.gz" "${LOG}.$((i + 1)).gz"
    done
    gzip -c "$LOG" >"${LOG}.1.gz" 2>/dev/null && chmod 600 "${LOG}.1.gz" && : >"$LOG"
}

log_init() {
    local dir
    dir="$(dirname "$LOG")"
    mkdir -p "$dir" 2>/dev/null || return 1
    if [[ -f "$LOG" ]]; then
        local size
        size="$(stat -c %s "$LOG" 2>/dev/null || echo 0)"
        ((size > LOG_MAX_BYTES)) && log_rotate
    fi
    (umask 077 && : >>"$LOG") 2>/dev/null || return 1
    chmod 600 "$LOG" 2>/dev/null
    exec {LOG_FD}>>"$LOG" || return 1

    printf '\n%s\n' "=====================================================================" >&"$LOG_FD"
    log "${TITLE} ${SPARTAN_VERSION} - pid $$ - started"
    log "Arguments: ${SPARTAN_ARGS_TEXT:-<none>}"
    log "Bash ${BASH_VERSION}, TERM=${TERM:-unset}, UI=${UI_MODE:-?}"

    if ((DEBUG)); then
        BASH_XTRACEFD="$LOG_FD"
        PS4='+ ${BASH_SOURCE[0]##*/}:${LINENO}: '
        set -x
    fi
}

log_close() {
    [[ -n "$LOG_FD" ]] || return 0
    ((DEBUG)) && set +x
    log "Finished with exit code ${1:-0}"
    exec {LOG_FD}>&-
    LOG_FD=""
}
