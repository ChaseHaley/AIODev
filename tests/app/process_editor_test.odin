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
	updated := commit_text(t, p.source, settings.PADDING_GROUPS_KEY, "Editors:0:nvim,vim;Tools:8:less")
	return testing.expect_value(t, app.settings_commit(&f.state, p.source, updated, p), settings.Save_Error.None)
}

@(test)
process_editor_saves_runtime_rules_and_keeps_new_group_drafts_across_other_writers :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !process_app_fixture(t, &f, "process-save") {return}
	s, w := &f.state, f.state.windows[0]
	p := &w.editor
	app.settings_reveal_page(s, p, {key = "process.group.1.program.1", focus = .Control})
	ui.field_set(&p.value, "helix")
	app.editor_outcome(s, w, .Save)
	testing.expect_value(t, s.settings.process.padding_groups, "Editors:0:helix,vim;Tools:8:less")
	testing.expect_value(t, ui.editor_row(p).key, "process.group.1.program.1")
	testing.expect_value(t, ui.field_string(&p.value), "helix")
	testing.expect(t, !p.process_dirty)
	testing.expect(t, ui.editor_reveal(p, "process.group.0.add"))
	_ = ui.editor_process_activate(p, ui.editor_row(p))
	ui.field_set(&p.value, "Focus")
	app.editor_outcome(s, w, .Save)
	testing.expect(t, p.error)
	testing.expect_value(t, s.settings.process.padding_groups, "Editors:0:helix,vim;Tools:8:less")
	updated := commit_text(t, p.source, "pane.gap", "11")
	testing.expect_value(t, app.settings_commit(s, p.source, updated), settings.Save_Error.None)
	testing.expect(t, p.process_dirty)
	testing.expect(t, ui.editor_reveal(p, "process.group.3.program.1"))
	p.focus = .Control
	ui.field_set(&p.value, "claude")
	app.editor_outcome(s, w, .Save)
	testing.expect_value(t, s.settings.process.padding_groups, "Editors:0:helix,vim;Tools:8:less;Focus:8:claude")
	testing.expect_value(t, s.settings.pane.gap, 11)
	for window in s.windows {
		testing.expect_value(t, window.editor.source, p.source)
	}
	before := strings.clone(p.source, context.temp_allocator)
	ui.field_set(&p.value, "a,b")
	app.editor_outcome(s, w, .Save)
	testing.expect(t, p.error)
	data, error := os.read_entire_file(f.path, context.temp_allocator)
	testing.expect_value(t, error, nil)
	testing.expect_value(t, string(data), before)
}

@(test)
process_editor_always_confirms_deletion_and_rejects_changed_subjects :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !process_app_fixture(t, &f, "process-delete") {return}
	s, w := &f.state, f.state.windows[0]
	p := &w.editor
	p.process_remove = 1
	app.editor_process_remove_ask(s, w)
	testing.expect(t, w.process_remove_confirm.open)
	testing.expect(t, !w.process_remove_confirm.show_option)
	testing.expect_value(t, w.process_remove_confirm.focus, ui.Confirm_Button.Cancel)
	app.editor_process_remove_finish(s, w, false)
	testing.expect_value(t, s.settings.process.padding_groups, "Editors:0:nvim,vim;Tools:8:less")
	p.process_remove = 1
	app.editor_process_remove_ask(s, w)
	updated := commit_text(t, p.source, settings.PADDING_GROUPS_KEY, "Different:4:codex;Tools:8:less")
	testing.expect_value(t, app.settings_commit(s, p.source, updated), settings.Save_Error.None)
	app.editor_process_remove_finish(s, w, true)
	testing.expect_value(t, s.settings.process.padding_groups, "Different:4:codex;Tools:8:less")
	testing.expect(t, p.error)
	p.process_remove = 1
	app.editor_process_remove_ask(s, w)
	testing.expect(t, !w.process_remove_confirm.show_option)
	app.editor_process_remove_finish(s, w, true)
	testing.expect_value(t, s.settings.process.padding_groups, "Tools:8:less")
	testing.expect(t, !p.process_dirty)
}
