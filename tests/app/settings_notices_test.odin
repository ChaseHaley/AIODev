package app_test

import "base:runtime"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import app "../../src"
import "aio:commands"
import "aio:platform"
import "aio:settings"
import "aio:ui"

@(test)
settings_notices_preserve_expiry_and_reappear_only_for_changed_or_reintroduced_problems :: proc(t: ^testing.T) {
	state: app.App
	ui.notices_init(&state.notices)
	defer ui.notices_destroy(&state.notices)
	defer settings.diagnostics_destroy(&state.settings_diagnostics)
	issues := make([dynamic]settings.Diagnostic)
	defer settings.diagnostics_destroy(&issues)
	testing.expect_value(t, settings.diagnostic_append(&issues, 92, "input.leader",
		"input.leader vs Select All (edit.select_all); input.leader wins [settings.ini:92; defaults]",
		.Shortcut_Warning), nil)
	show_diagnostics_quietly(&state, &issues, nil)
	if !testing.expect_value(t, len(state.notices.items), 1) { return }
	first := state.notices.items[0]
	testing.expect_value(t, first.kind, ui.Notice_Kind.Warning)
	testing.expect(t, strings.contains(first.text, "Settings"))
	testing.expect(t, !strings.contains(first.text, "settings.ini:") && !strings.contains(first.text, "Line 92"))
	testing.expect_value(t, settings.diagnostic_append(&issues, 93, "input.leader",
		"input.leader vs Select All (edit.select_all); input.leader wins [settings.ini:93; defaults]",
		.Shortcut_Warning), nil)
	show_diagnostics_quietly(&state, &issues, nil)
	testing.expect_value(t, state.notices.items[0].expires, first.expires)
	testing.expect(t, ui.notices_expire(&state.notices, time.tick_add(first.expires, time.Second)))
	testing.expect_value(t, settings.diagnostic_append(&issues, 93, "input.leader",
		"input.leader vs Select All (edit.select_all); input.leader wins [settings.ini:93; defaults]",
		.Shortcut_Warning), nil)
	show_diagnostics_quietly(&state, &issues, nil)
	testing.expect_value(t, len(state.notices.items), 0)
	testing.expect_value(t, settings.diagnostic_append(&issues, 1, "font.size", "invalid number", .Invalid_Value), nil)
	show_diagnostics_quietly(&state, &issues, nil)
	testing.expect_value(t, state.notices.items[0].kind, ui.Notice_Kind.Error)
	testing.expect(t, strings.contains(state.notices.items[0].text, "log"))
	show_diagnostics_quietly(&state, &issues, nil)
	testing.expect_value(t, len(state.notices.items), 0)
	show_diagnostics_quietly(&state, &issues, os.Error(os.General_Error.Invalid_Path))
	testing.expect_value(t, state.notices.items[0].kind, ui.Notice_Kind.Error)
	testing.expect(t, strings.contains(state.notices.items[0].text, "Using defaults"))
	read_expiry := state.notices.items[0].expires
	show_diagnostics_quietly(&state, &issues, os.Error(os.General_Error.Invalid_Path))
	testing.expect_value(t, state.notices.items[0].expires, read_expiry)
	ui.notices_clear(&state.notices, state.notices.items[0].key)
	show_diagnostics_quietly(&state, &issues, os.Error(os.General_Error.Not_Exist))
	testing.expect_value(t, len(state.notices.items), 1)
	show_diagnostics_quietly(&state, &issues, nil)
	testing.expect_value(t, len(state.notices.items), 0)
	testing.expect_value(t, settings.diagnostic_append(&issues, 1, "font.size", "invalid number", .Invalid_Value), nil)
	show_diagnostics_quietly(&state, &issues, nil)
	testing.expect_value(t, len(state.notices.items), 1)
}

@(test)
settings_diagnostic_comparison_ignores_order_and_locations_but_preserves_new_meanings :: proc(t: ^testing.T) {
	a := [?]settings.Diagnostic{{1, "a", "invalid", .Invalid_Value}, {2, "b", "unknown", .Unknown_Key}}
	b := [?]settings.Diagnostic{{8, "b", "unknown", .Unknown_Key}, {9, "a", "invalid", .Invalid_Value}}
	testing.expect(t, app.settings_diagnostics_equal(a[:], b[:]))
	b[0].message = "different"
	testing.expect(t, !app.settings_diagnostics_equal(a[:], b[:]))
	b[0] = a[0]
	b[1] = a[0]
	testing.expect(t, !app.settings_diagnostics_equal(a[:], b[:]))
	b = a
	b[0].kind = .Out_Of_Range
	testing.expect(t, !app.settings_diagnostics_equal(a[:], b[:]))
	leader_a := [?]settings.Diagnostic{{1, "input.leader",
		"input.leader (Ctrl+B) vs New Tab; input.leader wins [settings.ini:1; defaults]", .Shortcut_Warning}}
	leader_b := [?]settings.Diagnostic{{2, "input.leader",
		"input.leader (Ctrl+T) vs New Tab; input.leader wins [settings.ini:2; defaults]", .Shortcut_Warning}}
	testing.expect(t, !app.settings_diagnostics_equal(leader_a[:], leader_b[:]))
}

@(test)
settings_load_keeps_source_order_conflict_and_text_field_chords_separate :: proc(t: ^testing.T) {
	directory, directory_error := os.make_directory_temp("", "aio-notices-*", context.allocator)
	if !testing.expect_value(t, directory_error, nil) { return }
	defer delete(directory)
	defer os.remove(directory)
	path := strings.concatenate({directory, "/settings.ini"})
	defer delete(path)
	defer os.remove(path)
	state := app.App{settings_path = path, registry = commands.create()}
	defer commands.destroy(&state.registry)
	defer settings.destroy(&state.settings)
	defer settings.diagnostics_destroy(&state.settings_diagnostics)
	ui.notices_init(&state.notices)
	defer ui.notices_destroy(&state.notices)
	if !testing.expect_value(t, app.register_actions(&state.registry), commands.Error.None) { return }
	if !testing.expect_value(t, os.write_entire_file(path, "input.leader = Ctrl+Shift+A\n"), nil) { return }
	app.load_settings(&state)
	testing.expect(t, state.leader != nil)
	testing.expect_value(t, len(state.settings_diagnostics), 1)
	testing.expect_value(t, state.settings_diagnostics[0].kind, settings.Diagnostic_Kind.Shortcut_Warning)
	select_all := commands.find(&state.registry, "edit.select_all")
	testing.expect_value(t, len(commands.active_shortcuts(select_all)), 0)
	expires := state.notices.items[0].expires
	app.load_settings(&state)
	testing.expect_value(t, state.notices.items[0].expires, expires)
	if !testing.expect_value(t, os.write_entire_file(path, "input.leader = Ctrl+A\n"), nil) { return }
	app.load_settings(&state)
	testing.expect_value(t, len(state.settings_diagnostics), 0)
	testing.expect_value(t, len(state.notices.items), 0)
	testing.expect_value(t, len(commands.active_shortcuts(select_all)), 1)
	if !testing.expect_value(t, os.write_entire_file(path,
		"input.leader = Ctrl+Shift+A\nkeys.edit.select_all = Ctrl+Shift+A\n"), nil) { return }
	app.load_settings(&state)
	testing.expect(t, state.leader == nil)
	testing.expect_value(t, len(commands.active_shortcuts(select_all)), 1)
	testing.expect_value(t, state.notices.items[0].kind, ui.Notice_Kind.Warning)
}

@(test)
settings_bracket_leader_preserves_actions_and_winners_after_notice_expiry :: proc(t: ^testing.T) {
	a := [?]settings.Diagnostic{{10, "input.leader",
		"input.leader (Ctrl+[) vs New Tab (tab.new); input.leader wins [settings.ini:10; settings.ini:9]",
		.Shortcut_Warning}}
	b := [?]settings.Diagnostic{{11, "input.leader",
		"input.leader (Ctrl+[) vs Close Tab (tab.close); input.leader wins [settings.ini:11; defaults]",
		.Shortcut_Warning}}
	c := [?]settings.Diagnostic{{10, "input.leader",
		"input.leader (Ctrl+[) vs New Tab (tab.new); tab.new wins [settings.ini:10; settings.ini:11]",
		.Shortcut_Warning}}
	d := [?]settings.Diagnostic{{12, "input.leader",
		"input.leader (Ctrl+[) vs New Tab (tab.new); input.leader wins [settings.ini:12; settings.ini:11]",
		.Shortcut_Warning}}
	testing.expect(t, !app.settings_diagnostics_equal(a[:], b[:]), "changed action must remain visible")
	testing.expect(t, !app.settings_diagnostics_equal(a[:], c[:]), "changed winner must remain visible")
	testing.expect(t, app.settings_diagnostics_equal(a[:], d[:]), "source-line moves stay quiet")
	state: app.App
	ui.notices_init(&state.notices)
	defer ui.notices_destroy(&state.notices)
	defer settings.diagnostics_destroy(&state.settings_diagnostics)
	issues := make([dynamic]settings.Diagnostic)
	defer settings.diagnostics_destroy(&issues)
	sequence := [?]settings.Diagnostic{a[0], d[0], b[0], c[0]}
	for diagnostic in sequence {
		testing.expect_value(t, settings.diagnostic_append(&issues, diagnostic.line,
			diagnostic.key, diagnostic.message, diagnostic.kind), nil)
		show_diagnostics_quietly(&state, &issues, nil)
		if diagnostic.message == d[0].message {
			testing.expect_value(t, len(state.notices.items), 0)
			continue
		}
		if !testing.expect_value(t, len(state.notices.items), 1) { continue }
		testing.expect_value(t, state.notices.items[0].kind, ui.Notice_Kind.Warning)
		testing.expect(t, ui.notices_expire(&state.notices,
			time.tick_add(state.notices.items[0].expires, time.Second)))
	}
}

show_diagnostics_quietly :: proc(state: ^app.App, issues: ^[dynamic]settings.Diagnostic, error: os.Error) {
	logger := context.logger
	context.logger = {}
	defer context.logger = logger
	app.show_settings_diagnostics(state, issues, error)
}

@(private="file")
poison_parent: runtime.Allocator

// Overwrites freed bytes so text that outlives its owner is detected deterministically.
@(private="file")
poison_free :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int,
	old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]u8, runtime.Allocator_Error) {
	if mode == .Free && old_memory != nil && old_size > 0 { mem.set(old_memory, 0xAA, old_size) }
	return poison_parent.procedure(poison_parent.data, mode, size, alignment, old_memory, old_size, loc)
}

@(test)
settings_inline_shortcut_warning_outlives_validation :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "InlineWarning") { return }
	s := &f.state
	w := s.windows[0]
	app.editor_open(s, w)
	app.handle_event(s, platform.Text_Event{w.id, "input.leader"})
	if !testing.expect_value(t, ui.editor_row(&w.editor).key, "input.leader") { return }
	ui.field_set(&w.editor.value, "Ctrl+Shift+T")
	poison_parent = context.allocator
	{
		context.allocator = runtime.Allocator{poison_free, nil}
		logger := context.logger
		context.logger = {}
		defer context.logger = logger
		app.editor_outcome(s, w, .Save)
	}
	testing.expect(t, !w.editor.error)
	testing.expect_value(t, w.editor.message,
		"Saved. input.leader (Ctrl+Shift+T) vs New Tab (tab.new); input.leader wins")
}
