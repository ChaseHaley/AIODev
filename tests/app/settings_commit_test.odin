package app_test

import app "../../src"
import "aio:layout"
import "aio:settings"
import "aio:ui"
import "core:os"
import "core:strings"
import "core:testing"

@(private)
commit_text :: proc(t: ^testing.T, source, key, value: string) -> string {
	updated, message, err := settings.edit_text(source, key, value, context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, message, "")
	return updated
}

@(private)
theme_commit_text :: proc(t: ^testing.T, source, token, value: string) -> string {
	updated, created, issue, err := settings.theme_color_edit(source, token, value, context.temp_allocator)
	testing.expect_value(t, err, settings.Theme_Edit_Error.None)
	testing.expect_value(t, issue, "")
	_ = created
	return updated
}

// Opening Settings focuses an existing tab, so a second settings tab only comes from a layout saved with two.
@(private)
settings_tab_restore :: proc(t: ^testing.T, state: ^app.App, w: ^app.Window) -> bool {
	tab, record_error := app.tab_record_reserve(w.workspace)
	if !testing.expect_value(t, record_error, app.Tab_Record_Error.None) {return false}
	if !testing.expect_value(t, layout.init(&tab.tree, {.Settings, 0}), nil) {return false}
	app.tab_record_commit(state, w.workspace, tab)
	app.workspace_settings_sync(state, w.workspace)
	app.tab_select(state, w, len(w.workspace.tabs) - 1)
	return testing.expect(t, ui.editor_loaded(&w.editor))
}

@(private)
expect_revision :: proc(t: ^testing.T, p: ^ui.Editor, current: bool, reason := ui.Editor_Stale_Reason.Changed_Outside) -> bool {
	stale, is_stale := p.revision.(ui.Editor_Stale)
	if current {return testing.expect(t, ui.editor_loaded(p) && !is_stale)}
	return testing.expect(t, is_stale) && testing.expect_value(t, stale.reason, reason)
}

@(private)
commit_open_pages :: proc(t: ^testing.T, f: ^Palette_Fixture, name: string) -> bool {
	if !palette_fixture_create(t, f, name) {return false}
	for window in f.state.windows {
		if !settings_tab_restore(t, &f.state, window) {return false}
	}
	return true
}

// An inline save, a disk-based writer and a second inline save all cross the same interface.
// Every window follows the revision while the other page keeps its unsaved field and selection.
@(test)
settings_commit_publishes_across_writers_and_preserves_the_other_windows_draft :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !commit_open_pages(t, &f, "commit-writers") {return}
	s := &f.state
	first, second := &s.windows[0].editor, &s.windows[1].editor
	app.settings_reveal_page(s, first, {key = "pane.gap", focus = .Control})
	app.settings_reveal_page(s, second, {key = "font.size", query = "font", search = .Scope, focus = .Control})
	ui.field_set(&second.value, "19")
	second.value.cursor, second.value.anchor = 1, 0
	ui.editor_message(second, "Pending field", true)
	updated := commit_text(t, ui.editor_source(first), "pane.gap", "9")
	if !testing.expect_value(t, app.settings_commit(s, ui.editor_source(first), updated, first), settings.Save_Error.None) {return}
	testing.expect_value(t, s.settings.pane.gap, 9)
	testing.expect_value(t, ui.editor_source(first), updated)
	testing.expect_value(t, ui.editor_row(first).key, "pane.gap")
	testing.expect_value(t, ui.editor_row(first).value, "9")
	testing.expect_value(t, ui.field_string(&first.value), "9")
	testing.expect_value(t, ui.editor_source(second), updated)
	testing.expect_value(t, ui.field_string(&second.filter), "font")
	testing.expect_value(t, ui.editor_row(second).key, "font.size")
	testing.expect_value(t, ui.field_string(&second.value), "19")
	testing.expect_value(t, second.value.cursor, 1)
	testing.expect_value(t, second.value.anchor, 0)
	testing.expect_value(t, ui.editor_focus(second), ui.Editor_Focus.Control)
	testing.expect_value(t, second.message, "Pending field")
	testing.expect(t, second.error)
	updated = commit_text(t, ui.editor_source(first), "tabs.orientation", "vertical")
	if !testing.expect_value(t, app.settings_commit(s, ui.editor_source(first), updated), settings.Save_Error.None) {return}
	for window in s.windows {
		testing.expect(t, !window.tabs_horizontal)
		testing.expect_value(t, ui.editor_source(&window.editor), updated)
	}
	testing.expect_value(t, ui.field_string(&second.value), "19")
	updated = commit_text(t, ui.editor_source(second), "font.size", ui.field_string(&second.value))
	if !testing.expect_value(t, app.settings_commit(s, ui.editor_source(second), updated, second), settings.Save_Error.None) {return}
	testing.expect_value(t, s.settings.font.size, 19.0)
	testing.expect_value(t, ui.editor_row(second).value, "19")
	testing.expect_value(t, ui.editor_source(first), updated)
	data, err := os.read_entire_file(f.path, context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, string(data), updated)
}

@(test)
settings_commit_conflict_leaves_running_state_pages_and_drafts_unchanged :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !commit_open_pages(t, &f, "commit-conflict") {return}
	s := &f.state
	p := &s.windows[0].editor
	app.settings_reveal_page(s, p, {key = "font.size", focus = .Control})
	ui.field_set(&p.value, "19")
	previous := strings.clone(ui.editor_source(p), context.temp_allocator)
	font_size := s.settings.font.size
	external := commit_text(t, previous, "pane.gap", "9")
	if !testing.expect_value(t, os.write_entire_file(f.path, external), nil) {return}
	updated := commit_text(t, previous, "font.size", "19")
	testing.expect_value(t, app.settings_commit(s, ui.editor_source(p), updated, p), settings.Save_Error.Conflict)
	testing.expect_value(t, s.settings.font.size, font_size)
	for window in s.windows {
		testing.expect_value(t, ui.editor_source(&window.editor), previous)
		// The file no longer holds what both pages show, so both fell behind.
		expect_revision(t, &window.editor, false)
	}
	testing.expect_value(t, ui.field_string(&p.value), "19")
	data, err := os.read_entire_file(f.path, context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, string(data), external)
}

// Reading the latest file for an internal write must not legitimize a page that predates a real
// external edit: only pages based on the commit's expected revision can advance.
@(test)
settings_commit_disk_writer_keeps_an_external_conflict_on_stale_pages :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !commit_open_pages(t, &f, "commit-stale") {return}
	s := &f.state
	p := &s.windows[0].editor
	previous := strings.clone(ui.editor_source(p), context.temp_allocator)
	external := commit_text(t, previous, "pane.gap", "9")
	if !testing.expect_value(t, os.write_entire_file(f.path, external), nil) {return}
	updated := commit_text(t, external, "tabs.orientation", "vertical")
	if !testing.expect_value(t, app.settings_commit(s, external, updated), settings.Save_Error.None) {return}
	testing.expect_value(t, s.settings.pane.gap, 9)
	testing.expect_value(t, s.settings.tabs.orientation, settings.Tabs_Orientation.Vertical)
	for window in s.windows {
		testing.expect_value(t, ui.editor_source(&window.editor), previous)
		expect_revision(t, &window.editor, false)
	}
	candidate := commit_text(t, ui.editor_source(p), "font.size", "19")
	testing.expect_value(t, app.settings_commit(s, ui.editor_source(p), candidate, p), settings.Save_Error.Conflict)
}

@(test)
settings_commit_io_failure_does_not_publish :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !commit_open_pages(t, &f, "commit-io") {return}
	s := &f.state
	p := &s.windows[0].editor
	previous := strings.clone(ui.editor_source(p), context.temp_allocator)
	gap := s.settings.pane.gap
	updated := commit_text(t, previous, "pane.gap", "9")
	previous_path := s.settings_path
	s.settings_path = strings.concatenate({f.directory, "/missing/settings.ini"}, context.temp_allocator)
	defer s.settings_path = previous_path
	context.logger = {}
	testing.expect_value(t, app.settings_commit(s, ui.editor_source(p), updated, p), settings.Save_Error.IO)
	testing.expect_value(t, s.settings.pane.gap, gap)
	for window in s.windows {
		testing.expect_value(t, ui.editor_source(&window.editor), previous)
		expect_revision(t, &window.editor, true)
	}
}

@(test)
settings_commit_keeps_a_removed_profiles_draft_as_a_conflict :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !commit_open_pages(t, &f, "commit-removed") {return}
	s := &f.state
	first, second := &s.windows[0].editor, &s.windows[1].editor
	updated := commit_text(t, ui.editor_source(first), "profile.custom.command", "cmd.exe")
	updated = commit_text(t, updated, "profile.custom.name", "Custom")
	if !testing.expect_value(t, app.settings_commit(s, ui.editor_source(first), updated, first), settings.Save_Error.None) {return}
	app.settings_reveal_page(s, second, {key = "profile.custom.name", focus = .Control})
	ui.field_set(&second.value, "My pending name")
	previous := strings.clone(ui.editor_source(second), context.temp_allocator)
	removed, remove_error := settings.remove_profile_text(ui.editor_source(first), "custom", context.temp_allocator)
	if !testing.expect_value(t, remove_error, nil) {return}
	if !testing.expect_value(t, app.settings_commit(s, ui.editor_source(first), removed, first), settings.Save_Error.None) {return}
	testing.expect(t, settings.profile_find(&s.settings.profiles, "custom") == nil)
	testing.expect_value(t, ui.editor_source(second), previous)
	expect_revision(t, second, false, .Draft_Conflict)
	expect_revision(t, first, true)
	testing.expect_value(t, ui.editor_row(second).key, "profile.custom.name")
	testing.expect_value(t, ui.field_string(&second.value), "My pending name")
	candidate := commit_text(t, ui.editor_source(second), "profile.custom.name", ui.field_string(&second.value))
	testing.expect_value(t, app.settings_commit(s, ui.editor_source(second), candidate, second), settings.Save_Error.Conflict)
}

// Reloading is how a page behind the file catches up: every page adopts the file, and a draft whose
// row survives rides along.
@(test)
settings_reload_publishes_the_file_to_stale_pages_and_keeps_drafts :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !commit_open_pages(t, &f, "reload-stale") {return}
	s := &f.state
	first, second := &s.windows[0].editor, &s.windows[1].editor
	app.settings_reveal_page(s, second, {key = "font.size", focus = .Control})
	ui.field_set(&second.value, "19")
	external := commit_text(t, ui.editor_source(first), "pane.gap", "9")
	if !testing.expect_value(t, os.write_entire_file(f.path, external), nil) {return}
	updated := commit_text(t, external, "tabs.orientation", "vertical")
	if !testing.expect_value(t, app.settings_commit(s, external, updated), settings.Save_Error.None) {return}
	for window in s.windows {expect_revision(t, &window.editor, false)}
	app.reload_settings(s, false)
	for window in s.windows {
		testing.expect_value(t, ui.editor_source(&window.editor), updated)
		expect_revision(t, &window.editor, true)
	}
	testing.expect_value(t, ui.editor_row(second).key, "font.size")
	testing.expect_value(t, ui.field_string(&second.value), "19")
	_, draft := second.revision.(ui.Editor_Draft)
	testing.expect(t, draft, "the carried draft remains explicit after reloading")
	candidate := commit_text(t, ui.editor_source(second), "font.size", ui.field_string(&second.value))
	testing.expect_value(t, app.settings_commit(s, ui.editor_source(second), candidate, second), settings.Save_Error.None)
	testing.expect_value(t, s.settings.font.size, 19.0)
}

@(test)
settings_commit_keeps_the_origins_color_picker_and_hsv_after_drag_release :: proc(t: ^testing.T) {
	f: Profile_Fixture
	defer profile_fixture_destroy(t, &f)
	if !profile_fixture_create(t, &f, "commit-picker", PROFILE_FIXTURE_SETTINGS) {return}
	p := profile_open(&f)
	w := f.state.windows[0]
	app.settings_reveal_page(&f.state, p, {key = "colors.cursor", focus = .Control})
	cases := [?]struct {value: string, hsv: [3]f32, drag: ui.Color_Drag} {
		{"#000000", {120, 0.75, 0}, .Ramp},
		{"#408020", {100, 0.75, 0.5}, .Wheel},
	}
	for entry in cases {
		ui.field_set(&p.value, entry.value)
		p.mode, p.hsv = ui.Editor_Color_Popup{entry.drag}, entry.hsv
		outcome := ui.editor_release(p)
		if !testing.expect_value(t, outcome, ui.Editor_Outcome.Save) {return}
		app.editor_outcome(&f.state, w, outcome)
		testing.expect(t, !p.error)
		testing.expect_value(t, ui.editor_row(p).key, "colors.cursor")
		testing.expect_value(t, ui.field_string(&p.value), entry.value)
		testing.expect_value(t, ui.editor_popup(p), ui.Editor_Popup.Color)
		testing.expect_value(t, p.hsv, entry.hsv)
		testing.expect(t, !ui.editor_dragging(p))
	}
}

@(test)
settings_commit_rebuilds_a_clean_peers_picker_hsv_when_its_effective_color_changes :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !commit_open_pages(t, &f, "commit-peer-picker") {return}
	s := &f.state
	first, second := &s.windows[0].editor, &s.windows[1].editor
	updated := theme_commit_text(t, ui.editor_source(first), "cursor", "#000000")
	if !testing.expect_value(t, app.settings_commit(s, ui.editor_source(first), updated, first), settings.Save_Error.None) {return}
	app.settings_reveal_page(s, second, {key = "colors.cursor", focus = .Control})
	second.mode, second.hsv = ui.Editor_Color_Popup{}, {120, 0.75, 0}
	updated = theme_commit_text(t, ui.editor_source(first), "cursor", "#408020")
	if !testing.expect_value(t, app.settings_commit(s, ui.editor_source(first), updated, first), settings.Save_Error.None) {return}
	testing.expect_value(t, ui.editor_popup(second), ui.Editor_Popup.Color)
	testing.expect_value(t, ui.field_string(&second.value), "#408020")
	h, saturation, value := settings.rgb_to_hsv({64, 128, 32})
	testing.expect_value(t, second.hsv, [3]f32{h, saturation, value})
	updated = theme_commit_text(t, ui.editor_source(first), "cursor", "#000000")
	if !testing.expect_value(t, app.settings_commit(s, ui.editor_source(first), updated, first), settings.Save_Error.None) {return}
	second.hsv = {120, 0.75, 0}
	updated = commit_text(t, ui.editor_source(first), "pane.gap", "9")
	if !testing.expect_value(t, app.settings_commit(s, ui.editor_source(first), updated, first), settings.Save_Error.None) {return}
	testing.expect_value(t, second.hsv, [3]f32{120, 0.75, 0})
	testing.expect_value(t, ui.editor_popup(second), ui.Editor_Popup.Color)
}
