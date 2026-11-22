package settings

import "cosmos:colour"
import "base:runtime"
import "core:fmt"
import "core:strings"

QUICK_LABELS_KEY :: "turns.quick_labels"

// The documented shape of a quick-labels value. The settings description and the diagnostic for a
// malformed value both show it, so a grammar change updates the example with the parser.
QUICK_LABELS_EXAMPLE :: "Clarify this | blue | Explain it first; Looks good | #2ea043"

QUICK_LABELS_MAX :: 8192

// The named colours a label can take. Each follows the theme; the interface resolves it. The order
// is the one Add label walks through, so new labels differ from their neighbours.
QUICK_LABEL_PRESETS :: [?]string{"blue", "yellow", "orange", "teal", "red", "violet", "green", "gray"}

// The labels a fresh settings file starts with and Reset labels returns to. Their instructions are
// what the agent reads with the label, so they are written as direct requests.
QUICK_LABELS_DEFAULT ::
	"Clarify this | blue | Explain what this does and why you chose it. Don't change it yet.; " +
	"Verify this | yellow | This looks like an assumption. Check it against the code or by running it, " +
	"and say what you found.; " +
	"Match existing patterns | teal | Find how the codebase already does this and reuse that instead of " +
	"a new approach.; " +
	"Out of scope | red | This isn't part of the task. Revert it and stay on what was asked.; " +
	"Ensure no regressions | orange | Work out what this could break and guard it, with a test where one " +
	"fits.; " +
	"Consider alternatives | violet | Propose two or three other approaches with their trade-offs before " +
	"keeping this one.; " +
	"Looks good | green | No change needed here. Leave it as it is."

// `;` ends a label and `|` ends a field, and a line break ends the setting, so no edited field can
// hold any of them.
@(private)
QUICK_LABEL_FORBIDDEN :: ";|\r\n\x00"

// One `name | colour | instruction` entry, as slices of the value. The instruction may be empty.
Quick_Label :: struct {
	name, colour, instruction: string,
}

// A cursor over the `;`-separated labels. A blank value has no labels; anywhere else an empty item
// is malformed, which makes a trailing or doubled separator follow the same rule as an empty name.
Quick_Labels_Cursor :: struct {
	rest: string,
	done: bool,
}

@(require_results)
quick_labels_scan :: proc(value: string) -> Quick_Labels_Cursor {
	if strings.trim_space(value) == "" {return {done = true}}
	return {rest = value}
}

// Yields every entry in order. A setting value is checked when it is loaded, so the entries a running
// program reads are well formed.
@(require_results)
quick_labels_next :: proc(c: ^Quick_Labels_Cursor) -> (label: Quick_Label, ok: bool) {
	label, _, ok = quick_labels_step(c)
	return
}

@(private, require_results)
quick_labels_step :: proc(c: ^Quick_Labels_Cursor) -> (label: Quick_Label, valid, more: bool) {
	if c.done {return {}, false, false}
	text := c.rest
	if end := strings.index_byte(text, ';'); end >= 0 {
		c.rest = text[end + 1:]
		text = text[:end]
	} else {
		c.done = true
	}
	label, valid = quick_label_parse(text)
	return label, valid, true
}

@(private, require_results)
quick_label_parse :: proc(text: string) -> (label: Quick_Label, valid: bool) {
	first := strings.index_byte(text, '|')
	if first < 0 {return {name = strings.trim_space(text)}, false}
	label.name = strings.trim_space(text[:first])
	rest := text[first + 1:]
	if second := strings.index_byte(rest, '|'); second >= 0 {
		label.colour = strings.trim_space(rest[:second])
		label.instruction = strings.trim_space(rest[second + 1:])
	} else {
		label.colour = strings.trim_space(rest)
	}
	valid =
		quick_label_name_valid(label.name) &&
		quick_label_colour_valid(label.colour) &&
		quick_label_instruction_valid(label.instruction)
	return
}

@(private, require_results)
quick_label_name_valid :: proc(name: string) -> bool {
	return name != "" && !strings.contains_any(name, QUICK_LABEL_FORBIDDEN)
}

@(private, require_results)
quick_label_colour_valid :: proc(text: string) -> bool {
	for preset in QUICK_LABEL_PRESETS {
		if text == preset {return true}
	}
	_, ok, _ := colour.parse(text, .Strict)
	return ok
}

@(private, require_results)
quick_label_instruction_valid :: proc(text: string) -> bool {
	return !strings.contains_any(text, QUICK_LABEL_FORBIDDEN)
}

// What an edited label cannot store, reported for the first label that has one: its name, then its
// colour, then its instruction.
Quick_Label_Problem :: enum u8 {
	Name,
	Colour,
	Instruction,
	Too_Long,
}

// One edited label; each field is the raw text typed for it.
Quick_Label_Draft :: struct {
	name, colour, instruction: string,
}

// Encodes edited labels in the grammar quick_labels_next reads back, or reports the first field of
// the first label it cannot store; a refused draft encodes nothing.
@(require_results)
quick_labels_text :: proc(
	labels: []Quick_Label_Draft,
	allocator := context.allocator,
) -> (
	text: string,
	problem: Maybe(Quick_Label_Problem),
	err: runtime.Allocator_Error,
) {
	for label in labels {
		if problem = quick_label_check(label); problem != nil {return}
	}
	builder := strings.builder_make(allocator) or_return
	for label, index in labels {
		if index > 0 {strings.write_string(&builder, "; ")}
		fmt.sbprintf(&builder, "%s | %s", strings.trim_space(label.name), strings.trim_space(label.colour))
		if instruction := strings.trim_space(label.instruction); instruction != "" {
			fmt.sbprintf(&builder, " | %s", instruction)
		}
	}
	if strings.builder_len(builder) > QUICK_LABELS_MAX {
		strings.builder_destroy(&builder)
		return "", Quick_Label_Problem.Too_Long, nil
	}
	return strings.to_string(builder), nil, nil
}

@(private, require_results)
quick_label_check :: proc(label: Quick_Label_Draft) -> Maybe(Quick_Label_Problem) {
	if !quick_label_name_valid(strings.trim_space(label.name)) {return Quick_Label_Problem.Name}
	if !quick_label_colour_valid(strings.trim_space(label.colour)) {return Quick_Label_Problem.Colour}
	if !quick_label_instruction_valid(strings.trim_space(label.instruction)) {
		return Quick_Label_Problem.Instruction
	}
	return nil
}

@(private, require_results)
quick_labels_valid :: proc(value: string) -> bool {
	cursor := quick_labels_scan(value)
	for {
		_, valid, more := quick_labels_step(&cursor)
		if !more {break}
		if !valid {return false}
	}
	return true
}

// Built from the parser's own limits and example, so the diagnostic cannot describe a grammar the
// parser does not accept.
@(private, require_results)
quick_labels_rules :: proc(buffer: []u8) -> string {
	names: [96]u8
	list := strings.builder_from_bytes(names[:])
	for preset, i in QUICK_LABEL_PRESETS {
		if i > 0 {strings.write_string(&list, ", ")}
		strings.write_string(&list, preset)
	}
	return fmt.bprintf(
		buffer,
		"Each label is name | color | instruction; the color is a preset (%s) or #rrggbb and the " +
		"instruction is optional. Fields cannot use ; or |. A value looks like %s.",
		strings.to_string(list),
		QUICK_LABELS_EXAMPLE,
	)
}
