# shellcheck shell=bash

# Visible width of a rendered string: escape sequences removed, the block
# glyphs counted as one column each (independent of the test's locale).
_t_visible_width() {
    local v
    v="$(printf '%s' "$1" | sed $'s/\e\\[[0-9;]*m//g')"
    v="${v//▀/x}"
    v="${v//▄/x}"
    v="${v//█/x}"
    echo "${#v}"
}

test_logo_bitmaps_use_the_palette() {
    local size row ch i
    for size in 5 4; do
        local -n bmp="LOGO_${size}"
        assert_eq $((size * 2)) "${#bmp[@]}" "LOGO_${size} has two pixel rows per terminal row"
        for row in "${bmp[@]}"; do
            assert_eq "${#bmp[0]}" "${#row}" "LOGO_${size} rows have one width"
            for ((i = 0; i < ${#row}; i++)); do
                ch="${row:i:1}"
                [[ "$ch" == . || -n "${LOGO_PAL[$ch]:-}" ]] || assert_eq "palette entry" "$ch" "LOGO_${size} uses only palette shades"
            done
        done
        local -n art="LOGO_ASCII_${size}"
        assert_eq "$size" "${#art[@]}" "ASCII version of LOGO_${size} has the same height"
        unset -n bmp art
    done
}

test_logo_renders_at_every_depth() {
    local depth utf size row
    ui_theme_init
    for utf in 1 0; do
        UI_UTF8=$utf
        ui_glyphs_init
        for depth in 24 256 16 0; do
            UI_DEPTH=$depth
            for size in 5 4; do
                logo_render "$size"
                assert_eq "$size" "${#LOGO_ROWS[@]}" "rows (depth ${depth}, utf8 ${utf}, size ${size})"
                for row in "${LOGO_ROWS[@]}"; do
                    if ((utf)); then
                        assert_eq "$LOGO_W" "$(_t_visible_width "$row")" "width (depth ${depth}, size ${size})"
                    else
                        (($(_t_visible_width "$row") <= LOGO_W)) || assert_eq "<= ${LOGO_W}" "$(_t_visible_width "$row")" "ASCII width"
                    fi
                done
            done
        done
    done
    UI_UTF8=1 UI_DEPTH=0
    logo_render 5
    [[ "${LOGO_ROWS[*]}" != *$'\e[38'* && "${LOGO_ROWS[*]}" != *$'\e[48'* ]]
    assert_eq 0 $? "no colours without colour support"
}

test_track_follows_the_wizard_then_the_plan() {
    PLAN_EXECUTED=0 PLAN_RUNNING=0 UI_STEP=""
    ui_track
    assert_eq 1 $? "nothing to track on the menu"

    UI_STEP="3/9"
    ui_track
    assert_eq "33|Step 3 of 9|run" "${TRACK_PCT}|${TRACK_LABEL}|${TRACK_STATE}" "wizard step"

    plan_new "Test"
    plan_add a "A" 10 true
    plan_add b "B" 30 true
    plan_add c "C" 60 true
    PLAN_EXECUTED=1 PLAN_RUNNING=1
    PROG_STATE=(ok ok run)
    ui_track
    assert_eq "40|40%|run" "${TRACK_PCT}|${TRACK_LABEL}|${TRACK_STATE}" "plan by weight, over the wizard"

    PLAN_RUNNING=0 PROG_STATE=(ok ok ok) SUMMARY_OK=1
    ui_track
    assert_eq "100|ok" "${TRACK_PCT}|${TRACK_STATE}" "finished"

    PLAN_FAILED_INDEX=1 PROG_STATE=(ok fail pending)
    ui_track
    assert_eq "40|fail" "${TRACK_PCT}|${TRACK_STATE}" "failed at the second phase"

    PLAN_FAILED_INDEX=-1 SUMMARY_OK=0
    ui_track
    assert_eq "fail" "$TRACK_STATE" "plan done but the run failed (rolled back update)"
}

test_header_leaves_room_for_the_tallest_form() {
    TERM_COLS=80
    # The Database form is 17 rows high and cannot scroll.
    local rows
    for rows in 24 28 34 40; do
        TERM_ROWS=$rows
        ui_layout_dialog 11 "$UI_WIDTH"
        assert_eq 17 "$DLG_H" "17-row form fits at ${rows} rows"
        ((DLG_R - 1 > HEADER_H))
        assert_eq 0 $? "room for the tab above the dialog at ${rows} rows"
    done
    TERM_ROWS=24
    ui_header_height
    assert_eq 4 "$HEADER_LOGO" "4-row logo at 24 rows"
    TERM_ROWS=40
    ui_header_height
    assert_eq 5 "$HEADER_LOGO" "5-row logo at 40 rows"
    TERM_ROWS=22
    ui_header_height
    assert_eq 0 "$HEADER_LOGO" "single line below 24 rows"
}
