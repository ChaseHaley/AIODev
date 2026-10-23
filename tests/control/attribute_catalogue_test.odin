package control_test

import "aio:control"
import "aio:term"
import "core:fmt"
import "core:strings"
import "core:testing"

catalogue_names :: proc(kinds: bit_set[control.Attribute_Kind], separator: string) -> string {
	names: [dynamic]string
	defer delete(names)
	for entry in control.ATTRIBUTE_CATALOGUE {
		if entry.kind in kinds {
			append(&names, entry.name)
		}
	}
	joined, _ := strings.join(names[:], separator)
	return joined
}

underline_names :: proc(include_none: bool, separator: string) -> string {
	names: [dynamic]string
	defer delete(names)
	for name, i in control.UNDERLINES {
		if i == 0 && !include_none {continue}
		append(&names, name)
	}
	joined, _ := strings.join(names[:], separator)
	return joined
}

@(test)
catalogue_validates_emits_and_compares :: proc(t: ^testing.T) {
	s, ok := source(t,
		"\x1b[1;2;3;5;7;8;9;53m\x1b[4:3m" +
		"\x1b[38;2;255;0;0;48;2;0;0;200;58:2::1:2:3m漢",
		2, 1, selected = true)
	if !ok {return}
	defer term.snapshot_destroy(&s)
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	testing.expect_value(t, control.format_cells(&b, &s, {0, {}}), control.Error.None)
	output := strings.to_string(b)
	testing.expect_value(t, output,
		"row 0 cols 0-1\n" +
		"0-1 \"漢\" fg=#ff0000 bg=#0000c8 bold italic faint blink inverse invisible strike " +
		"overline underline=curly underline-color=#010203 selected wide\n")

	quote := strings.index(output, "\" ")
	testing.expect(t, quote >= 0)
	if quote < 0 {return}
	tokens := strings.fields(output[quote + 2:])
	defer delete(tokens)
	index := 0
	out := strings.builder_make()
	defer strings.builder_destroy(&out)
	item_buffer: [128]u8
	for entry in control.ATTRIBUTE_CATALOGUE {
		if entry.kind == .Text {continue}
		if !testing.expectf(t, index < len(tokens), "%s: no emitted token", entry.name) {
			return
		}
		token := tokens[index]
		index += 1
		item := token
		if entry.kind == .Flag {
			testing.expect_value(t, token, entry.name)
			item = fmt.bprintf(item_buffer[:], "%s=true", entry.name)
		} else {
			separator := strings.index_byte(token, '=')
			if !testing.expectf(t, separator > 0, "%s: malformed token %s", entry.name, token) {
				return
			}
			testing.expect_value(t, token[:separator], entry.name)
			if entry.kind == .Color {
				upper := strings.to_upper(token[separator + 1:])
				item = fmt.bprintf(item_buffer[:], "%s=%s", entry.name, upper)
				delete(upper)
			}
		}
		r, err := control.parse({"expect", "cell", "0,0", item})
		if testing.expectf(t, err.advice == "", "%s: %s", item, err.advice) {
			strings.builder_reset(&out)
			passed, failure := control.evaluate(&out, r.(control.Expect), &s)
			testing.expect_value(t, failure, control.Error.None)
			testing.expectf(t, passed, "%s did not match its emitted value", item)
		}
		control.request_destroy(&r)
	}
	testing.expect_value(t, index, len(tokens))

	r, err := control.parse({"expect", "cell", "0,0", "text=漢"})
	defer control.request_destroy(&r)
	testing.expect_value(t, err.advice, "")
	if err.advice == "" {
		strings.builder_reset(&out)
		passed, failure := control.evaluate(&out, r.(control.Expect), &s)
		testing.expect_value(t, failure, control.Error.None)
		testing.expect(t, passed)
	}
}

@(test)
catalogue_rejects_kind_specific_bad_values :: proc(t: ^testing.T) {
	buffer: [128]u8
	for entry in control.ATTRIBUTE_CATALOGUE {
		value: string
		switch entry.kind {
		case .Text:
			continue
		case .Color:
			value = "#000"
		case .Flag:
			value = "yes"
		case .Underline:
			value = "bad"
		}
		item := fmt.bprintf(buffer[:], "%s=%s", entry.name, value)
		r, err := control.parse({"expect", "cell", "0,0", item})
		testing.expectf(t, err.advice != "", "%s accepted", item)
		control.request_destroy(&r)
	}
	for name in control.UNDERLINES {
		item := fmt.bprintf(buffer[:], "underline=%s", name)
		r, err := control.parse({"expect", "cell", "0,0", item})
		testing.expectf(t, err.advice == "", "%s rejected", item)
		control.request_destroy(&r)
	}
	r, err := control.parse({"expect", "cell", "0,0", "text="})
	testing.expect_value(t, err.advice, "")
	control.request_destroy(&r)
}

@(test)
help_lists_the_catalogue_vocabulary :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	testing.expect_value(t, control.help(&b, "cells"), control.Error.None)
	cells := strings.to_string(b)
	prefix := "Attributes, in order: "
	end := ". Only nondefaults appear"
	start := strings.index(cells, prefix)
	stop := strings.index(cells, end)
	testing.expect(t, start >= 0 && stop > start)
	all_names := catalogue_names({.Color, .Flag, .Underline}, ", ")
	defer delete(all_names)
	if start >= 0 && stop > start {
		listed, _ := strings.replace_all(cells[start + len(prefix):stop], "\n", " ")
		testing.expect_value(t, listed, all_names)
		delete(listed)
	}
	testing.expect(t, strings.contains(cells, "overline,\nunderline, "))
	underline_values := underline_names(false, ", ")
	defer delete(underline_values)
	underline_line := fmt.aprintf("Underline values: %s. Default trailing blanks:", underline_values)
	defer delete(underline_line)
	testing.expect(t, strings.contains(cells, underline_line))

	strings.builder_reset(&b)
	testing.expect_value(t, control.help(&b, "expect"), control.Error.None)
	expect := strings.to_string(b)
	text_name := catalogue_names({.Text}, "")
	defer delete(text_name)
	color_names := catalogue_names({.Color}, "/")
	defer delete(color_names)
	underline_name := catalogue_names({.Underline}, "")
	defer delete(underline_name)
	all_underline_values := underline_names(true, "|")
	defer delete(all_underline_values)
	flag_names := catalogue_names({.Flag}, ", ")
	defer delete(flag_names)
	expected := fmt.aprintf(
		"Cell attributes: %s=<s>, %s=default|#rrggbb,\n%s=%s, and true|false for\n%s.\n",
		text_name, color_names, underline_name, all_underline_values, flag_names)
	defer delete(expected)
	testing.expect(t, strings.contains(expect, expected))
}
