package app_test

import app "../../src"
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

@(private)
commit_open_pages :: proc(t: ^testing.T, f: ^Palette_Fixture, name: string) -> bool {
	if !palette_fixture_create(t, f, name) {return false}
	for window in f.state.windows {
		app.editor_open(&f.state, window)
		if !testing.expect(t, window.editor.open) {return false}
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
	updated := commit_text(t, first.source, "pane.gap", "9")
	if !testing.expect_value(t, app.settings_commit(s, first.source, updated, first), settings.Save_Error.None) {return}
	testing.expect_value(t, s.settings.pane.gap, 9)
	testing.expect_value(t, first.source, updated)
	testing.expect_value(t, ui.editor_row(first).key, "pane.gap")
	testing.expect_value(t, ui.editor_row(first).value, "9")
	testing.expect_value(t, ui.field_string(&first.value), "9")
	testing.expect_value(t, second.source, updated)
	testing.expect_value(t, ui.field_string(&second.filter), "font")
	testing.expect_value(t, ui.editor_row(second).key, "font.size")
	testing.expect_value(t, ui.field_string(&second.value), "19")
	testing.expect_value(t, second.value.cursor, 1)
	testing.expect_value(t, second.value.anchor, 0)
	testing.expect_value(t, second.focus, ui.Editor_Focus.Control)
	testing.expect_value(t, second.message, "Pending field")
	testing.expect(t, second.error)
	updated = commit_text(t, first.source, "tabs.orientation", "vertical")
	if !testing.expect_value(t, app.settings_commit(s, first.source, updated), settings.Save_Error.None) {return}
	for window in s.windows {
		testing.expect(t, !window.tabs_horizontal)
		testing.expect_value(t, window.editor.source, updated)
	}
	testing.expect_value(t, ui.field_string(&second.value), "19")
	updated = commit_text(t, second.source, "font.size", ui.field_string(&second.value))
	if !testing.expect_value(t, app.settings_commit(s, second.source, updated, second), settings.Save_Error.None) {return}
	testing.expect_value(t, s.settings.font.size, 19.0)
	testing.expect_value(t, ui.editor_row(second).value, "19")
	testing.expect_value(t, first.source, updated)
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
	previous := strings.clone(p.source, context.temp_allocator)
	font_size := s.settings.font.size
	external := commit_text(t, previous, "pane.gap", "9")
	if !testing.expect_value(t, os.write_entire_file(f.path, external), nil) {return}
	updated := commit_text(t, previous, "font.size", "19")
	testing.expect_value(t, app.settings_commit(s, p.source, updated, p), settings.Save_Error.Conflict)
	testing.expect_value(t, s.settings.font.size, font_size)
	for window in s.windows {testing.expect_value(t, window.editor.source, previous)}
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
	previous := strings.clone(p.source, context.temp_allocator)
	external := commit_text(t, previous, "pane.gap", "9")
	if !testing.expect_value(t, os.write_entire_file(f.path, external), nil) {return}
	updated := commit_text(t, external, "tabs.orientation", "vertical")
	if !testing.expect_value(t, app.settings_commit(s, external, updated), settings.Save_Error.None) {return}
	testing.expect_value(t, s.settings.pane.gap, 9)
	testing.expect_value(t, s.settings.tabs.orientation, settings.Tabs_Orientation.Vertical)
	for window in s.windows {testing.expect_value(t, window.editor.source, previous)}
	candidate := commit_text(t, p.source, "font.size", "19")
	testing.expect_value(t, app.settings_commit(s, p.source, candidate, p), settings.Save_Error.Conflict)
}

@(test)
settings_commit_io_failure_does_not_publish :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !commit_open_pages(t, &f, "commit-io") {return}
	s := &f.state
	p := &s.windows[0].editor
	previous := strings.clone(p.source, context.temp_allocator)
	gap := s.settings.pane.gap
	updated := commit_text(t, previous, "pane.gap", "9")
	previous_path := s.settings_path
	s.settings_path = strings.concatenate({f.directory, "/missing/settings.ini"}, context.temp_allocator)
	defer s.settings_path = previous_path
	context.logger = {}
	testing.expect_value(t, app.settings_commit(s, p.source, updated, p), settings.Save_Error.IO)
	testing.expect_value(t, s.settings.pane.gap, gap)
	for window in s.windows {testing.expect_value(t, window.editor.source, previous)}
}

@(test)
settings_commit_keeps_a_removed_profiles_draft_as_a_conflict :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !commit_open_pages(t, &f, "commit-removed") {return}
	s := &f.state
	first, second := &s.windows[0].editor, &s.windows[1].editor
	updated := commit_text(t, first.source, "profile.custom.command", "cmd.exe")
	updated = commit_text(t, updated, "profile.custom.name", "Custom")
	if !testing.expect_value(t, app.settings_commit(s, first.source, updated, first), settings.Save_Error.None) {return}
	app.settings_reveal_page(s, second, {key = "profile.custom.name", focus = .Control})
	ui.field_set(&second.value, "My pending name")
	previous := strings.clone(second.source, context.temp_allocator)
	removed, remove_error := settings.remove_profile_text(first.source, "custom", context.temp_allocator)
	if !testing.expect_value(t, remove_error, nil) {return}
	if !testing.expect_value(t, app.settings_commit(s, first.source, removed, first), settings.Save_Error.None) {return}
	testing.expect(t, settings.profile_find(&s.settings.profiles, "custom") == nil)
	testing.expect_value(t, second.source, previous)
	testing.expect_value(t, ui.editor_row(second).key, "profile.custom.name")
	testing.expect_value(t, ui.field_string(&second.value), "My pending name")
	candidate := commit_text(t, second.source, "profile.custom.name", ui.field_string(&second.value))
	testing.expect_value(t, app.settings_commit(s, second.source, candidate, second), settings.Save_Error.Conflict)
}

@(test)
settings_commit_keeps_the_origins_color_picker_and_hsv_after_drag_release :: proc(t: ^testing.T) {
	f: Profile_Fixture
	defer profile_fixture_destroy(t, &f)
	if !profile_fixture_create(t, &f, "commit-picker", PROFILE_FIXTURE_SETTINGS) {return}
	p := profile_open(&f)
	w := f.state.windows[0]
	app.settings_reveal_page(&f.state, p, {key = "colors.cursor", focus = .Control})
	cases := [?]struct {value: string, hsv: [3]f32, drag: ui.Editor_Drag} {
		{"#000000", {120, 0.75, 0}, .Ramp},
		{"#408020", {100, 0.75, 0.5}, .Wheel},
	}
	for entry in cases {
		ui.field_set(&p.value, entry.value)
		p.popup, p.hsv, p.drag = .Color, entry.hsv, entry.drag
		outcome := ui.editor_release(p)
		if !testing.expect_value(t, outcome, ui.Editor_Outcome.Save) {return}
		app.editor_outcome(&f.state, w, outcome)
		testing.expect(t, !p.error)
		testing.expect_value(t, ui.editor_row(p).key, "colors.cursor")
		testing.expect_value(t, ui.field_string(&p.value), entry.value)
		testing.expect_value(t, p.popup, ui.Editor_Popup.Color)
		testing.expect_value(t, p.hsv, entry.hsv)
		testing.expect_value(t, p.drag, ui.Editor_Drag.None)
	}
}

@(test)
settings_commit_rebuilds_a_clean_peers_picker_hsv_when_its_effective_color_changes :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !commit_open_pages(t, &f, "commit-peer-picker") {return}
	s := &f.state
	first, second := &s.windows[0].editor, &s.windows[1].editor
	updated := theme_commit_text(t, first.source, "cursor", "#000000")
	if !testing.expect_value(t, app.settings_commit(s, first.source, updated, first), settings.Save_Error.None) {return}
	app.settings_reveal_page(s, second, {key = "colors.cursor", focus = .Control})
	second.popup, second.hsv = .Color, {120, 0.75, 0}
	updated = theme_commit_text(t, first.source, "cursor", "#408020")
	if !testing.expect_value(t, app.settings_commit(s, first.source, updated, first), settings.Save_Error.None) {return}
	testing.expect_value(t, second.popup, ui.Editor_Popup.Color)
	testing.expect_value(t, ui.field_string(&second.value), "#408020")
	h, saturation, value := settings.rgb_to_hsv({64, 128, 32})
	testing.expect_value(t, second.hsv, [3]f32{h, saturation, value})
	updated = theme_commit_text(t, first.source, "cursor", "#000000")
	if !testing.expect_value(t, app.settings_commit(s, first.source, updated, first), settings.Save_Error.None) {return}
	second.hsv = {120, 0.75, 0}
	updated = commit_text(t, first.source, "pane.gap", "9")
	if !testing.expect_value(t, app.settings_commit(s, first.source, updated, first), settings.Save_Error.None) {return}
	testing.expect_value(t, second.hsv, [3]f32{120, 0.75, 0})
	testing.expect_value(t, second.popup, ui.Editor_Popup.Color)
}
