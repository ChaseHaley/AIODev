package settings

import "base:runtime"
import "core:fmt"
import "core:strings"

SAVED_COMMAND_PREFIX :: "saved_command."
SAVED_COMMAND_ORDER_KEY :: "saved_command.order"
// Saved command IDs follow the profile ID rules.
SAVED_COMMAND_ID_MAX_LENGTH :: PROFILE_ID_MAX_LENGTH
SAVED_COMMAND_LIMIT :: 64
#assert(SAVED_COMMAND_LIMIT <= ORDER_LIMIT)

// Where a saved command is offered (D-092): panes in its folder or a folder below it, panes of its
// profile, or every pane.
Saved_Command_Level :: enum u8 {
	Folder,
	Profile,
	Everywhere,
}

// The fields of one saved command, each a saved_command.ID.<name> key.
Saved_Command_Field :: enum {
	Name,
	Command,
	Level,
	Folder,
	Profile,
}

@(rodata)
saved_command_field_names := [Saved_Command_Field]string {
	.Name    = "name",
	.Command = "command",
	.Level   = "level",
	.Folder  = "folder",
	.Profile = "profile",
}

@(rodata)
saved_command_level_names := [Saved_Command_Level]string {
	.Folder     = "folder",
	.Profile    = "profile",
	.Everywhere = "everywhere",
}

// A command line saved to run in a new shell or to type into a pane. A folder command runs in its
// folder with the profile it was saved from, empty meaning the default profile; a profile command
// runs with its profile. The name may be empty, and then the command line stands for it. `set`
// records the fields the file supplied; `line` is the first line that named the command.
Saved_Command :: struct {
	id, name, command, folder, profile: string,
	level:                              Saved_Command_Level,
	set:                                bit_set[Saved_Command_Field],
	line:                               int,
}

Saved_Commands :: struct {
	items:      [dynamic]Saved_Command,
	order:      [dynamic]string,
	order_line: int,
	allocator:  runtime.Allocator,
}

saved_commands_init :: proc(c: ^Saved_Commands, allocator: runtime.Allocator) {
	c.allocator = allocator
	c.items.allocator = allocator
	c.order.allocator = allocator
}

saved_commands_destroy :: proc(c: ^Saved_Commands) {
	for &command in c.items {saved_command_destroy(&command, c.allocator)}
	delete(c.items)
	for id in c.order {delete(id, c.allocator)}
	delete(c.order)
	c^ = {}
}

@(private)
saved_command_destroy :: proc(command: ^Saved_Command, allocator: runtime.Allocator) {
	delete(command.id, allocator)
	delete(command.name, allocator)
	delete(command.command, allocator)
	delete(command.folder, allocator)
	delete(command.profile, allocator)
}

saved_command_find :: proc(c: ^Saved_Commands, id: string) -> ^Saved_Command {
	for &command in c.items {
		if command.id == id {return &command}
	}
	return nil
}

// Fills `out` with indices into c.items in saved order: saved_command.order first, then unlisted IDs
// sorted by ID. Returns the number written; `out` must hold SAVED_COMMAND_LIMIT entries.
saved_commands_in_order :: proc(c: ^Saved_Commands, out: []int) -> int {
	return items_in_order(c.items[:], c.order[:], out, nil)
}

// "saved_command.ID.field". Temporary.
saved_command_field_key :: proc(id: string, field: Saved_Command_Field) -> string {
	return fmt.tprintf("%s%s.%s", SAVED_COMMAND_PREFIX, id, saved_command_field_names[field])
}

saved_command_level_name :: proc(level: Saved_Command_Level) -> string {
	return saved_command_level_names[level]
}

saved_command_level_from_name :: proc(name: string) -> (Saved_Command_Level, bool) {
	for candidate, level in saved_command_level_names {
		if candidate == name {return level, true}
	}
	return {}, false
}

@(private)
saved_command_field_from_name :: proc(name: string) -> (Saved_Command_Field, bool) {
	for candidate, field in saved_command_field_names {
		if candidate == name {return field, true}
	}
	return {}, false
}

// Whether a pane in `directory` is in `folder` or a folder below it. Windows paths compare without
// regard to case or to which slash separates them; a trailing separator on either is ignored.
saved_command_folder_contains :: proc(folder, directory: string) -> bool {
	trim :: proc(path: string) -> string {
		end := len(path)
		for end > 1 && (path[end - 1] == '\\' || path[end - 1] == '/') && !(end == 3 && path[1] == ':') {
			end -= 1
		}
		return path[:end]
	}
	same :: proc(a, b: u8) -> bool {
		slash :: proc(c: u8) -> bool {return c == '\\' || c == '/'}
		if slash(a) || slash(b) {return slash(a) && slash(b)}
		lower :: proc(c: u8) -> u8 {return c >= 'A' && c <= 'Z' ? c + 32 : c}
		return lower(a) == lower(b)
	}
	root, path := trim(folder), trim(directory)
	if root == "" || len(path) < len(root) {return false}
	for i in 0 ..< len(root) {
		if !same(root[i], path[i]) {return false}
	}
	if len(path) == len(root) {return true}
	last := root[len(root) - 1]
	return last == '\\' || last == '/' || path[len(root)] == '\\' || path[len(root)] == '/'
}

// Appends a command with an owned ID. `nil` means the limit was reached.
@(private, require_results)
saved_commands_add :: proc(
	c: ^Saved_Commands,
	id: string,
	line: int,
) -> (
	^Saved_Command,
	runtime.Allocator_Error,
) {
	if found := saved_command_find(c, id); found != nil {return found, nil}
	if len(c.items) >= SAVED_COMMAND_LIMIT {return nil, nil}
	owned, clone_error := strings.clone(id, c.allocator)
	if clone_error != nil {return nil, clone_error}
	if _, append_error := append(&c.items, Saved_Command{id = owned, line = line}); append_error != nil {
		delete(owned, c.allocator)
		return nil, append_error
	}
	return &c.items[len(c.items) - 1], nil
}

@(private)
SAVED_COMMAND_KEY_SHAPE ::
	"saved_command.ID.name, saved_command.ID.command, saved_command.ID.level, saved_command.ID.folder, " +
	"saved_command.ID.profile or saved_command.order"

// Checks one field value. The file accepts one pair of double quotes around text, which `text`
// drops; edits pass `quoted` false. The command line and folder must not be empty, the level must be
// one of its names and the profile a profile ID. Only the name may be empty.
@(private)
saved_command_field_check :: proc(
	field: Saved_Command_Field,
	value: string,
	quoted: bool,
) -> (
	text, issue: string,
) {
	switch field {
	case .Level:
		if _, known := saved_command_level_from_name(value); !known {
			return "", fmt.tprintf("invalid level \"%s\", expected folder, profile or everywhere", value)
		}
		return value, ""
	case .Profile:
		if !id_valid(value, PROFILE_ID_MAX_LENGTH) {return "", "invalid profile ID"}
		return value, ""
	case .Name, .Command, .Folder:
	}
	text = value
	if quoted {
		text, issue = text_value_decode(value)
		if issue != "" {return "", issue}
	} else if !text_valid(value) {
		return "", "expected UTF-8 text without NUL bytes"
	}
	if field != .Name && strings.trim_space(text) == "" {
		return "", field == .Command ? "a saved command needs a command line" : "a folder command needs a folder"
	}
	return text, ""
}

// Parses one saved_command.* line. Invalid lines produce diagnostics and never stop startup.
@(require_results)
parse_saved_command_key :: proc(
	s: ^Settings,
	diagnostics: ^[dynamic]Diagnostic,
	key, value: string,
	line: int,
) -> runtime.Allocator_Error {
	c := &s.saved_commands
	if key == SAVED_COMMAND_ORDER_KEY {
		return parse_order(&c.order, &c.order_line, c.allocator, key, "saved command", value, line, diagnostics)
	}
	id, field_name, shaped := item_key_split(key, SAVED_COMMAND_PREFIX)
	if !shaped {
		return diagnostic_append(diagnostics, line, key, "expected " + SAVED_COMMAND_KEY_SHAPE, .Unknown_Key)
	}
	if !id_valid(id, SAVED_COMMAND_ID_MAX_LENGTH) {
		return diagnostic_append(
			diagnostics,
			line,
			key,
			"invalid saved command ID; use lowercase letters, digits, - and _",
			.Unknown_Key,
		)
	}
	field, known := saved_command_field_from_name(field_name)
	if !known {
		message := fmt.tprintf(
			"unknown saved command field \"%s\"; expected name, command, level, folder or profile",
			field_name,
		)
		return diagnostic_append(diagnostics, line, key, message, .Unknown_Key)
	}
	command := saved_commands_add(c, id, line) or_return
	if command == nil {
		return diagnostic_append(
			diagnostics,
			line,
			key,
			limit_message("saved commands", SAVED_COMMAND_LIMIT),
			.Invalid_Value,
		)
	}
	text, issue := saved_command_field_check(field, value, true)
	if issue != "" {return diagnostic_append(diagnostics, line, key, issue)}
	if field in command.set {
		duplicate_key_diagnostic(diagnostics, key, line) or_return
	}
	switch field {
	case .Name:
		profile_own(&command.name, text, c.allocator) or_return
	case .Command:
		profile_own(&command.command, text, c.allocator) or_return
	case .Level:
		command.level, _ = saved_command_level_from_name(text)
	case .Folder:
		profile_own(&command.folder, text, c.allocator) or_return
	case .Profile:
		profile_own(&command.profile, text, c.allocator) or_return
	}
	command.set += {field}
	return nil
}

// Drops every command the file left without a command line or a level, a folder command without
// a folder and a profile command without a profile, diagnosing each at the line that first named it.
// Called once per parse, after every line was read.
@(private, require_results)
saved_commands_finalize :: proc(
	c: ^Saved_Commands,
	diagnostics: ^[dynamic]Diagnostic,
) -> runtime.Allocator_Error {
	for index := 0; index < len(c.items); {
		command := &c.items[index]
		missing := ""
		if .Command not_in command.set {
			missing = "command line"
		} else if .Level not_in command.set {
			missing = "level"
		} else if command.level == .Folder && .Folder not_in command.set {
			missing = "folder"
		} else if command.level == .Profile && .Profile not_in command.set {
			missing = "profile"
		}
		if missing == "" {
			index += 1
			continue
		}
		message := fmt.tprintf("saved command \"%s\" has no %s; it is not offered", command.id, missing)
		key := fmt.tprintf("%s%s", SAVED_COMMAND_PREFIX, command.id)
		diagnostic_append(diagnostics, command.line, key, message) or_return
		saved_command_destroy(command, c.allocator)
		ordered_remove(&c.items, index)
	}
	return nil
}

// Serializes one saved command line for edit_text. The returned text is temporary.
saved_command_edit_text :: proc(key, value: string) -> (serialized, issue: string) {
	if key == SAVED_COMMAND_ORDER_KEY {
		if !order_text_valid(value) {
			return "", "Use comma-separated saved command IDs, each lowercase with digits, - or _."
		}
		return value, ""
	}
	id, field_name, shaped := item_key_split(key, SAVED_COMMAND_PREFIX)
	if !shaped {return "", "Expected " + SAVED_COMMAND_KEY_SHAPE + "."}
	if !id_valid(id, SAVED_COMMAND_ID_MAX_LENGTH) {
		return "", "Invalid saved command ID. Use lowercase letters, digits, - and _."
	}
	field, known := saved_command_field_from_name(field_name)
	if !known {return "", "Unknown saved command field. Expected name, command, level, folder or profile."}
	text, field_issue := saved_command_field_check(field, value, false)
	if field_issue != "" {return "", field_issue}
	if field == .Level || field == .Profile {return text, ""}
	return edit_quoted(value)
}

Saved_Command_Mutation_Kind :: enum {
	Add,
	Edit,
	Remove,
}

// Add ignores `id`; Edit replaces every field of `id` with these; Remove takes only `id`. The
// folder applies to a folder command, the profile to a folder or profile command.
Saved_Command_Mutation :: struct {
	kind:                          Saved_Command_Mutation_Kind,
	id, name, command:             string,
	level:                         Saved_Command_Level,
	folder, profile:               string,
}

// The revision of `source` with `change` made, resolved against `commands`, the commands `source`
// parses to. All returned strings are owned; failures return no revision.
@(require_results)
saved_command_mutate :: proc(
	source: string,
	commands: ^Saved_Commands,
	change: Saved_Command_Mutation,
	allocator := context.allocator,
) -> (
	updated, id, issue: string,
	error: Mutation_Error,
) {
	if change.kind != .Add && saved_command_find(commands, change.id) == nil {return "", "", "", .Unavailable}
	if change.kind == .Add && len(commands.items) >= SAVED_COMMAND_LIMIT {return "", "", "", .Limit}
	target := change.id
	if change.kind == .Add {
		// A command the file names without a command line was dropped from `commands`, yet its lines
		// remain; a new command never inherits them.
		for number := 1; ; number += 1 {
			target = fmt.tprintf("command-%d", number)
			if saved_command_find(commands, target) == nil &&
			   !item_text_has(source, SAVED_COMMAND_PREFIX, target) {break}
		}
	}
	revision: string
	alloc_error: runtime.Allocator_Error
	if change.kind == .Add {
		revision, alloc_error = strings.clone(source, allocator)
	} else {
		// Edit rewrites every field, so the fields the new level does not use go with the old lines.
		revision, alloc_error = remove_item_text(source, SAVED_COMMAND_PREFIX, target, allocator)
	}
	if alloc_error != nil {return "", "", "", .Allocation}
	defer delete(revision, allocator)
	if change.kind != .Remove {
		values := [Saved_Command_Field]string {
			.Name    = strings.trim_space(change.name),
			.Command = change.command,
			.Level   = saved_command_level_names[change.level],
			.Folder  = change.level == .Folder ? change.folder : "",
			.Profile = change.level != .Everywhere ? change.profile : "",
		}
		for value, field in values {
			if value == "" {continue}
			if issue, error = mutation_edit(&revision, saved_command_field_key(target, field), value, allocator);
			   error != .None {return "", "", issue, error}
		}
	}
	indices: [SAVED_COMMAND_LIMIT]int
	ordered: [SAVED_COMMAND_LIMIT + 1]string
	written := 0
	for index in indices[:saved_commands_in_order(commands, indices[:])] {
		item := &commands.items[index]
		if change.kind == .Remove && item.id == target {continue}
		ordered[written] = item.id
		written += 1
	}
	if change.kind == .Add {
		ordered[written] = target
		written += 1
	}
	if written == 0 {
		// Removing the last command leaves no order to keep, and an empty one is not an edit.
		emptied, empty_error := remove_key_text(revision, SAVED_COMMAND_ORDER_KEY, allocator)
		if empty_error != nil {return "", "", "", .Allocation}
		delete(revision, allocator)
		revision = emptied
	} else {
		order_value, order_error := order_text(ordered[:written], nil, allocator)
		defer delete(order_value, allocator)
		if order_error != nil {return "", "", "", .Allocation}
		if issue, error = mutation_edit(&revision, SAVED_COMMAND_ORDER_KEY, order_value, allocator);
		   error != .None {return "", "", issue, error}
	}
	id, alloc_error = strings.clone(target, allocator)
	if alloc_error != nil {return "", "", "", .Allocation}
	updated, revision = revision, ""
	return
}
