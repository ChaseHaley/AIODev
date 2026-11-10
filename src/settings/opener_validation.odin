package settings

import "core:fmt"
import "core:strings"

// The fields of one link program, each an opener.ID.<name> key.
Opener_Field :: enum {
	Name,
	Command,
	Offers,
	Placement,
}

@(rodata)
opener_field_names := [Opener_Field]string {
	.Name      = "name",
	.Command   = "command",
	.Offers    = "offers",
	.Placement = "placement",
}

// The file values of Opener_Offers, and how Settings shows them.
OPENER_OFFERS_NAME :: [Opener_Offers]string {
	.Files_And_Folders = "both",
	.Files             = "files",
	.Folders           = "folders",
}
OPENER_OFFERS_LABEL :: [Opener_Offers]string {
	.Files_And_Folders = "Files and folders",
	.Files             = "Files",
	.Folders           = "Folders",
}

// The file values of Opener_Placement, and how Settings shows them.
OPENER_PLACEMENT_NAME :: [Opener_Placement]string {
	.Right_Split   = "right",
	.Down_Split    = "down",
	.Float         = "float",
	.Tab           = "tab",
	.Linked_Window = "linked",
	.Own_Window    = "window",
}
OPENER_PLACEMENT_LABEL :: [Opener_Placement]string {
	.Right_Split   = "Right Split",
	.Down_Split    = "Down Split",
	.Float         = "Float",
	.Tab           = "New Tab",
	.Linked_Window = "Linked Window",
	.Own_Window    = "Own Window",
}

opener_field_from_name :: proc(name: string) -> (Opener_Field, bool) {
	for candidate, field in opener_field_names {
		if candidate == name {return field, true}
	}
	return {}, false
}

// "opener.ID.field". Temporary.
opener_field_key :: proc(id: string, field: Opener_Field) -> string {
	return fmt.tprintf("%s%s.%s", OPENER_PREFIX, id, opener_field_names[field])
}

opener_offers_from_name :: proc(name: string) -> (Opener_Offers, bool) {
	for candidate, offers in OPENER_OFFERS_NAME {
		if candidate == name {return offers, true}
	}
	return {}, false
}

opener_placement_from_name :: proc(name: string) -> (Opener_Placement, bool) {
	for candidate, placement in OPENER_PLACEMENT_NAME {
		if candidate == name {return placement, true}
	}
	return {}, false
}

// The surface that checks a link program value: the file accepts one pair of quotes around text
// and reports lowercase diagnostics; Settings fields and edits use sentences.
Opener_Validation_Context :: enum {
	File,
	Interactive_Field,
}

Opener_Problem :: enum {
	None,
	Invalid_Text,
	Empty_Name,
	Empty_Command,
	Invalid_Offers,
	Invalid_Placement,
}

// Checks one field value. A File name or command may carry one pair of double quotes, which `text`
// drops; otherwise `text` is `value`. Offers and placement must be exactly one of their names.
opener_field_check :: proc(
	field: Opener_Field,
	value: string,
	ctx: Opener_Validation_Context,
) -> (
	text: string,
	issue: Opener_Problem,
) {
	switch field {
	case .Offers:
		if _, known := opener_offers_from_name(value); !known {return "", .Invalid_Offers}
		return value, .None
	case .Placement:
		if _, known := opener_placement_from_name(value); !known {return "", .Invalid_Placement}
		return value, .None
	case .Name, .Command:
	}
	text = value
	if ctx == .File {
		decode_issue: string
		text, decode_issue = text_value_decode(value)
		if decode_issue != "" {return "", .Invalid_Text}
	} else if !text_valid(value) {
		return "", .Invalid_Text
	}
	if strings.trim_space(text) == "" {return "", field == .Name ? .Empty_Name : .Empty_Command}
	return text, .None
}

// The message for `issue` on `ctx`'s surface; `value` is the value that was checked. Temporary.
opener_problem_text :: proc(issue: Opener_Problem, ctx: Opener_Validation_Context, value: string) -> string {
	file := ctx == .File
	switch issue {
	case .None:
	case .Invalid_Text:
		if file {
			_, decode_issue := text_value_decode(value)
			return decode_issue
		}
		return "Expected UTF-8 text without NUL bytes."
	case .Empty_Name:
		return file ? "link program name cannot be empty" : "A link program needs a name."
	case .Empty_Command:
		return file ? "link program command line cannot be empty" : "A link program needs a command line."
	case .Invalid_Offers:
		if !file {return "Expected both, files or folders."}
		return fmt.tprintf("invalid offers \"%s\", expected both, files or folders", value)
	case .Invalid_Placement:
		if !file {return "Expected right, down, float, tab, linked or window."}
		return fmt.tprintf(
			"invalid placement \"%s\", expected right, down, float, tab, linked or window",
			value,
		)
	}
	return ""
}
