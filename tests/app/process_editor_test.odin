package app_test

import app "../../src"
import "aio:settings"
import "aio:ui"
import "core:os"
import "core:strings"
import "core:testing"

@(private)
process_app_fixture :: proc(t: ^testing.T, f: ^Palette_Fixture, name: string) -> bool {
	if !commit_open_pages(t, f, name) {return false}
	p := &f.state.windows[0].editor
	return testing.expect_value(t, commit_value(&f.state, settings.PADDING_GROUPS_KEY, "Editors:0:nvim,vim;Tools:8:less", app.Settings_Page{p}), app.Settings_Status.Applied)
}

@(test)
process_editor_saves_runtime_rules_and_keeps_new_group_drafts_across_other_writers :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !process_app_fixture(t, &f, "process-save") {return}
	s, w := &f.state, f.state.windows[0]
	p := &w.editor
	app.settings_reveal_page(p, {key = "process.group.1.program.1", focus = .Control})
	ui.field_set(&p.value, "helix")
	app.editor_outcome(s, w, .Save)
	testing.expect_value(t, s.settings.process.padding_groups, "Editors:0:helix,vim;Tools:8:less")
	testing.expect_value(t, ui.editor_row(p).key, "process.group.1.program.1")
	testing.expect_value(t, ui.field_string(&p.value), "helix")
	testing.expect(t, !p.process_dirty)
	testing.expect(t, ui.editor_reveal(p, ui.Reveal_Row{"process.group.0.add"}))
	_ = ui.editor_process_activate(p, ui.editor_row(p))
	ui.field_set(&p.value, "Focus")
	app.editor_outcome(s, w, .Save)
	testing.expect(t, p.error)
	testing.expect_value(t, s.settings.process.padding_groups, "Editors:0:helix,vim;Tools:8:less")
	testing.expect_value(t, commit_value(s, "pane.gap", "11", app.Settings_Expected{ui.editor_source(p)}), app.Settings_Status.Applied)
	testing.expect(t, p.process_dirty)
	testing.expect(t, ui.editor_reveal(p, ui.Reveal_Row{"process.group.3.program.1"}))
	ui.editor_focus_row(p)
	ui.field_set(&p.value, "claude")
	app.editor_outcome(s, w, .Save)
	testing.expect_value(t, s.settings.process.padding_groups, "Editors:0:helix,vim;Tools:8:less;Focus:8:claude")
	testing.expect_value(t, s.settings.pane.gap, 11)
	for window in s.windows {
		testing.expect_value(t, ui.editor_source(&window.editor), ui.editor_source(p))
	}
	before := strings.clone(ui.editor_source(p), context.temp_allocator)
	ui.field_set(&p.value, "a,b")
	app.editor_outcome(s, w, .Save)
	testing.expect(t, p.error)
	data, error := os.read_entire_file(f.path, context.temp_allocator)
	testing.expect_value(t, error, nil)
	testing.expect_value(t, string(data), before)
}

// A program draft rides along with publication even when the page's search shows no row, so the
// page stays current and the draft still saves.
@(test)
process_editor_keeps_a_program_draft_current_while_search_shows_no_row :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !process_app_fixture(t, &f, "process-no-row") {return}
	s, w := &f.state, f.state.windows[0]
	p := &w.editor
	testing.expect(t, ui.editor_reveal(p, ui.Reveal_Row{"process.group.0.add"}))
	_ = ui.editor_process_activate(p, ui.editor_row(p))
	ui.field_set(&p.value, "Focus")
	app.editor_outcome(s, w, .Save)
	testing.expect(t, p.process_dirty)
	ui.field_set(&p.filter, "qqqqqqqqqqqq")
	ui.editor_filter(p)
	if !testing.expect(t, ui.editor_row(p) == nil) {return}
	updated := commit_text(t, ui.editor_source(p), "pane.gap", "11")
	testing.expect_value(t, commit_value(s, "pane.gap", "11", app.Settings_Expected{ui.editor_source(p)}), app.Settings_Status.Applied)
	expect_revision(t, p, true)
	testing.expect_value(t, ui.editor_source(p), updated)
	testing.expect(t, p.process_dirty)
	ui.field_set(&p.filter, "")
	ui.editor_filter(p)
	testing.expect(t, ui.editor_reveal(p, ui.Reveal_Row{"process.group.3.program.1"}))
	ui.editor_focus_row(p)
	ui.field_set(&p.value, "claude")
	app.editor_outcome(s, w, .Save)
	testing.expect_value(t, s.settings.process.padding_groups, "Editors:0:nvim,vim;Tools:8:less;Focus:8:claude")
}

@(test)
process_editor_always_confirms_deletion_and_rejects_changed_subjects :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !process_app_fixture(t, &f, "process-delete") {return}
	s, w := &f.state, f.state.windows[0]
	p := &w.editor
	app.editor_process_remove_ask(s, w, 1)
	c := app.confirmation_current(w)
	if !testing.expect(t, c != nil && app.confirmation_asking(w, app.Process_Remove) != nil) {return}
	testing.expect(t, !c.show_option)
	testing.expect_value(t, c.focus, ui.Confirm_Button.Cancel)
	app.confirmation_finish(s, w, false)
	testing.expect_value(t, s.settings.process.padding_groups, "Editors:0:nvim,vim;Tools:8:less")
	app.editor_process_remove_ask(s, w, 1)
	testing.expect_value(t, commit_value(s, settings.PADDING_GROUPS_KEY, "Different:4:codex;Tools:8:less", app.Settings_Expected{ui.editor_source(p)}), app.Settings_Status.Applied)
	app.confirmation_finish(s, w, true)
	testing.expect_value(t, s.settings.process.padding_groups, "Different:4:codex;Tools:8:less")
	testing.expect(t, p.error)
	app.editor_process_remove_ask(s, w, 1)
	c = app.confirmation_current(w)
	testing.expect(t, c != nil && !c.show_option)
	app.confirmation_finish(s, w, true)
	testing.expect_value(t, s.settings.process.padding_groups, "Tools:8:less")
	testing.expect(t, !p.process_dirty)
}

@(test)
process_editor_uncommitted_field_cannot_follow_a_different_groups_positional_key :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !process_app_fixture(t, &f, "process-draft-conflict") {return}
	s := &f.state
	writer, peer := &s.windows[0].editor, &s.windows[1].editor
	app.settings_reveal_page(peer, {key = "process.group.1.program.1", focus = .Control})
	ui.field_set(&peer.value, "pending-program")
	before := strings.clone(ui.editor_source(peer), context.temp_allocator)
	testing.expect_value(t, commit_value(s, settings.PADDING_GROUPS_KEY, "Different:4:codex;Tools:8:less", app.Settings_Page{writer}), app.Settings_Status.Applied)
	testing.expect_value(t, ui.editor_source(peer), before)
	testing.expect_value(t, ui.field_string(&peer.value), "pending-program")
	app.editor_outcome(s, s.windows[1], .Save)
	testing.expect(t, peer.error)
	testing.expect_value(t, s.settings.process.padding_groups, "Different:4:codex;Tools:8:less")
}

@(test)
process_editor_drop_outside_window_cancels_the_last_valid_target :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !process_app_fixture(t, &f, "process-outside-drop") {return}
	s, w := &f.state, f.state.windows[0]
	p := &w.editor
	testing.expect(t, ui.editor_reveal(p, ui.Reveal_Row{"process.group.1"}))
	p.scroll = p.selected
	l := app.settings_layout(w)
	first := ui.editor_row_parts(p, l, p.selected).row
	second := first
	for item, index in p.items {
		if item.row >= 0 && p.rows[item.row].key == "process.group.2" {
			second = ui.editor_row_parts(p, l, index).row
		}
	}
	app.gesture_button(s, w, {window = w.id, button = .Left, pressed = true,
		x = i32(first.x + 18 * w.scale), y = i32(first.y + first.height / 2)})
	testing.expect(t, ui.editor_order_dragging(p, .Process_Groups))
	app.gesture_move(s, w, {window = w.id, buttons = {.Left},
		x = i32(second.x + 60), y = i32(second.y + second.height - 2)})
	testing.expect(t, ui.editor_order_target(p) > 0)
	app.gesture_move(s, w, {window = w.id, buttons = {.Left}, x = -10, y = -10})
	app.gesture_button(s, w, {window = w.id, button = .Left, pressed = false, x = -10, y = -10})
	testing.expect_value(t, s.settings.process.padding_groups, "Editors:0:nvim,vim;Tools:8:less")
	testing.expect(t, !ui.editor_dragging(p))
}
