# How the installer is put together

The installer is plain bash (4.4+) without external dependencies for its interface. The source is split into small modules; `src/modules.list` defines the load order. In a git checkout `src/main.sh` sources them; for releases `tools/build.sh` concatenates them into one file.

```
spartan_installer.sh      bootstrap: runs src/ in a checkout, otherwise downloads and verifies the bundle
src/
  main.sh                 loads the modules in a checkout and calls spartan_main
  modules.list            load order (also used by the build)
  core/                   settings, helpers, log, command line, task runner, plans
  ui/                     theme, logo, terminal, text layout, drawing, widgets, forms, line mode, progress
  system/                 OS detection, packages, services, preflight, swap, time, network, firewall, SELinux
  stack/                  PHP, ionCube, Composer, Node.js, Nginx, database, Redis, SSL
  app/                    detection, .env, license, release download, options file, preserving
                          customisations, build, Octane, queue workers, cron, permissions
  backup/                 backups and rollback
  flows/                  main menu and the install, update, uninstall, tools and demo flows
tests/                    unit tests for the pure functions
tools/                    build, release, lint
```

## Interface modes

`ui_mode_init` picks one of three modes:

- `tui`: full screen, when stdin can read the terminal, the terminal is at least 70x20 and `--plain`/`--non-interactive` are not set.
- `line`: line-by-line prompts and spinners on a terminal.
- `plain`: no colours or cursor movement, for pipes and Spartan's automatic updater.

Widgets (`ui_msgbox`, `ui_nav`, `ui_confirm`, `ui_menu`, `ui_radio`, `ui_checklist`, `ui_form`) work in all three modes; callers never check the mode. They return 0 for next/confirm, 1 for back and 255 when the terminal went away.

In full-screen mode the terminal runs with signals off, so Ctrl+C arrives as a key. Keys are read with plain timed `read -t` calls: bash's `read -n`/`-s`/`-d` temporarily switch signals back on, which made Ctrl+C kill the program.

After the full-screen interface starts, everything the installer runs writes to the log; the interface writes to the terminal (`TTY_FD`) or the original stdout (`UI_FD`). Stray output therefore never breaks the screen.

## Running work: tasks and plans

A plan is an ordered list of phases (`plan_new`, `plan_add`, `plan_run`); each phase is one row in the progress view. Inside a phase, every command runs through `task`:

```bash
ph_example() {
    task "Installing Nginx" install_nginx || return 1        # fails the phase
    task_try "Opening ports 80 and 443" firewall_open_web     # only a warning
    warn_add "Something the user should know."               # "!" on the phase, listed at the end
    return 0                                                  # 3 = skipped
}
```

`task` runs commands and shell functions in the current shell (so functions can set variables), sends their output to the log, and keeps the output of a failure for the error screen. A background "ticker" process animates the spinner and reads the keyboard meanwhile. Nested `task` calls only update the description under the spinner.

Use `phase_fail "message"` before returning 1 when the reason is not obvious from the failed command.

## Adding a wizard screen

A screen is a function returning 0 (next) or 1 (back). An optional `<name>_applies` function hides it when it returns 1; the step count on the header's progress bar adjusts. Add it to the `wizard_run` call of the flow:

```bash
scr_example() {
    form_reset
    form_add "Label" "$CURRENT_VALUE" text "Help shown under the form"
    FORM_VALIDATE=_validate_example     # sets FORM_ERROR / FORM_ERROR_FIELD on failure
    ui_form "Title" "Explanation." || return $?
    CURRENT_VALUE="${FORM_VALUES[0]}"
}
```

Text passed to dialogs may use the tags `{b}`, `{d}`, `{a}`, `{ok}`, `{w}`, `{e}` and `{/}`; wrap anything that comes from outside the installer in `tx` so it cannot inject tags.

## Rules the code follows

- Nothing changes on the server before the review screen is confirmed. Preflight checks are read-only.
- Never `rm -rf` a variable path directly: use `safe_rm_rf`, which refuses system folders.
- Passwords never go on a command line or into the log: use `db_app_cnf`/`db_root_cnf`, send SQL on stdin, and register secrets with `secret_add`.
- Keep 1.x names: unit names, paths, `.env` keys and flags are relied on by Spartan and existing servers.
- Every system change in an update must either be in the backup (`create_*_backup`) or be harmless to leave in place after a rollback.
- Keep the bootstrap small: it is passed to bash as a single argument (128 KiB limit).
