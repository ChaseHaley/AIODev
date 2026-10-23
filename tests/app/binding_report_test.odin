package app_test

import "core:testing"
import app "../../src"
import "aio:commands"
import "aio:input"
import "aio:platform"
import "aio:settings"
import "aio:ui"

@(private, require_results)
binding_report_for_text :: proc(
	t: ^testing.T,
	registry: ^commands.Registry,
	text: string,
) -> (
	s: settings.Settings,
	report: app.Binding_Report,
	ok: bool,
) {
	if !testing.expect_value(t, app.register_actions(registry), commands.Error.None) {return}
	parsed, diagnostics, parse_error := settings.parse(text)
	defer settings.diagnostics_destroy(&diagnostics)
	if !testing.expect_value(t, parse_error, nil) {return}
	created, report_error := app.binding_report(registry, &parsed)
	if !testing.expect_value(t, report_error, nil) {
		settings.destroy(&parsed)
		return
	}
	return parsed, created, true
}

@(test)
binding_report_keeps_duplicate_winner_origins_and_text :: proc(t: ^testing.T) {
	registry := commands.create()
	defer commands.destroy(&registry)
	s, report, ok := binding_report_for_text(t, &registry, "keys.edit.select_all = Ctrl+Shift+T\n")
	if !ok {return}
	defer settings.destroy(&s)
	if !testing.expect_value(t, len(report.issues), 1) {return}
	issue := report.issues[0]
	testing.expect_value(t, issue.kind, app.Binding_Issue_Kind.Duplicate_Shortcut)
	testing.expect_value(t, issue.severity, settings.Diagnostic_Kind.Invalid_Value)
	testing.expect_value(t, issue.line, 1)
	testing.expect_value(t, issue.key, "keys.edit.select_all")
	testing.expect_value(t, issue.apply_error, commands.Error.Duplicate_Shortcut)
	testing.expect_value(t, issue.conflict.loser.name, "edit.select_all")
	testing.expect_value(t, issue.conflict.loser.title, "Select All")
	testing.expect_value(t, issue.conflict.loser.line, 1)
	testing.expect_value(t, issue.conflict.winner.name, "tab.new")
	testing.expect_value(t, issue.conflict.winner.title, "New Tab")
	testing.expect_value(t, issue.conflict.winner.line, 0)
	testing.expect_value(t, issue.conflict.shortcut.key, input.Key.T)
	testing.expect_value(t, issue.conflict.shortcut.modifiers, input.Modifiers{.Control, .Shift})
	testing.expect_value(t, app.binding_issue_text(issue, "C:/data/settings.ini"),
		"shortcut \"Ctrl+Shift+T\" for Select All (edit.select_all at settings.ini:1) " +
		"already used by New Tab (tab.new at defaults)")
	select_all := commands.find(&registry, "edit.select_all")
	testing.expect_value(t, len(commands.active_shortcuts(select_all)), 1)
	testing.expect_value(t, commands.active_shortcuts(select_all)[0].key, input.Key.A)
}

@(test)
binding_report_keeps_default_origin_for_a_rejected_override :: proc(t: ^testing.T) {
	registry := commands.create()
	defer commands.destroy(&registry)
	s, report, ok := binding_report_for_text(t, &registry,
		"input.leader = Ctrl+Shift+T\nkeys.tab.new = Ctrl+Shift+P\n")
	if !ok {return}
	defer settings.destroy(&s)
	if !testing.expect_value(t, len(report.issues), 2) {return}
	duplicate := report.issues[0]
	testing.expect_value(t, duplicate.kind, app.Binding_Issue_Kind.Duplicate_Shortcut)
	testing.expect_value(t, duplicate.conflict.loser.name, "tab.new")
	testing.expect_value(t, duplicate.conflict.loser.line, 2)
	testing.expect_value(t, duplicate.conflict.winner.name, "app.command_palette")
	testing.expect_value(t, duplicate.conflict.winner.line, 0)
	testing.expect_value(t, app.binding_issue_text(duplicate, "settings.ini"),
		"shortcut \"Ctrl+Shift+P\" for New Tab (tab.new at settings.ini:2) " +
		"already used by Show Command Palette (app.command_palette at defaults)")
	leader := report.issues[1]
	testing.expect_value(t, leader.kind, app.Binding_Issue_Kind.Leader_Prefix)
	testing.expect_value(t, leader.conflict.loser.name, "tab.new")
	testing.expect_value(t, leader.conflict.loser.line, 0)
	testing.expect_value(t, leader.conflict.winner.name, "input.leader")
	testing.expect_value(t, app.binding_issue_text(leader, "settings.ini"),
		"input.leader (Ctrl+Shift+T) vs New Tab (tab.new); " +
		"input.leader wins [settings.ini:1; defaults]")
	testing.expect(t, report.leader != nil)
}

@(test)
binding_report_keeps_leader_prefix_winner_origins_and_text :: proc(t: ^testing.T) {
	registry := commands.create()
	defer commands.destroy(&registry)
	s, report, ok := binding_report_for_text(t, &registry, "input.leader = Ctrl+Shift+T\n")
	if !ok {return}
	defer settings.destroy(&s)
	if !testing.expect_value(t, len(report.issues), 1) {return}
	issue := report.issues[0]
	testing.expect_value(t, issue.kind, app.Binding_Issue_Kind.Leader_Prefix)
	testing.expect_value(t, issue.severity, settings.Diagnostic_Kind.Shortcut_Warning)
	testing.expect_value(t, issue.line, 1)
	testing.expect_value(t, issue.key, "input.leader")
	testing.expect_value(t, issue.conflict.loser.name, "tab.new")
	testing.expect_value(t, issue.conflict.loser.title, "New Tab")
	testing.expect_value(t, issue.conflict.loser.line, 0)
	testing.expect_value(t, issue.conflict.winner.name, "input.leader")
	testing.expect_value(t, issue.conflict.winner.line, 1)
	testing.expect_value(t, issue.conflict.leader_text, "Ctrl+Shift+T")
	testing.expect_value(t, issue.conflict.shortcut.key, input.Key.T)
	testing.expect_value(t, issue.conflict.shortcut.modifiers, input.Modifiers{.Control, .Shift})
	testing.expect_value(t, app.binding_issue_text(issue, "settings.ini"),
		"input.leader (Ctrl+Shift+T) vs New Tab (tab.new); " +
		"input.leader wins [settings.ini:1; defaults]")
	leader, enabled := report.leader.?
	testing.expect(t, enabled)
	testing.expect_value(t, leader.key, input.Key.T)
	testing.expect_value(t, leader.modifiers, input.Modifiers{.Control, .Shift})
	new_tab := commands.find(&registry, "tab.new")
	testing.expect_value(t, len(commands.active_shortcuts(new_tab)), 0)
}

@(test)
binding_report_declines_leader_when_a_later_binding_owns_its_prefix :: proc(t: ^testing.T) {
	registry := commands.create()
	defer commands.destroy(&registry)
	s, report, ok := binding_report_for_text(t, &registry,
		"input.leader = Ctrl+B\nkeys.tab.new = Ctrl+B\n")
	if !ok {return}
	defer settings.destroy(&s)
	if !testing.expect_value(t, len(report.issues), 1) {return}
	issue := report.issues[0]
	testing.expect_value(t, issue.kind, app.Binding_Issue_Kind.Leader_Prefix)
	testing.expect_value(t, issue.conflict.loser.line, 2)
	testing.expect_value(t, issue.conflict.winner.name, "tab.new")
	testing.expect_value(t, issue.conflict.winner.line, 2)
	testing.expect_value(t, app.binding_issue_text(issue, "settings.ini"),
		"input.leader (Ctrl+B) vs New Tab (tab.new); " +
		"tab.new wins [settings.ini:1; settings.ini:2]")
	testing.expect(t, report.leader == nil)
	new_tab := commands.find(&registry, "tab.new")
	testing.expect_value(t, len(commands.active_shortcuts(new_tab)), 1)
}

@(test)
binding_report_reports_unknown_commands_and_unparsed_shortcuts :: proc(t: ^testing.T) {
	registry := commands.create()
	defer commands.destroy(&registry)
	s, report, ok := binding_report_for_text(t, &registry,
		"keys.missing.command = Ctrl+W\nkeys.tab.new = Ctrl+NotAKey\n")
	if !ok {return}
	defer settings.destroy(&s)
	if !testing.expect_value(t, len(report.issues), 2) {return}
	unknown := report.issues[0]
	testing.expect_value(t, unknown.kind, app.Binding_Issue_Kind.Unknown_Command)
	testing.expect_value(t, unknown.line, 1)
	testing.expect_value(t, unknown.key, "keys.missing.command")
	testing.expect_value(t, app.binding_issue_text(unknown, "settings.ini"),
		"unknown command \"missing.command\"")
	invalid := report.issues[1]
	testing.expect_value(t, invalid.kind, app.Binding_Issue_Kind.Invalid_Shortcut)
	testing.expect_value(t, invalid.line, 2)
	testing.expect_value(t, invalid.key, "keys.tab.new")
	testing.expect_value(t, app.binding_issue_text(invalid, "settings.ini"),
		"cannot parse shortcut \"Ctrl+NotAKey\"")
}

@(test)
binding_origins_name_the_source_line_or_defaults :: proc(t: ^testing.T) {
	testing.expect_value(t, app.binding_origin("C:/data/settings.ini", 0), "defaults")
	testing.expect_value(t, app.binding_origin("C:/data/settings.ini", 3), "settings.ini:3")
	testing.expect_value(t, app.binding_origin("settings.ini", 12), "settings.ini:12")
}

@(test)
settings_inline_duplicate_names_the_winner_without_reading_prose :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "InlineDuplicate") {return}
	s := &f.state
	w := s.windows[0]
	app.editor_open(s, w)
	app.handle_event(s, platform.Text_Event{w.id, "keys.tab.new"})
	if !testing.expect_value(t, ui.editor_row(&w.editor).key, "keys.tab.new") {return}
	ui.field_set(&w.editor.value, "Ctrl+Shift+P")
	app.editor_outcome(s, w, .Save)
	testing.expect(t, w.editor.error)
	testing.expect_value(t, w.editor.message,
		"Assigned to Show Command Palette. Choose another shortcut.")
}
