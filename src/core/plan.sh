# shellcheck shell=bash
# Plans: an ordered list of phases (shown as rows in the progress view).
# A phase function returns 0 when done, 3 when it had nothing to do, and
# anything else to stop the plan. warn_add during a phase marks it with "!".
#
#   plan_new "Installing DezerX Spartan"
#   plan_add php "Installing PHP 8.4" 14 phase_php
#   plan_run || handle_failure

declare -a PLAN_FUNCS=()
PLAN_FAILED_INDEX=-1
PLAN_FAILED_LABEL=""
PLAN_RUNNING=0
PLAN_ABORTED=0
PLAN_EXECUTED=0
PHASE_WARNED=0

plan_new() {
    progress_reset "$1"
    PLAN_FUNCS=()
    PLAN_FAILED_INDEX=-1
    PLAN_FAILED_LABEL=""
    PLAN_ABORTED=0
}

# plan_add <id> <label> <weight> <function>
plan_add() {
    progress_add "$1" "$2" "$3"
    PLAN_FUNCS+=("$4")
}

_plan_sigint() {
    if [[ -e "$ABORT_FILE" ]]; then
        echo force >"$ABORT_FILE"
    else
        echo stop >"$ABORT_FILE"
        ui_task_note "Stopping after the current step (press Ctrl+C again to stop now)"
    fi
}

plan_run() {
    local i rc state
    PLAN_RUNNING=1
    PLAN_EXECUTED=1
    rm -f "$ABORT_FILE"
    [[ "$UI_MODE" != tui ]] && trap _plan_sigint INT
    ui_plan_begin

    for i in "${!PLAN_FUNCS[@]}"; do
        if abort_requested; then
            PLAN_ABORTED=1
            PLAN_FAILED_INDEX=$i
            PLAN_FAILED_LABEL="${PROG_LABELS[i]}"
            log "Plan stopped by the user before: ${PROG_LABELS[i]}"
            break
        fi
        PHASE_WARNED=0
        PHASE_FAIL_MSG=""
        TASK_FAIL_DESC=""
        TASK_FAIL_OUT=""
        log "=== ${PROG_LABELS[i]}"
        ui_phase_begin "$i"
        "${PLAN_FUNCS[i]}"
        rc=$?
        if ((rc == 0)); then
            state="ok"
            ((PHASE_WARNED)) && state="warn"
        elif ((rc == 3)); then
            state="skip"
        else
            state="fail"
        fi
        ui_phase_end "$i" "$state"
        if [[ "$state" == fail ]]; then
            PLAN_FAILED_INDEX=$i
            PLAN_FAILED_LABEL="${PROG_LABELS[i]}"
            abort_requested && PLAN_ABORTED=1
            log "Phase failed: ${PROG_LABELS[i]} (code ${rc})"
            break
        fi
    done

    PLAN_RUNNING=0
    [[ "$UI_MODE" != tui ]] && trap - INT
    ((PLAN_FAILED_INDEX < 0))
}

PHASE_FAIL_MSG=""

# phase_fail <message> - explains why a phase stops; returns 1 for chaining:
#   [[ -f composer.json ]] || { phase_fail "The download is not a Spartan release."; return 1; }
phase_fail() {
    PHASE_FAIL_MSG="$1"
    log "ERROR: $1"
    return 1
}

# plan_fail_reason - one paragraph describing what went wrong.
plan_fail_reason() {
    if ((PLAN_ABORTED)); then
        printf 'Stopped on request during: %s' "${PLAN_FAILED_LABEL:-the run}"
    elif [[ -n "$PHASE_FAIL_MSG" ]]; then
        printf '%s' "$PHASE_FAIL_MSG"
    elif [[ -n "$TASK_FAIL_DESC" ]]; then
        printf '%s failed (exit code %s).' "$TASK_FAIL_DESC" "$TASK_FAIL_RC"
    else
        printf '%s failed.' "${PLAN_FAILED_LABEL:-A step}"
    fi
}
