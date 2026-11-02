package app_test

import "core:testing"
import app "../../src"

@(private)
jumps_all_reachable :: proc(data: rawptr, session: u32) -> bool {return true}

@(private)
jumps_skip_two :: proc(data: rawptr, session: u32) -> bool {return session != 2}

@(test)
focus_jumps_walk_back_and_forward :: proc(t: ^testing.T) {
	j: app.Focus_Jumps
	defer app.focus_jumps_destroy(&j)
	for session in ([]u32{1, 2, 2, 3}) {app.focus_jumps_note(&j, session)}
	testing.expect_value(t, len(j.entries), 3)
	session, ok := app.focus_jumps_step(&j, -1, jumps_all_reachable, nil)
	testing.expect(t, ok && session == 2)
	session, ok = app.focus_jumps_step(&j, -1, jumps_all_reachable, nil)
	testing.expect(t, ok && session == 1)
	_, ok = app.focus_jumps_step(&j, -1, jumps_all_reachable, nil)
	testing.expect(t, !ok)
	// Landing on the pane the jump chose records nothing, so forward still works.
	app.focus_jumps_note(&j, 1)
	session, ok = app.focus_jumps_step(&j, 1, jumps_all_reachable, nil)
	testing.expect(t, ok && session == 2)
}

@(test)
focus_jumps_new_focus_drops_forward_path :: proc(t: ^testing.T) {
	j: app.Focus_Jumps
	defer app.focus_jumps_destroy(&j)
	for session in ([]u32{1, 2, 3}) {app.focus_jumps_note(&j, session)}
	_, _ = app.focus_jumps_step(&j, -1, jumps_all_reachable, nil)
	app.focus_jumps_note(&j, 4)
	testing.expect_value(t, len(j.entries), 3)
	testing.expect_value(t, j.entries[2], 4)
	_, ok := app.focus_jumps_step(&j, 1, jumps_all_reachable, nil)
	testing.expect(t, !ok)
}

@(test)
focus_jumps_skip_closed_panes :: proc(t: ^testing.T) {
	j: app.Focus_Jumps
	defer app.focus_jumps_destroy(&j)
	for session in ([]u32{1, 2, 3}) {app.focus_jumps_note(&j, session)}
	session, ok := app.focus_jumps_step(&j, -1, jumps_skip_two, nil)
	testing.expect(t, ok && session == 1)
	testing.expect_value(t, len(j.entries), 2)
	session, ok = app.focus_jumps_step(&j, 1, jumps_skip_two, nil)
	testing.expect(t, ok && session == 3)
}
