package control

import "aio:term"
import "core:fmt"

Attribute_Kind :: enum {
	Text,
	Color,
	Flag,
	Underline,
}

@(private)
Attribute_Accessor :: enum {
	Text,
	Foreground,
	Background,
	Underline,
	Underline_Color,
	Flag,
}

@(private)
Attribute_Flag :: enum {
	Bold,
	Italic,
	Faint,
	Blink,
	Inverse,
	Invisible,
	Strike,
	Overline,
	Selected,
	Wide,
}

Attribute :: struct {
	name:     string,
	kind:     Attribute_Kind,
	accessor: Attribute_Accessor,
	flag:     Attribute_Flag,
}

// Catalogue position is each attribute's placement: emission and help use this order.
// `text` is the cell content, not an emitted attribute.
ATTRIBUTE_CATALOGUE :: [?]Attribute {
	{name = "text", kind = .Text, accessor = .Text},
	{name = "fg", kind = .Color, accessor = .Foreground},
	{name = "bg", kind = .Color, accessor = .Background},
	{name = "bold", kind = .Flag, accessor = .Flag, flag = .Bold},
	{name = "italic", kind = .Flag, accessor = .Flag, flag = .Italic},
	{name = "faint", kind = .Flag, accessor = .Flag, flag = .Faint},
	{name = "blink", kind = .Flag, accessor = .Flag, flag = .Blink},
	{name = "inverse", kind = .Flag, accessor = .Flag, flag = .Inverse},
	{name = "invisible", kind = .Flag, accessor = .Flag, flag = .Invisible},
	{name = "strike", kind = .Flag, accessor = .Flag, flag = .Strike},
	{name = "overline", kind = .Flag, accessor = .Flag, flag = .Overline},
	{name = "underline", kind = .Underline, accessor = .Underline},
	{name = "underline-color", kind = .Color, accessor = .Underline_Color},
	{name = "selected", kind = .Flag, accessor = .Flag, flag = .Selected},
	{name = "wide", kind = .Flag, accessor = .Flag, flag = .Wide},
}

UNDERLINES :: [?]string{"none", "single", "double", "curly", "dotted", "dashed"}

@(private)
Attributes :: struct {
	fg, bg, underline_color: Maybe(term.Color),
	flags:                   bit_set[Attribute_Flag],
	underline:               i32,
}

@(private, require_results)
attribute_entry :: proc(name: string) -> (Attribute, bool) {
	for entry in ATTRIBUTE_CATALOGUE {
		if entry.name == name {return entry, true}
	}
	return {}, false
}

@(private, require_results)
color_text :: proc(c: Maybe(term.Color), buffer: []u8) -> string {
	if rgb, ok := c.?; ok {return fmt.bprintf(buffer, "#%02x%02x%02x", rgb[0], rgb[1], rgb[2])}
	return "default"
}

@(private, require_results)
attribute_value :: proc(entry: Attribute, a: Attributes, buffer: []u8) -> (string, bool) {
	@(static, rodata)
	underlines := UNDERLINES
	switch entry.accessor {
	case .Text:
		return "", false
	case .Foreground:
		return color_text(a.fg, buffer), a.fg != nil
	case .Background:
		return color_text(a.bg, buffer), a.bg != nil
	case .Underline_Color:
		return color_text(a.underline_color, buffer), a.underline_color != nil
	case .Underline:
		if a.underline >= 0 && int(a.underline) < len(underlines) {
			return underlines[a.underline], a.underline > 0
		}
		return "unknown", false
	case .Flag:
		set := entry.flag in a.flags
		return set ? "true" : "false", set
	}
	return "", false
}

@(private, require_results)
underline_index :: proc(name: string) -> int {
	for value, i in UNDERLINES {
		if value == name {return i}
	}
	return -1
}

@(private, require_results)
valid_color :: proc(value: string) -> bool {
	if value == "default" {return true}
	if len(value) != 7 || value[0] != '#' {return false}
	for c in value[1:] {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F') {
			return false
		}
	}
	return true
}

@(private, require_results)
valid_attribute :: proc(s: string) -> bool {
	key, value, ok := assignment(s)
	if !ok {return false}
	entry, found := attribute_entry(key)
	if !found {return false}
	switch entry.kind {
	case .Text:
		return true
	case .Color:
		return valid_color(value)
	case .Flag:
		return value == "true" || value == "false"
	case .Underline:
		return underline_index(value) >= 0
	}
	return false
}

@(private, require_results)
observed_attribute :: proc(
	c: ^term.Snapshot_Cell,
	a: Attributes,
	key: string,
	buffer: []u8,
) -> (
	value: string,
	kind: Attribute_Kind,
	found: bool,
) {
	entry, ok := attribute_entry(key)
	if !ok {return "", .Text, false}
	if entry.kind == .Text {return c.text, .Text, true}
	value, _ = attribute_value(entry, a, buffer)
	return value, entry.kind, true
}
