package settings_test

import "core:fmt"
import "core:strings"
import "core:testing"
import "aio:settings"

@(test)
openers_parse_fields_and_display_order :: proc(t: ^testing.T) {
	fixture :: `opener.zed.name = Zed
opener.zed.command = "zed %1"
opener.zed.offers = files
opener.zed.placement = window
opener.alpha.name = "Alpha"
opener.alpha.command = alpha.exe
opener.mid.name = Mid
opener.mid.command = mid %1
opener.mid.offers = folders
opener.mid.placement = tab
opener.order = mid
`
	s, diagnostics, err := settings.parse(fixture)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&diagnostics)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(diagnostics), 0)
	zed := settings.opener_find(&s.openers, "zed")
	alpha := settings.opener_find(&s.openers, "alpha")
	if !testing.expect(t, zed != nil && alpha != nil) {return}
	testing.expect_value(t, zed.name, "Zed")
	testing.expect_value(t, zed.command, "zed %1")
	testing.expect_value(t, zed.offers, settings.Opener_Offers.Files)
	testing.expect_value(t, zed.placement, settings.Opener_Placement.Own_Window)
	testing.expect_value(t, alpha.name, "Alpha")
	testing.expect_value(t, alpha.offers, settings.Opener_Offers.Files_And_Folders)
	testing.expect_value(t, alpha.placement, settings.Opener_Placement.Right_Split)
	opener_order_expect(t, &s.openers, {"mid", "alpha", "zed"})
}

@(test)
openers_diagnose_each_bad_line_and_skip_incomplete_programs :: proc(t: ^testing.T) {
	fixture :: `opener.nvim.name = Neovim
opener.nvim.command = nvim %1
opener.bad = x
opener.ABC.name = X
opener.nvim.args = x
opener.nvim.offers = some
opener.nvim.placement = left
opener.nvim.name =
opener.nvim.command = ""
opener.nvim.name = "Neovim"
opener.order = nvim, BAD, nvim
opener.nameless.command = code %1
opener.commandless.name = Commandless
`
	s, diagnostics, err := settings.parse(fixture)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&diagnostics)
	testing.expect_value(t, err, nil)
	expected := [?]struct {
		line: int,
		kind: settings.Diagnostic_Kind,
	} {
		{3, .Unknown_Key},
		{4, .Unknown_Key},
		{5, .Unknown_Key},
		{6, .Invalid_Value},
		{7, .Invalid_Value},
		{8, .Invalid_Value},
		{9, .Invalid_Value},
		{10, .Duplicate_Key},
		{11, .Invalid_Value},
		{11, .Duplicate_Key},
		{12, .Invalid_Value},
		{13, .Invalid_Value},
	}
	if !testing.expect_value(t, len(diagnostics), len(expected)) {return}
	for want, i in expected {
		testing.expectf(
			t,
			diagnostics[i].line == want.line && diagnostics[i].kind == want.kind,
			"diagnostic %d: %v",
			i,
			diagnostics[i],
		)
	}
	testing.expect_value(t, diagnostics[11].key, "opener.commandless")
	testing.expect(t, strings.contains(diagnostics[10].message, "has no name"))
	testing.expect(t, strings.contains(diagnostics[11].message, "has no command line"))
	testing.expect_value(t, len(s.openers.items), 1)
	nvim := settings.opener_find(&s.openers, "nvim")
	if !testing.expect(t, nvim != nil) {return}
	testing.expect_value(t, nvim.name, "Neovim")
	testing.expect_value(t, nvim.command, "nvim %1")
	testing.expect_value(t, nvim.offers, settings.Opener_Offers.Files_And_Folders)
	testing.expect_value(t, nvim.placement, settings.Opener_Placement.Right_Split)
	opener_order_expect(t, &s.openers, {"nvim"})
}

@(test)
openers_stop_at_the_limit :: proc(t: ^testing.T) {
	builder := strings.builder_make(context.temp_allocator)
	for i in 0 ..= settings.OPENER_LIMIT {
		fmt.sbprintf(&builder, "opener.p%d.name = P%d\nopener.p%d.command = p%d.exe\n", i, i, i, i)
	}
	s, diagnostics, err := settings.parse(strings.to_string(builder))
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&diagnostics)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(s.openers.items), settings.OPENER_LIMIT)
	testing.expect_value(t, len(diagnostics), 2)
	for d in diagnostics {
		testing.expect_value(t, d.message, "too many link programs; the limit is 32")
	}
	testing.expect(t, settings.opener_find(&s.openers, fmt.tprintf("p%d", settings.OPENER_LIMIT)) == nil)
}

@(test)
editing_an_opener_field_writes_its_key :: proc(t: ^testing.T) {
	source :: "# keep\nopener.nvim.name = Neovim\nopener.nvim.command = nvim %1\n"
	command, command_message, command_error := settings.edit_text(
		source, settings.opener_field_key("nvim", .Command), "nvim -R %1",
	)
	defer delete(command)
	defer delete(command_message)
	testing.expect_value(t, command_error, nil)
	testing.expect_value(t, command_message, "")
	testing.expect_value(
		t,
		command,
		"# keep\nopener.nvim.name = Neovim\nopener.nvim.command = \"nvim -R %1\"\n",
	)
	offers, offers_message, offers_error := settings.edit_text(
		command, settings.opener_field_key("nvim", .Offers), "folders",
	)
	defer delete(offers)
	defer delete(offers_message)
	testing.expect_value(t, offers_error, nil)
	testing.expect(t, strings.has_suffix(offers, "opener.nvim.offers = folders\n"))
	s := mutation_parse(t, offers)
	defer settings.destroy(&s)
	nvim := settings.opener_find(&s.openers, "nvim")
	if testing.expect(t, nvim != nil) {
		testing.expect_value(t, nvim.command, "nvim -R %1")
		testing.expect_value(t, nvim.offers, settings.Opener_Offers.Folders)
	}
	for refused in ([?]struct {
		field:          settings.Opener_Field,
		value, message: string,
	} {
		{.Placement, "left", "Expected right, down, float, tab, linked or window."},
		{.Offers, "all", "Expected both, files or folders."},
		{.Name, "  ", "A link program needs a name."},
		{.Command, "", "A link program needs a command line."},
	}) {
		updated, message, error := settings.edit_text(
			source, settings.opener_field_key("nvim", refused.field), refused.value,
		)
		defer delete(updated)
		defer delete(message)
		testing.expect_value(t, error, nil)
		testing.expect_value(t, updated, "")
		testing.expect_value(t, message, refused.message)
	}
}

@(test)
opener_mutation_adds_with_defaults_and_a_fresh_id :: proc(t: ^testing.T) {
	// program-1 has lines but no name, so parsing dropped it; Add must not inherit its offers.
	source :: "opener.nvim.name = Neovim\nopener.nvim.command = nvim %1\nopener.program-1.offers = folders\n"
	s := opener_parse(t, source)
	defer settings.destroy(&s)
	text, id, issue, error := settings.opener_mutate(source, &s.openers, {kind = .Add})
	defer delete(text)
	defer delete(id)
	defer delete(issue)
	if !testing.expect_value(t, error, settings.Mutation_Error.None) {return}
	testing.expect_value(t, id, "program-2")
	after := opener_parse(t, text)
	defer settings.destroy(&after)
	added := settings.opener_find(&after.openers, id)
	if !testing.expect(t, added != nil) {return}
	testing.expect_value(t, added.name, settings.OPENER_NEW_NAME)
	testing.expect_value(t, added.command, settings.OPENER_NEW_COMMAND)
	testing.expect_value(t, added.offers, settings.Opener_Offers.Files)
	testing.expect_value(t, added.placement, settings.Opener_Placement.Own_Window)
	opener_order_expect(t, &after.openers, {"nvim", "program-2"})
}

@(test)
opener_mutation_removes_lines_and_order_entry :: proc(t: ^testing.T) {
	source :: "\xef\xbb\xbf# keep\r\nopener.code.name = Code\r\nopener.code.command = code %1\r\n" +
		"opener.nvim.name = Neovim\r\nopener.nvim.command = nvim %1\r\nopener.order = code, nvim\r\n"
	s := mutation_parse(t, source)
	defer settings.destroy(&s)
	text, id, issue, error := settings.opener_mutate(source, &s.openers, {kind = .Remove, id = "code"})
	defer delete(text)
	defer delete(id)
	defer delete(issue)
	testing.expect_value(t, error, settings.Mutation_Error.None)
	testing.expect_value(t, id, "code")
	testing.expect(t, !strings.contains(text, "opener.code."))
	testing.expect(t, strings.has_prefix(text, "\xef\xbb\xbf# keep\r\nopener.nvim.name = Neovim\r\n"))
	after := mutation_parse(t, text)
	defer settings.destroy(&after)
	testing.expect(t, settings.opener_find(&after.openers, "code") == nil)
	opener_order_expect(t, &after.openers, {"nvim"})
}

@(test)
opener_mutation_moves_in_display_order :: proc(t: ^testing.T) {
	source :: "opener.a.name = A\nopener.a.command = a\nopener.b.name = B\nopener.b.command = b\n" +
		"opener.c.name = C\nopener.c.command = c\n"
	s := mutation_parse(t, source)
	defer settings.destroy(&s)
	for change in ([?]struct {
		id:    string,
		slot:  int,
		order: []string,
	} {
		{"c", 0, {"c", "a", "b"}},
		{"a", 2, {"b", "a", "c"}},
		{"a", 99, {"b", "c", "a"}},
	}) {
		text, id, issue, error := settings.opener_mutate(
			source, &s.openers, {kind = .Move, id = change.id, slot = change.slot},
		)
		defer delete(text)
		defer delete(id)
		defer delete(issue)
		testing.expect_value(t, error, settings.Mutation_Error.None)
		after := mutation_parse(t, text)
		defer settings.destroy(&after)
		opener_order_expect(t, &after.openers, change.order)
	}
}

@(test)
opener_mutation_refuses_missing_programs_and_the_limit :: proc(t: ^testing.T) {
	s := mutation_parse(t, "")
	defer settings.destroy(&s)
	for kind in ([?]settings.Opener_Mutation_Kind{.Remove, .Move}) {
		text, id, issue, error := settings.opener_mutate("", &s.openers, {kind = kind, id = "missing"})
		defer delete(text)
		defer delete(id)
		defer delete(issue)
		testing.expect_value(t, error, settings.Mutation_Error.Unavailable)
		testing.expect_value(t, text, "")
	}
	builder := strings.builder_make(context.temp_allocator)
	for i in 0 ..< settings.OPENER_LIMIT {
		fmt.sbprintf(&builder, "opener.p%d.name = P\nopener.p%d.command = p\n", i, i)
	}
	full := mutation_parse(t, strings.to_string(builder))
	defer settings.destroy(&full)
	text, id, issue, error := settings.opener_mutate(strings.to_string(builder), &full.openers, {kind = .Add})
	defer delete(text)
	defer delete(id)
	defer delete(issue)
	testing.expect_value(t, error, settings.Mutation_Error.Limit)
	testing.expect_value(t, text, "")
}

@(test)
opener_command_line_substitutes_and_quotes_the_path :: proc(t: ^testing.T) {
	plain :: `C:\src\main.odin`
	spaced :: `C:\My Files\notes.txt`
	for case_ in ([?]struct {
		command, path, line: string,
	} {
		{"nvim %1", plain, `nvim C:\src\main.odin`},
		{"nvim %1", spaced, `nvim "C:\My Files\notes.txt"`},
		{`code "%1"`, spaced, `code "C:\My Files\notes.txt"`},
		{`code --goto "%1:1"`, spaced, `code --goto "C:\My Files\notes.txt:1"`},
		{"diff %1 %1", spaced, `diff "C:\My Files\notes.txt" "C:\My Files\notes.txt"`},
		{"cmd /c echo 100%% %1", plain, `cmd /c echo 100% C:\src\main.odin`},
		{"notepad.exe", plain, `notepad.exe C:\src\main.odin`},
		{"notepad.exe", spaced, `notepad.exe "C:\My Files\notes.txt"`},
		{"explorer %1", `C:\My Folder\`, `explorer "C:\My Folder\\"`},
		{`nvim "%1"`, `C:\src\`, `nvim "C:\src\\"`},
		{"nvim %1", `C:\src\`, `nvim C:\src\`},
		{"tool %2 50%", plain, `tool %2 50% C:\src\main.odin`},
	}) {
		line, err := settings.opener_command_line(case_.command, case_.path)
		defer delete(line)
		testing.expect_value(t, err, nil)
		testing.expectf(t, line == case_.line, "%s on %s: got %s, want %s", case_.command, case_.path, line, case_.line)
	}
}

@(test)
generated_settings_describe_link_programs_without_shipping_one :: proc(t: ^testing.T) {
	text, text_error := settings.default_text()
	defer delete(text)
	testing.expect_value(t, text_error, nil)
	testing.expect(t, strings.contains(text, "# opener.nvim.name = \"Neovim\"\n"))
	testing.expect(t, strings.contains(text, "# opener.nvim.command = \"nvim %1\"\n"))
	testing.expect(t, strings.contains(text, "# opener.nvim.placement = right\n"))
	s := mutation_parse(t, text)
	defer settings.destroy(&s)
	testing.expect_value(t, len(s.openers.items), 0)
}

// Parses `source` expecting only the diagnostic an incomplete program earns.
@(private = "file")
opener_parse :: proc(t: ^testing.T, source: string) -> settings.Settings {
	s, diagnostics, error := settings.parse(source)
	defer settings.diagnostics_destroy(&diagnostics)
	testing.expect_value(t, error, nil)
	for d in diagnostics {testing.expect(t, strings.contains(d.message, "has no name"))}
	return s
}

@(private = "file")
opener_order_expect :: proc(t: ^testing.T, openers: ^settings.Openers, expected: []string) {
	indices: [settings.OPENER_LIMIT]int
	count := settings.openers_in_order(openers, indices[:])
	if !testing.expect_value(t, count, len(expected)) {return}
	for id, i in expected {testing.expect_value(t, openers.items[indices[i]].id, id)}
}
