package settings

import "base:runtime"
import "core:strings"

OPENER_PREFIX :: "opener."
OPENER_ORDER_KEY :: "opener.order"
// Link program IDs follow the profile ID rules.
OPENER_ID_MAX_LENGTH :: PROFILE_ID_MAX_LENGTH
// Link menus offer at most this many programs.
OPENER_LIMIT :: 32
#assert(OPENER_LIMIT <= ORDER_LIMIT)

// The kinds of link a program can be offered for.
Opener_Link :: enum u8 {
	Files,
	Folders,
}

// Which links a program is offered for; never empty.
Opener_Offers :: bit_set[Opener_Link;u8]
OPENER_OFFERS_ALL :: Opener_Offers{.Files, .Folders}

// Where a program opens.
Opener_Placement :: enum u8 {
	Right_Split,
	Down_Split,
	Float,
	Tab,
	Linked_Window,
	Own_Window,
}

// A link program: a command line a link menu offers for opening the link's file or folder. Only
// programs with a name and a command line survive parsing. `set` records the fields the file
// supplied; `line` is the first line that named the program, where diagnostics about it point.
Opener :: struct {
	id, name, command: string,
	offers:            Opener_Offers,
	placement:         Opener_Placement,
	set:               bit_set[Opener_Field],
	line:              int,
}

Openers :: struct {
	items:      [dynamic]Opener,
	order:      [dynamic]string,
	order_line: int,
	allocator:  runtime.Allocator,
}

openers_init :: proc(o: ^Openers, allocator: runtime.Allocator) {
	o.allocator = allocator
	o.items.allocator = allocator
	o.order.allocator = allocator
}

openers_destroy :: proc(o: ^Openers) {
	for &opener in o.items {opener_destroy(&opener, o.allocator)}
	delete(o.items)
	for id in o.order {delete(id, o.allocator)}
	delete(o.order)
	o^ = {}
}

@(private)
opener_destroy :: proc(opener: ^Opener, allocator: runtime.Allocator) {
	delete(opener.id, allocator)
	delete(opener.name, allocator)
	delete(opener.command, allocator)
}

opener_find :: proc(o: ^Openers, id: string) -> ^Opener {
	for &opener in o.items {
		if opener.id == id {return &opener}
	}
	return nil
}

// Fills `out` with indices into o.items in display order: opener.order first, then unlisted IDs
// sorted by ID. Returns the number written; `out` must hold at least len(o.items) entries, which
// OPENER_LIMIT bounds.
openers_in_order :: proc(o: ^Openers, out: []int) -> int {
	return items_in_order(o.items[:], o.order[:], out, nil)
}

// Splits "opener.ID.field"; `opener.order` is handled before this is called.
opener_key_split :: proc(key: string) -> (id, field: string, shaped: bool) {
	return item_key_split(key, OPENER_PREFIX)
}

// Appends a program with an owned ID. `nil` means the limit was reached.
@(private, require_results)
openers_add :: proc(o: ^Openers, id: string, line: int) -> (^Opener, runtime.Allocator_Error) {
	if found := opener_find(o, id); found != nil {return found, nil}
	if len(o.items) >= OPENER_LIMIT {return nil, nil}
	owned, clone_error := strings.clone(id, o.allocator)
	if clone_error != nil {return nil, clone_error}
	if _, append_error := append(&o.items, Opener{id = owned, offers = OPENER_OFFERS_ALL, line = line});
	   append_error != nil {
		delete(owned, o.allocator)
		return nil, append_error
	}
	return &o.items[len(o.items) - 1], nil
}

// Parses one opener.* line. Invalid lines produce diagnostics and never stop startup.
@(require_results)
parse_opener_key :: proc(
	s: ^Settings,
	diagnostics: ^[dynamic]Diagnostic,
	key, value: string,
	line: int,
) -> runtime.Allocator_Error {
	o := &s.openers
	if key == OPENER_ORDER_KEY {
		return parse_order(&o.order, &o.order_line, o.allocator, key, "link program", value, line, diagnostics)
	}
	id, field_name, shaped := opener_key_split(key)
	if !shaped {
		return diagnostic_append(
			diagnostics,
			line,
			key,
			"expected opener.ID.name, opener.ID.command, opener.ID.offers, opener.ID.placement " +
			"or opener.order",
			.Unknown_Key,
		)
	}
	if !id_valid(id, OPENER_ID_MAX_LENGTH) {
		return diagnostic_append(
			diagnostics,
			line,
			key,
			"invalid link program ID; use lowercase letters, digits, - and _",
			.Unknown_Key,
		)
	}
	field, known := opener_field_from_name(field_name)
	if !known {
		message, message_error := strings.concatenate(
			{"unknown link program field \"", field_name, "\"; expected name, command, offers or placement"},
			context.temp_allocator,
		)
		if message_error != nil {
			message = "unknown link program field; expected name, command, offers or placement"
		}
		return diagnostic_append(diagnostics, line, key, message, .Unknown_Key)
	}
	opener := openers_add(o, id, line) or_return
	if opener == nil {
		return diagnostic_append(
			diagnostics,
			line,
			key,
			limit_message("link programs", OPENER_LIMIT),
			.Invalid_Value,
		)
	}
	text, issue := opener_field_check(field, value, .File)
	if issue != .None {
		return diagnostic_append(diagnostics, line, key, opener_problem_text(issue, .File, value))
	}
	if field in opener.set {
		duplicate_key_diagnostic(diagnostics, key, line) or_return
	}
	switch field {
	case .Name:
		profile_own(&opener.name, text, o.allocator) or_return
	case .Command:
		profile_own(&opener.command, text, o.allocator) or_return
	case .Offers:
		opener.offers, _ = opener_offers_parse(text)
	case .Placement:
		opener.placement, _ = opener_placement_from_name(text)
	}
	opener.set += {field}
	return nil
}

// Drops every program the file left without a name or a command line, diagnosing each at the line
// that first named it. Called once per parse, after every line was read.
@(private, require_results)
openers_finalize :: proc(o: ^Openers, diagnostics: ^[dynamic]Diagnostic) -> runtime.Allocator_Error {
	for index := 0; index < len(o.items); {
		opener := &o.items[index]
		missing := ""
		if .Name not_in opener.set {
			missing = "name"
		} else if .Command not_in opener.set {
			missing = "command line"
		}
		if missing == "" {
			index += 1
			continue
		}
		message, message_error := strings.concatenate(
			{"link program \"", opener.id, "\" has no ", missing, "; it is not offered"},
			context.temp_allocator,
		)
		if message_error != nil {message = "link program has no name or command line; it is not offered"}
		key, key_error := strings.concatenate({OPENER_PREFIX, opener.id}, context.temp_allocator)
		if key_error != nil {return key_error}
		diagnostic_append(diagnostics, opener.line, key, message) or_return
		opener_destroy(opener, o.allocator)
		ordered_remove(&o.items, index)
	}
	return nil
}

// Serializes one link program row from the settings editor. The returned text is temporary and
// is consumed immediately by edit_text.
opener_edit_text :: proc(key, value: string) -> (serialized, issue: string) {
	if key == OPENER_ORDER_KEY {
		if !order_text_valid(value) {
			return "", "Use comma-separated link program IDs, each lowercase with digits, - or _."
		}
		return value, ""
	}
	id, field_name, shaped := opener_key_split(key)
	if !shaped {
		return "", "Expected opener.ID.name, opener.ID.command, opener.ID.offers, " +
			"opener.ID.placement or opener.order."
	}
	if !id_valid(id, OPENER_ID_MAX_LENGTH) {
		return "", "Invalid link program ID. Use lowercase letters, digits, - and _."
	}
	field, known := opener_field_from_name(field_name)
	if !known {
		return "", "Unknown link program field. Expected name, command, offers or placement."
	}
	text, field_issue := opener_field_check(field, value, .Interactive_Field)
	if field_issue != .None {return "", opener_problem_text(field_issue, .Interactive_Field, value)}
	if field == .Offers || field == .Placement {return text, ""}
	return edit_quoted(value)
}

// The command line that runs `command` on `path`. Each %1 becomes the path, wrapped in double
// quotes when the path has whitespace and the %1 is not already inside quotes; %% becomes %; a
// command without %1 runs as if it ended in " %1". Windows paths cannot contain '"', so the path
// needs no escaping except backslashes that end it right before a quote, which are doubled so the
// quote still closes the argument (a folder such as C:\My Folder\).
@(require_results)
opener_command_line :: proc(
	command, path: string,
	allocator := context.allocator,
) -> (
	line: string,
	err: runtime.Allocator_Error,
) {
	builder := strings.builder_make(allocator) or_return
	defer strings.builder_destroy(&builder)
	quoted, substituted := false, false
	for i := 0; i < len(command); i += 1 {
		if command[i] == '%' && i + 1 < len(command) {
			switch command[i + 1] {
			case '%':
				write_parts(&builder, "%") or_return
				i += 1
				continue
			case '1':
				quote_follows := quoted && i + 2 < len(command) && command[i + 2] == '"'
				opener_path_write(&builder, path, quoted, quote_follows) or_return
				substituted = true
				i += 1
				continue
			}
		}
		if command[i] == '"' {quoted = !quoted}
		write_parts(&builder, command[i:i + 1]) or_return
	}
	if !substituted {
		write_parts(&builder, " ") or_return
		opener_path_write(&builder, path, false, false) or_return
	}
	return strings.clone(strings.to_string(builder), allocator)
}

// Writes `path` as one argument; outside quotes, an empty path or one with whitespace is wrapped
// in them.
@(private, require_results)
opener_path_write :: proc(
	b: ^strings.Builder,
	path: string,
	inside_quotes, quote_follows: bool,
) -> runtime.Allocator_Error {
	wrap := !inside_quotes && (path == "" || strings.contains_any(path, " \t"))
	if wrap {write_parts(b, "\"") or_return}
	write_parts(b, path) or_return
	if wrap || quote_follows {
		// A run of backslashes before a quote escapes it unless doubled.
		trailing := len(path) - len(strings.trim_right(path, "\\"))
		write_parts(b, path[len(path) - trailing:]) or_return
	}
	if wrap {write_parts(b, "\"") or_return}
	return nil
}
