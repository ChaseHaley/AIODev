package settings_test

import "core:testing"
import "aio:settings"

@(test)
shortcut_origins_keep_last_written_source_line :: proc(t: ^testing.T) {
	s, diagnostics, err := settings.parse("# heading\ninput.leader = Ctrl+B\nkeys.tab.new = Ctrl+B\n"+
		"input.leader = Ctrl+T\nkeys.tab.new = Physical+Ctrl+Y\n")
	testing.expect_value(t, err, nil)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&diagnostics)
	testing.expect_value(t, settings.setting_line(&s, "input.leader"), 4)
	testing.expect_value(t, s.input.leader, "Ctrl+T")
	testing.expect_value(t, len(s.keys), 1)
	testing.expect_value(t, s.keys[0].line, 5)
	testing.expect_value(t, s.keys[0].value, "Physical+Ctrl+Y")
	testing.expect_value(t, len(diagnostics), 2)
}

@(test)
shortcut_warning_kind_is_preserved :: proc(t: ^testing.T) {
	diagnostics := make([dynamic]settings.Diagnostic)
	defer settings.diagnostics_destroy(&diagnostics)
	testing.expect_value(t, settings.diagnostic_append(&diagnostics, 4, "input.leader",
		"input.leader conflicts with tab.new; input.leader wins", .Shortcut_Warning), nil)
	testing.expect_value(t, diagnostics[0].kind, settings.Diagnostic_Kind.Shortcut_Warning)
	testing.expect_value(t, diagnostics[0].line, 4)
	testing.expect_value(t, diagnostics[0].identity, diagnostics[0].message)
}

@(test)
diagnostic_identity_is_supplied_by_its_producer_or_is_the_whole_message :: proc(t: ^testing.T) {
	diagnostics := make([dynamic]settings.Diagnostic)
	defer settings.diagnostics_destroy(&diagnostics)
	message := "literal [not a location]"
	testing.expect_value(t, settings.diagnostic_append(
		&diagnostics, 4, "input.leader", message, .Shortcut_Warning,
	), nil)
	testing.expect_value(t, diagnostics[0].identity, message)
	testing.expect_value(t, settings.diagnostic_append(
		&diagnostics, 5, "input.leader", message, .Shortcut_Warning, "producer meaning",
	), nil)
	testing.expect_value(t, diagnostics[1].identity, "producer meaning")
}
