package app_test

import "core:testing"
import "core:time"
import app "../../src"
import "aio:layout"
import "aio:settings"
import "aio:term"
import "aio:ui"

@(test)
program_status_spinner_requests_every_display_frame :: proc(t: ^testing.T) {
	w := app.Window{status_spinning = true, width = 800, height = 600}
	app.status_spin_tick(&w)
	w.dirty = false
	app.status_spin_tick(&w)
	testing.expect(t, w.dirty, "visible spinner must advance at 240 Hz, not wait for an 80 ms timer")
}

@(test)
program_status_spinner_stops_when_not_drawn_or_window_has_no_extent :: proc(t: ^testing.T) {
	windows := [3]app.Window{
		{width = 800, height = 600},
		{status_spinning = true},
		{status_spinning = true, width = 800, height = 600, phase = .Preparing},
	}
	for w in windows {
		window := w
		app.status_spin_tick(&window)
		testing.expect(t, !window.dirty && !app.status_spin_active(&window))
	}
}

@(test)
program_status_static_marks_do_not_request_animation :: proc(t: ^testing.T) {
	a := app.App{animations = true}
	w: app.Window
	marks := [3]ui.Status_Mark{
		{glyph = .Working, progress = 30},
		{glyph = .Done, progress = -1},
		{glyph = .Blocked, progress = -1},
	}
	for mark in marks {
		testing.expect_value(t, app.status_phase(&a, &w, mark), f32(0))
		testing.expect(t, !w.status_spinning)
	}
	a.animations = false
	testing.expect_value(t, app.status_phase(&a, &w, {glyph = .Working, progress = -1}), f32(0))
	testing.expect(t, !w.status_spinning)
	a.animations = true
	_ = app.status_phase(&a, &w, {glyph = .Working, progress = -1})
	testing.expect(t, w.status_spinning)
}

@(private="file")
Status_Fixture :: struct {
	state:     app.App,
	workspace: ^app.Workspace,
	first:     [3]term.Program_Status,
	second:    [2]term.Program_Status,
}

@(private="file")
status_tab :: proc(t: ^testing.T, workspace: ^app.Workspace, session: u32) -> bool {
	tab, tab_error := new(app.Tab)
	if !testing.expect_value(t, tab_error, nil) {return false}
	if !testing.expect_value(t, layout.init(&tab.tree, {.Terminal, session}), nil) {
		free(tab)
		return false
	}
	if _, append_error := append(&workspace.tabs, tab); append_error == nil {return true}
	app.tab_record_free(tab)
	return false
}

@(private="file")
status_fixture_init :: proc(t: ^testing.T, f: ^Status_Fixture) -> bool {
	defaults, err := settings.defaults()
	if !testing.expect_value(t, err, nil) {return false}
	f.state.settings = defaults
	f.state.settings.status.show -= {.Idle}
	f.workspace = app.workspace_create_empty(&f.state)
	if !testing.expect(t, f.workspace != nil) {return false}
	if !status_tab(t, f.workspace, 1) || !status_tab(t, f.workspace, 2) {return false}
	now := time.now()
	f.first = {
		{id = "", app = "cargo", state = .Working, progress = 40, updated_at = now},
		{id = "test", app = "cargo", state = .Done, progress = -1, updated_at = now},
		{id = "lint", app = "vite", state = .Idle, progress = -1, updated_at = now},
	}
	f.second = {
		{id = "", app = "codex", state = .Blocked, kind = .Permission, progress = -1, updated_at = now},
		{id = "old", app = "codex", state = .Error, read = true, progress = -1, updated_at = now},
	}
	entries := [2]app.Session_Entry{{id = 1, statuses = f.first[:]}, {id = 2, statuses = f.second[:]}}
	for entry in entries {
		if _, append_error := append(&f.state.sessions, entry); append_error != nil {return false}
	}
	return true
}

@(private="file")
status_fixture_destroy :: proc(f: ^Status_Fixture) {
	clear(&f.state.workspaces)
	if f.workspace != nil {app.workspace_destroy(f.workspace)}
	delete(f.state.workspaces)
	delete(f.state.sessions)
	settings.destroy(&f.state.settings)
}

@(test)
program_status_close_scope_protects_work_independent_of_presentation :: proc(t: ^testing.T) {
	f: Status_Fixture
	defer status_fixture_destroy(&f)
	if !status_fixture_init(t, &f) {return}
	f.state.settings.interface.confirm -= {.Close_Split_Tab}
	f.state.settings.status.show -= {.Working, .Blocked}
	testing.expect(t, app.tab_close_has_work(&f.state, f.workspace, 0))
	testing.expect(t, app.tab_close_has_work(&f.state, f.workspace, 1))
	f.first[0].state = .Idle
	testing.expect(t, !app.tab_close_has_work(&f.state, f.workspace, 0))
	f.workspace.tabs[0].marked = true
	f.workspace.tabs[1].marked = true
	testing.expect(t, app.tab_close_has_work(&f.state, f.workspace, 0))
	f.second[0].state = .Done
	testing.expect(t, !app.tab_close_has_work(&f.state, f.workspace, 0))
	f.first[2].state = .Working
	testing.expect(t, app.tab_close_has_work(&f.state, f.workspace, 0))
	testing.expect(t, !app.tab_close_has_work(&f.state, f.workspace, -1))
}

@(test)
program_status_ranks_attention_first :: proc(t: ^testing.T) {
	rank :: proc(state: term.Program_Status_State, read := false) -> app.Status_Rank {
		return app.status_presentation({state = state, read = read}).rank
	}
	testing.expect(t, rank(.Blocked) < rank(.Error))
	testing.expect(t, rank(.Error) < rank(.Done))
	testing.expect(t, rank(.Done) < rank(.Working))
	testing.expect(t, rank(.Working) < rank(.Idle))
	testing.expect(t, rank(.Idle) < rank(.Error, read = true))
	// Reading live work changes nothing about its urgency; blocked work still needs the user.
	testing.expect_value(t, rank(.Blocked, read = true), rank(.Blocked))
	testing.expect(t, app.status_presentation({state = .Blocked, read = true}).attention)
	done, read_failed := app.status_presentation({state = .Done}), app.status_presentation({state = .Error, read = true})
	testing.expect(t, done.attention && !read_failed.attention && read_failed.seen)
	// The Activity panel's Needs you leaves finished work to Finished, unlike next-attention.
	testing.expect_value(t, done.section, app.Status_Section.Finished)
	testing.expect_value(t, app.status_presentation({state = .Error}).section, app.Status_Section.Needs_You)
	testing.expect_value(t, read_failed.section, app.Status_Section.Finished)
}

@(test)
program_status_marks_follow_state_and_kind :: proc(t: ^testing.T) {
	for state in term.Program_Status_State {
		for read in ([2]bool{false, true}) {
			p := app.status_presentation({state = state, read = read})
			testing.expect_value(t, p.seen, read && term.program_status_finished(state))
			testing.expect_value(t, p.mark.dim, p.seen)
		}
	}
	question := app.status_presentation({state = .Blocked, kind = .Question, progress = 10}).mark
	testing.expect_value(t, question.glyph, ui.Status_Glyph.Question)
	testing.expect_value(t, question.progress, i8(10))
	auth := app.status_presentation({state = .Blocked, kind = .Auth, progress = -1}).mark
	testing.expect_value(t, auth.glyph, ui.Status_Glyph.Auth)
	seen := app.status_presentation({state = .Done, read = true, progress = -1}).mark
	testing.expect(t, seen.glyph == .Done && seen.dim)
	buffer: [8]u8
	testing.expect_value(t, app.status_headline({glyph = .Working, progress = 7}, buffer[:]), "7%")
	testing.expect_value(t, app.status_headline({glyph = .Working, progress = 100}, buffer[:]), "100%")
	testing.expect_value(t, app.status_headline({glyph = .Working, progress = -1}, buffer[:]), "Working")
	testing.expect_value(t, app.status_headline({glyph = .Permission}, buffer[:]), "Needs permission")
}

@(test)
program_status_ignored_apps_match_whole_names :: proc(t: ^testing.T) {
	testing.expect(t, app.status_app_ignored("vite, Cargo", "cargo"))
	testing.expect(t, app.status_app_ignored("vite, Cargo", "vite"))
	testing.expect(t, !app.status_app_ignored("vite, Cargo", "vitest"))
	testing.expect(t, !app.status_app_ignored("", "cargo"))
	testing.expect(t, !app.status_app_ignored("cargo", ""))
}

@(test)
program_status_summaries_respect_settings :: proc(t: ^testing.T) {
	f: Status_Fixture
	defer status_fixture_destroy(&f)
	if !status_fixture_init(t, &f) {return}
	tab := app.status_tab_summary(&f.state, f.workspace, 0)
	testing.expect_value(t, tab.counts[.Working], 1)
	testing.expect_value(t, tab.counts[.Done], 1)
	testing.expect_value(t, tab.counts[.Idle], 0)
	testing.expect_value(t, tab.top.id, "test")
	whole := app.status_workspace_summary(&f.state, f.workspace)
	testing.expect_value(t, whole.counts[.Blocked], 1)
	testing.expect_value(t, whole.counts[.Failed], 0)
	testing.expect_value(t, whole.needs, 2)
	testing.expect_value(t, whole.session, u32(2))
	mark, shown := app.status_indicator(whole)
	testing.expect(t, shown && mark.glyph == .Permission)
	testing.expect_value(t, app.status_picker_text(&f.state, f.workspace), "1 needs you · 1 done · 1 working")

	f.state.settings.status.show += {.Idle}
	original := f.state.settings.status.ignore_apps
	f.state.settings.status.ignore_apps = "cargo"
	tab = app.status_tab_summary(&f.state, f.workspace, 0)
	testing.expect_value(t, tab.counts[.Working], 0)
	testing.expect_value(t, tab.counts[.Idle], 1)
	testing.expect_value(t, tab.top.app, "vite")
	f.state.settings.status.ignore_apps = original

	f.state.settings.status.show -= {.Blocked}
	whole = app.status_workspace_summary(&f.state, f.workspace)
	testing.expect_value(t, whole.counts[.Blocked], 0)
	testing.expect_value(t, whole.top.id, "test")

	f.state.settings.status.surfaces -= {.Workspace_Picker}
	testing.expect_value(t, app.status_picker_text(&f.state, f.workspace), "")

	f.state.settings.status.enabled = false
	whole = app.status_workspace_summary(&f.state, f.workspace)
	testing.expect(t, !whole.found)
	_, shown = app.status_indicator(whole)
	testing.expect(t, !shown)
}

@(test)
program_status_scope_records_share_filtering_and_borrow_no_sortable_snapshot :: proc(t: ^testing.T) {
	f: Status_Fixture
	defer status_fixture_destroy(&f)
	if !status_fixture_init(t, &f) {return}
	w := app.Window{workspace = f.workspace}
	walk := app.status_scope_records(&f.state, &w)
	first, ok := app.status_scope_records_next(&walk)
	if !testing.expect(t, ok) {return}
	testing.expect_value(t, first.session, u32(1))
	testing.expect_value(t, len(first.records), 2)
	testing.expect_value(t, first.records[0].id, "")
	testing.expect_value(t, first.records[1].id, "test")
	testing.expect_value(t, first.pane.workspace, f.workspace.name)
	testing.expect_value(t, first.pane.crumb,
		app.session_location_at(f.workspace, 0, &f.state.sessions[0]))
	// Each overview can reorder its copy without changing the next overview's input.
	first.records[0], first.records[1] = first.records[1], first.records[0]
	testing.expect_value(t, f.first[0].id, "")
	second, more := app.status_scope_records_next(&walk)
	if !testing.expect(t, more) {return}
	testing.expect_value(t, second.session, u32(2))
	testing.expect_value(t, len(second.records), 2)
	_, more = app.status_scope_records_next(&walk)
	testing.expect(t, !more)

	ignored := f.state.settings.status.ignore_apps
	f.state.settings.status.ignore_apps = "cargo"
	walk = app.status_scope_records(&f.state, &w)
	second, more = app.status_scope_records_next(&walk)
	testing.expect(t, more)
	testing.expect_value(t, second.session, u32(2))
	f.state.settings.status.ignore_apps = ignored

	f.state.settings.status.enabled = false
	walk = app.status_scope_records(&f.state, &w)
	_, more = app.status_scope_records_next(&walk)
	testing.expect(t, !more)
}
