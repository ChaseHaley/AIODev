package settings_test

import "aio:settings"
import "core:fmt"
import "core:strings"
import "core:testing"

@(private)
quick_labels_parse :: proc(t: ^testing.T, value: string) -> (labels: string, diagnostics: int) {
	s, issues, err := settings.parse(fmt.tprintf("%s = %s", settings.QUICK_LABELS_KEY, value))
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&issues)
	testing.expect_value(t, err, nil)
	return strings.clone(s.turns.quick_labels, context.temp_allocator), len(issues)
}

@(test)
quick_labels_cursor_yields_the_seven_defaults_in_order :: proc(t: ^testing.T) {
	Expected :: struct {
		name, colour, instruction: string,
	}
	expected := [?]Expected {
		{"Clarify this", "blue", "Explain what this does and why you chose it. Don't change it yet."},
		{
			"Verify this",
			"yellow",
			"This looks like an assumption. Check it against the code or by running it, and say what you found.",
		},
		{
			"Match existing patterns",
			"teal",
			"Find how the codebase already does this and reuse that instead of a new approach.",
		},
		{"Out of scope", "red", "This isn't part of the task. Revert it and stay on what was asked."},
		{
			"Ensure no regressions",
			"orange",
			"Work out what this could break and guard it, with a test where one fits.",
		},
		{
			"Consider alternatives",
			"violet",
			"Propose two or three other approaches with their trade-offs before keeping this one.",
		},
		{"Looks good", "green", "No change needed here. Leave it as it is."},
	}
	cursor := settings.quick_labels_scan(settings.QUICK_LABELS_DEFAULT)
	count := 0
	for label, more := settings.quick_labels_next(&cursor); more; label, more = settings.quick_labels_next(&cursor) {
		if !testing.expect(t, count < len(expected)) {return}
		testing.expect_value(t, label.name, expected[count].name)
		testing.expect_value(t, label.colour, expected[count].colour)
		testing.expect_value(t, label.instruction, expected[count].instruction)
		count += 1
	}
	testing.expect_value(t, count, len(expected))
	empty := settings.quick_labels_scan("  ")
	_, more := settings.quick_labels_next(&empty)
	testing.expect(t, !more)
}

@(test)
quick_labels_default_passes_its_own_validator_and_round_trips :: proc(t: ^testing.T) {
	entry := settings.schema_find(settings.QUICK_LABELS_KEY)
	if !testing.expect(t, entry != nil) {return}
	testing.expect_value(t, entry.default_value, settings.QUICK_LABELS_DEFAULT)
	testing.expect_value(t, entry.control, settings.Setting_Control.Group)
	testing.expect_value(t, settings.group_title(entry.key), "Agent changes")
	labels, diagnostics := quick_labels_parse(t, fmt.tprintf("\"%s\"", settings.QUICK_LABELS_DEFAULT))
	testing.expect_value(t, diagnostics, 0)
	testing.expect_value(t, labels, settings.QUICK_LABELS_DEFAULT)
	s, defaults_error := settings.defaults()
	testing.expect_value(t, defaults_error, nil)
	defer settings.destroy(&s)
	testing.expect_value(t, s.turns.quick_labels, settings.QUICK_LABELS_DEFAULT)

	drafts := make([dynamic]settings.Quick_Label_Draft, context.temp_allocator)
	cursor := settings.quick_labels_scan(settings.QUICK_LABELS_DEFAULT)
	for label, more := settings.quick_labels_next(&cursor); more; label, more = settings.quick_labels_next(&cursor) {
		append(&drafts, settings.Quick_Label_Draft{label.name, label.colour, label.instruction})
	}
	text, problem, err := settings.quick_labels_text(drafts[:], context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect(t, problem == nil)
	testing.expect_value(t, text, settings.QUICK_LABELS_DEFAULT)
}

@(test)
quick_labels_grammar_accepts_presets_hex_and_an_optional_instruction :: proc(t: ^testing.T) {
	for value in ([?]string {
			"Clarify | blue",
			"Clarify|blue|Explain it",
			"A  |  #2ea043 | do it ;B|gray",
			"A | orange | one; B | violet | two; C | teal",
			"",
			"A | #AABBCC",
		}) {
		labels, diagnostics := quick_labels_parse(t, value)
		testing.expectf(t, diagnostics == 0, "%q should be accepted", value)
		testing.expect_value(t, labels, value)
	}
	labels, _ := quick_labels_parse(t, "A | blue | Don't, \"quote\" it")
	testing.expect_value(t, labels, "A | blue | Don't, \"quote\" it")
}

@(test)
quick_labels_grammar_refuses_malformed_entries_and_keeps_the_default :: proc(t: ^testing.T) {
	for value in ([?]string {
			"Clarify",
			"Clarify | purple",
			"Clarify | Blue",
			"Clarify | #12345",
			"Clarify | #gggggg",
			"Clarify | 2ea043",
			"| blue | nameless",
			"  | blue",
			"A | blue | x | y",
			"A | blue;",
			"A | blue;; B | red",
			";A | blue",
			"A | | text",
		}) {
		labels, diagnostics := quick_labels_parse(t, value)
		testing.expectf(t, diagnostics == 1, "%q should be refused", value)
		testing.expect_value(t, labels, settings.QUICK_LABELS_DEFAULT)
	}
}

@(test)
quick_labels_grammar_limits_the_value_length :: proc(t: ^testing.T) {
	entry := settings.schema_find(settings.QUICK_LABELS_KEY)
	testing.expect_value(t, int(entry.valid.maximum), settings.QUICK_LABELS_MAX)
	long := strings.repeat("A | blue; ", 900, context.temp_allocator)
	_, diagnostics := quick_labels_parse(t, long[:len(long) - 2])
	testing.expect_value(t, diagnostics, 1)
}

@(test)
quick_labels_description_and_error_text_show_the_grammar :: proc(t: ^testing.T) {
	entry := settings.schema_find(settings.QUICK_LABELS_KEY)
	testing.expect(t, strings.contains(entry.description, settings.QUICK_LABELS_EXAMPLE))
	testing.expect(t, strings.contains(entry.description, "Alt+1 to Alt+9"))
	testing.expect(t, strings.contains(entry.description, "instruction"))
	s, issues, err := settings.parse(settings.QUICK_LABELS_KEY + " = broken")
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&issues)
	testing.expect_value(t, err, nil)
	if testing.expect_value(t, len(issues), 1) {
		testing.expect(t, strings.contains(issues[0].message, settings.QUICK_LABELS_EXAMPLE))
		testing.expect(t, strings.contains(issues[0].message, "color"))
		for preset in settings.QUICK_LABEL_PRESETS {
			testing.expect(t, strings.contains(issues[0].message, preset), preset)
		}
	}
}

@(test)
quick_labels_text_encodes_what_the_parser_reads_and_names_the_first_refused_field :: proc(t: ^testing.T) {
	labels := [?]settings.Quick_Label_Draft {
		{name = " Clarify ", colour = " blue ", instruction = " Explain it "},
		{name = "Plain", colour = "#2ea043", instruction = "  "},
	}
	text, problem, err := settings.quick_labels_text(labels[:], context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect(t, problem == nil)
	testing.expect_value(t, text, "Clarify | blue | Explain it; Plain | #2ea043")
	parsed, diagnostics := quick_labels_parse(t, text)
	testing.expect_value(t, diagnostics, 0)
	testing.expect_value(t, parsed, text)

	Case :: struct {
		label:   settings.Quick_Label_Draft,
		problem: settings.Quick_Label_Problem,
	}
	for c in ([?]Case {
			{{name = "a;b", colour = "blue"}, .Name},
			{{name = "a|b", colour = "blue"}, .Name},
			{{name = " ", colour = "blue"}, .Name},
			{{name = "a\nb", colour = "blue"}, .Name},
			{{name = "a\x00b", colour = "blue"}, .Name},
			{{name = "a", colour = "mauve"}, .Colour},
			{{name = "a", colour = ""}, .Colour},
			{{name = "a", colour = "blue", instruction = "x;y"}, .Instruction},
			{{name = "a", colour = "blue", instruction = "x|y"}, .Instruction},
			{{name = "a", colour = "blue", instruction = "x\ry"}, .Instruction},
			{{name = "a", colour = "blue", instruction = "x\ny"}, .Instruction},
			// The first refused field wins: the name before the colour before the instruction.
			{{name = "", colour = "mauve", instruction = "x;y"}, .Name},
			{{name = "a", colour = "mauve", instruction = "x;y"}, .Colour},
		}) {
		drafts := []settings.Quick_Label_Draft{{"fine", "red", ""}, c.label}
		refused, refusal, refused_error := settings.quick_labels_text(drafts, context.temp_allocator)
		testing.expect_value(t, refused_error, nil)
		testing.expect_value(t, refused, "")
		got, has_problem := refusal.?
		testing.expectf(t, has_problem && got == c.problem, "%q", c.label.name)
	}

	huge := strings.repeat("x", 600, context.temp_allocator)
	many := make([dynamic]settings.Quick_Label_Draft, context.temp_allocator)
	for _ in 0 ..< 20 {append(&many, settings.Quick_Label_Draft{"name", "blue", huge})}
	refused, refusal, _ := settings.quick_labels_text(many[:], context.temp_allocator)
	testing.expect_value(t, refused, "")
	got, has_problem := refusal.?
	testing.expect(t, has_problem && got == .Too_Long)
}
