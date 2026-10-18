# shellcheck shell=bash
# task: runs one unit of work with a spinner, sends its output to the log and
# remembers the output of the last failure for the error screen.
#
#   task "Installing PHP 8.4 packages" pkg_install php8.4-fpm php8.4-cli
#
# Commands and shell functions both work. Functions run in this shell, so
# the variables they set survive. A task started from inside another task just
# runs (and updates the description shown under the spinner).

TASK_DEPTH=0
TASK_SEQ=0
TASK_OUT=""
TASK_T0=0
TASK_DESC_CUR=""
TASK_FAIL_DESC=""
TASK_FAIL_RC=0
TASK_FAIL_OUT=""

task() {
    local desc="$1"
    shift

    if ((DEMO)) && [[ "$1" != demo_* ]]; then
        log "DEMO: refusing to run '$1' (${desc})"
        return 0
    fi

    if ((TASK_DEPTH > 0)); then
        log "  - ${desc}"
        local outer_desc="$TASK_DESC_CUR" outer_t0="$TASK_T0" rc
        task_state_write "$(now)" "$desc" "$TASK_OUT"
        printf '\n>>> %s\n' "$desc" >>"$TASK_OUT"
        "$@" </dev/null
        rc=$?
        task_state_write "$outer_t0" "$outer_desc" "$TASK_OUT"
        return "$rc"
    fi

    if abort_requested; then
        log "Not starting '${desc}': stop requested"
        return 130
    fi

    TASK_SEQ=$((TASK_SEQ + 1))
    TASK_OUT="${RUN_DIR}/task-${TASK_SEQ}.out"
    : >"$TASK_OUT"
    TASK_T0=$(now)
    TASK_DESC_CUR="$desc"
    log "> ${desc}"
    log "  \$ $*"
    task_state_write "$TASK_T0" "$desc" "$TASK_OUT"
    ui_task_begin "$desc"

    TASK_DEPTH=1
    "$@" >>"$TASK_OUT" 2>&1 </dev/null
    local rc=$?
    TASK_DEPTH=0

    ui_task_end "$desc" "$rc"
    log_file "$TASK_OUT"
    local took
    took="$(fmt_duration $(($(now) - TASK_T0)))"
    if ((rc == 0)); then
        log "  ok (${took})"
        rm -f "$TASK_OUT"
    else
        log "  FAILED with exit code ${rc} after ${took}"
        TASK_FAIL_DESC="$desc"
        TASK_FAIL_RC=$rc
        TASK_FAIL_OUT="$TASK_OUT"
    fi
    task_state_write "" "" ""
    return "$rc"
}

# task_try <description> <command...> - like task, but a failure only adds a
# warning instead of failing the phase.
task_try() {
    local desc="$1"
    task "$@" && return 0
    TASK_FAIL_DESC=""
    TASK_FAIL_OUT=""
    warn_add "${desc} did not succeed (see ${LOG})."
    return 0
}

# say <message> - a status line in the run log (and in line/plain output).
say() {
    log "$*"
    [[ "$UI_MODE" == plain ]] && lp "  $*"
    return 0
}

# task_fail_tail [lines] - last lines of the failed command's output (masked).
task_fail_tail() {
    local n="${1:-14}"
    [[ -n "$TASK_FAIL_OUT" && -s "$TASK_FAIL_OUT" ]] || return 0
    local out
    out="$(tail -c 8192 "$TASK_FAIL_OUT" | tr '\r' '\n' | sed -e 's/\x1b\[[0-9;?]*[ -\/]*[@-~]//g' | grep -v '^[[:space:]]*$' | tail -n "$n")"
    mask "$out"
}
