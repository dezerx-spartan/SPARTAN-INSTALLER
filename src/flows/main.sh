# shellcheck shell=bash
# Program entry: set-up, then the interactive menu or the requested action.

spartan_main() {
    SPARTAN_MAIN_PID=$$
    SPARTAN_USER_LOCALE="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
    core_locale

    parse_args "$@" || exit 1
    if ((SHOW_HELP)); then
        show_help
        exit 0
    fi
    if ((SHOW_VERSION)); then
        printf '%s\n' "$SPARTAN_VERSION"
        exit 0
    fi

    ui_mode_init
    exec {UI_FD}>&1
    local w
    for w in "${ARG_WARNINGS[@]}"; do printf '%s\n' "$w" >&2; done

    if ((DEMO)); then
        demo_main
        exit 0
    fi

    need_root
    export HOME=/root
    umask 022
    lock_acquire || exit 1
    run_dir_init
    ticker_files_init
    log_init || {
        printf 'Cannot write the log file %s.\n' "$LOG" >&2
        exit 1
    }
    for w in "${ARG_WARNINGS[@]}"; do log "$w"; done

    # From here on stray output goes to the log; the interface writes to the
    # terminal (TTY_FD) or the original stdout (UI_FD).
    exec >>"$LOG" 2>&1
    trap 'spartan_on_exit $?' EXIT
    trap spartan_on_hup HUP
    trap spartan_on_term TERM

    os_detect
    ui_start
    if ((NONINTERACTIVE)); then
        main_noninteractive
    else
        main_interactive
    fi
}

main_finish() {
    local code="$1"
    ui_stop
    summary_print_plain
    spartan_exit "$code"
}

main_interactive() {
    if [[ "$UI_MODE" == tui ]]; then
        UI_STEP=""
        ui_busy "Checking this server${G_ELLIPSIS}" startup_checks
    else
        startup_checks
    fi

    local action="$ACTION" rc
    choices_save
    while :; do
        if [[ -z "$action" ]]; then
            screen_menu
            rc=$?
            ((rc == 255)) && spartan_exit 1 "hangup"
            ((rc == 0)) || spartan_exit 0
            action="$UI_RESULT"
        fi
        choices_restore
        PLAN_EXECUTED=0
        case "$action" in
            install) UI_FLOW="Installer" ;;
            update) UI_FLOW="Updater" ;;
            uninstall) UI_FLOW="Uninstaller" ;;
            *) UI_FLOW="Tools" ;;
        esac
        case "$action" in
            install) flow_install ;;
            update) flow_update ;;
            uninstall) flow_uninstall ;;
            tools) flow_tools ;;
            setup_perms) PICK_TITLE="Repair permissions"; tool_perms ;;
            ssl) tool_ssl ;;
            health) tool_health ;;
            restart) tool_restart ;;
            support_bundle) tool_bundle ;;
        esac
        rc=$?
        if ((PLAN_EXECUTED)); then
            main_finish "$rc"
        fi
        action=""
    done
}

main_noninteractive() {
    startup_checks
    local rc=0
    case "$ACTION" in
        install) flow_install_noninteractive || rc=1 ;;
        update) flow_update_noninteractive || rc=1 ;;
        setup_perms)
            tool_pick_noninteractive || main_finish 1
            tool_perms_run || rc=1
            ;;
        ssl)
            tool_pick_noninteractive || main_finish 1
            app_get_var || { lp "Error: ${PHASE_FAIL_MSG}"; main_finish 1; }
            [[ -n "$SSL_MODE" && "$SSL_MODE" != later ]] || SSL_MODE="install"
            tool_ssl_run || rc=1
            ;;
        health)
            tool_pick_noninteractive || main_finish 1
            health_collect
            local row
            for row in "${HEALTH_ROWS[@]}"; do lp "$(text_strip "$row")"; done
            ((HEALTH_FAILS)) && rc=1
            ;;
        restart) tool_restart || rc=1 ;;
        support_bundle)
            if ! app_looks_like_spartan "$APP_DIR" && [[ -n "$DETECTED_APP_DIR" ]]; then
                APP_DIR="$DETECTED_APP_DIR"
            fi
            tool_bundle_run || rc=1
            ;;
        uninstall)
            lp "Uninstalling is interactive only. Run the installer without --non-interactive."
            rc=1
            ;;
        *)
            lp "Choose an action: --install, --update, --setup-perms, --ssl, --health, --restart-services or --support-bundle."
            rc=1
            ;;
    esac
    [[ "$SUMMARY_OK" == 0 ]] && rc=1
    main_finish "$rc"
}
