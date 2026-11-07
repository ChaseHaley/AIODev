package settings

import "base:runtime"
import "core:fmt"
import "core:strings"

PROFILE_PREFIX :: "profile."
PROFILE_ORDER_KEY :: "profile.order"
PROFILE_DEFAULT_ID :: "default"
DEFAULT_PROFILE_COMMAND :: "pwsh.exe -NoLogo"
DEFAULT_PROFILE_DIRECTORY :: "~"
PROFILE_ID_MAX_LENGTH :: 32
PROFILE_LIMIT :: 64

// One named shell. Fields are the effective values after profiles_finalize; `set` records the
// fields the file or detection supplied, so a later finalize can inherit the rest.
// detection_id preserves discovery identity when the built-in default represents a machine shell.
Profile :: struct {
	id, name, command, directory, icon: string,
	detection_id:                     string,
	hidden, detected, builtin:         bool,
	set:                               bit_set[Profile_Field],
}

Profiles :: struct {
	items:      [dynamic]Profile,
	order:      [dynamic]string,
	default_id: string,
	order_line: int,
	allocator:  runtime.Allocator,
}

profiles_init :: proc(p: ^Profiles, allocator: runtime.Allocator) {
	p.allocator = allocator
	p.items.allocator = allocator
	p.order.allocator = allocator
}

profiles_destroy :: proc(p: ^Profiles) {
	for &profile in p.items {profile_destroy(&profile, p.allocator)}
	delete(p.items)
	for id in p.order {delete(id, p.allocator)}
	delete(p.order)
	delete(p.default_id, p.allocator)
	p^ = {}
}

// Frees one profile's owned strings, for list teardown and removal alike.
@(private)
profile_destroy :: proc(profile: ^Profile, allocator: runtime.Allocator) {
	for field in ([?]string {
		profile.id,
		profile.name,
		profile.command,
		profile.directory,
		profile.icon,
		profile.detection_id,
	}) {delete(field, allocator)}
}

// The string a text field stores; nil for Hidden, which is a flag.
@(private)
profile_text :: proc(profile: ^Profile, field: Profile_Field) -> ^string {
	switch field {
	case .Name:
		return &profile.name
	case .Command:
		return &profile.command
	case .Directory:
		return &profile.directory
	case .Icon:
		return &profile.icon
	case .Hidden:
	}
	return nil
}

profile_find :: proc(p: ^Profiles, id: string) -> ^Profile {
	for &profile in p.items {
		if profile.id == id {return &profile}
	}
	return nil
}

// Appends a profile with an owned ID. `nil` means the limit was reached.
@(require_results)
profiles_add :: proc(p: ^Profiles, id: string) -> (^Profile, runtime.Allocator_Error) {
	if found := profile_find(p, id); found != nil {return found, nil}
	if len(p.items) >= PROFILE_LIMIT {return nil, nil}
	owned, err := strings.clone(id, p.allocator)
	if err != nil {return nil, err}
	if _, append_error := append(&p.items, Profile{id = owned}); append_error != nil {
		delete(owned, p.allocator)
		return nil, append_error
	}
	return &p.items[len(p.items) - 1], nil
}

// Splits "profile.ID.field"; `profile.order` is handled before this is called.
profile_key_split :: proc(key: string) -> (id, field: string, shaped: bool) {
	if !strings.has_prefix(key, PROFILE_PREFIX) {return "", "", false}
	rest := key[len(PROFILE_PREFIX):]
	dot := strings.last_index_byte(rest, '.')
	if dot <= 0 || dot + 1 >= len(rest) {return "", "", false}
	return rest[:dot], rest[dot + 1:], true
}

// The three pre-profile shell keys, in migration order. They stay accepted so a file whose
// migration cannot be written still launches; the file format otherwise uses profile.default.*.
Legacy_Shell_Field :: enum {
	Command,
	Directory,
	Icon,
}

// The file rules of each legacy key. Only the icon may be empty.
@(private, rodata)
legacy_shell_entries := [Legacy_Shell_Field]Schema_Entry {
	.Command = {
		key = "shell.command",
		kind = .String,
		default_value = DEFAULT_PROFILE_COMMAND,
		valid = {1, 32767},
	},
	.Directory = {
		key = "shell.directory",
		kind = .String,
		default_value = DEFAULT_PROFILE_DIRECTORY,
		valid = {1, 32767},
	},
	.Icon = {key = "shell.icon", kind = .String, valid = {0, 32767}},
}

// The profile.default field each legacy key became.
@(private, rodata)
legacy_shell_profile_fields := [Legacy_Shell_Field]Profile_Field {
	.Command   = .Command,
	.Directory = .Directory,
	.Icon      = .Icon,
}

// The legacy values one parse read, borrowed from its text; nil where the key was absent.
@(private)
Legacy_Shell_Input :: [Legacy_Shell_Field]Maybe(string)

legacy_shell_field :: proc(key: string) -> (Legacy_Shell_Field, bool) {
	for entry, field in legacy_shell_entries {
		if entry.key == key {return field, true}
	}
	return {}, false
}

@(private, require_results)
profile_own :: proc(
	target: ^string,
	value: string,
	allocator: runtime.Allocator,
) -> runtime.Allocator_Error {
	if target^ == value {return nil}
	copy, err := strings.clone(value, allocator)
	if err != nil {return err}
	delete(target^, allocator)
	target^ = copy
	return nil
}

// One entry of a profile.order value: trimmed, possibly empty. `repeated` means an earlier entry
// has the same text.
@(private)
Order_Token :: struct {
	id:              string,
	valid, repeated: bool,
}

// Steps through the comma-separated entries of a profile.order value without allocating; `offset`
// starts at 0. Every entry, empty ones included, is returned so each caller applies its own policy.
@(private)
order_token_next :: proc(text: string, offset: ^int) -> (token: Order_Token, ok: bool) {
	start := offset^
	if start > len(text) {return {}, false}
	end := strings.index_byte(text[start:], ',')
	end = end < 0 ? len(text) : start + end
	offset^ = end + 1
	token.id = strings.trim_space(text[start:end])
	token.valid = id_valid(token.id, PROFILE_ID_MAX_LENGTH)
	for from := 0; from < start; {
		comma := from + strings.index_byte(text[from:], ',')
		token.repeated ||= strings.trim_space(text[from:comma]) == token.id
		from = comma + 1
	}
	return token, true
}

// File parsing diagnoses and drops malformed or repeated IDs and keeps the rest.
@(private, require_results)
parse_profile_order :: proc(
	p: ^Profiles,
	value: string,
	line: int,
	diagnostics: ^[dynamic]Diagnostic,
) -> runtime.Allocator_Error {
	if p.order_line > 0 {
		duplicate_key_diagnostic(diagnostics, PROFILE_ORDER_KEY, line) or_return
	}
	p.order_line = line
	for id in p.order {delete(id, p.allocator)}
	clear(&p.order)
	offset := 0
	for token in order_token_next(value, &offset) {
		if token.id == "" {continue}
		if !token.valid {
			diagnostic_append(
				diagnostics,
				line,
				PROFILE_ORDER_KEY,
				"invalid profile ID in order; use lowercase letters, digits, - and _",
			) or_return
			continue
		}
		if token.repeated {
			duplicate_key_diagnostic(diagnostics, PROFILE_ORDER_KEY, line) or_return
			continue
		}
		owned := strings.clone(token.id, p.allocator) or_return
		if _, append_error := append(&p.order, owned); append_error != nil {
			delete(owned, p.allocator)
			return append_error
		}
	}
	return nil
}

// Parses one profile.* line. Invalid lines produce diagnostics and never stop startup.
@(require_results)
parse_profile_key :: proc(
	s: ^Settings,
	diagnostics: ^[dynamic]Diagnostic,
	key, value: string,
	line: int,
) -> runtime.Allocator_Error {
	p := &s.profiles
	if key == PROFILE_ORDER_KEY {
		return parse_profile_order(p, value, line, diagnostics)
	}
	id, field_name, shaped := profile_key_split(key)
	if !shaped {
		return diagnostic_append(
			diagnostics,
			line,
			key,
			"expected profile.ID.name, profile.ID.command, profile.ID.directory, " +
			"profile.ID.icon, profile.ID.hidden or profile.order",
			.Unknown_Key,
		)
	}
	if !id_valid(id, PROFILE_ID_MAX_LENGTH) {
		return diagnostic_append(
			diagnostics,
			line,
			key,
			"invalid profile ID; use lowercase letters, digits, - and _",
			.Unknown_Key,
		)
	}
	field, known := profile_field_from_name(field_name)
	if !known {
		message, message_error := strings.concatenate(
			{"unknown profile field \"", field_name, "\"; expected name, command, ",
			 "directory, icon or hidden"},
			context.temp_allocator,
		)
		if message_error != nil {
			message = "unknown profile field; expected name, command, directory, icon or hidden"
		}
		return diagnostic_append(diagnostics, line, key, message, .Unknown_Key)
	}
	profile, add_error := profiles_add(p, id)
	if add_error != nil {return add_error}
	if profile == nil {
		return diagnostic_append(
			diagnostics,
			line,
			key,
			limit_message("profiles", PROFILE_LIMIT),
			.Invalid_Value,
		)
	}
	text, issue := profile_field_check(field, value, .File)
	if issue != .None {
		return diagnostic_append(diagnostics, line, key, profile_problem_text(issue, .File, value))
	}
	if field in profile.set {
		duplicate_key_diagnostic(diagnostics, key, line) or_return
	}
	switch field {
	case .Hidden:
		profile.hidden = text == "true"
	case .Directory:
		// An empty directory inherits the default one.
		if text == "" {return nil}
		profile_own(&profile.directory, text, p.allocator) or_return
	case .Name, .Command, .Icon:
		profile_own(profile_text(profile, field), text, p.allocator) or_return
	}
	profile.set += {field}
	return nil
}

@(private)
profile_name_from_command :: proc(command: string) -> string {
	if name := shell_definitions[shell_kind(command)].name; name != "" {return name}
	return shell_executable(command)
}

// Applies the legacy shell keys to the reserved default profile wherever profile.default.* did not
// set that field. Called once per parse, before profiles_finalize derives the default's name.
@(private, require_results)
profiles_resolve_legacy :: proc(p: ^Profiles, legacy: Legacy_Shell_Input) -> runtime.Allocator_Error {
	base := profiles_add(p, PROFILE_DEFAULT_ID) or_return
	if base == nil {return .Out_Of_Memory}
	for value, legacy_field in legacy {
		text, seen := value.?
		field := legacy_shell_profile_fields[legacy_field]
		if !seen || field in base.set {continue}
		profile_own(profile_text(base, field), text, p.allocator) or_return
	}
	return nil
}

// Resolves inheritance. Safe to call again after detection adds profiles: fields the file or
// detection set are left alone, and the reserved default fills only a command or directory that is
// still empty.
@(require_results)
profiles_finalize :: proc(s: ^Settings) -> runtime.Allocator_Error {
	p := &s.profiles
	base := profiles_add(p, PROFILE_DEFAULT_ID) or_return
	if base == nil {return .Out_Of_Memory}
	if base.command == "" {
		profile_own(&base.command, DEFAULT_PROFILE_COMMAND, p.allocator) or_return
	}
	if base.directory == "" {
		profile_own(&base.directory, DEFAULT_PROFILE_DIRECTORY, p.allocator) or_return
	}
	if .Name not_in base.set {
		name := profile_name_from_command(base.command)
		if name == "" {name = PROFILE_DEFAULT_ID}
		profile_own(&base.name, name, p.allocator) or_return
	}
	for &profile in p.items {
		if profile.id == PROFILE_DEFAULT_ID {continue}
		if .Directory not_in profile.set {
			profile_own(&profile.directory, base.directory, p.allocator) or_return
		}
		if .Icon not_in profile.set {profile_own(&profile.icon, "", p.allocator) or_return}
		if .Name not_in profile.set {profile_own(&profile.name, profile.id, p.allocator) or_return}
	}
	default_id := s.shell.default_profile != "" ? s.shell.default_profile : PROFILE_DEFAULT_ID
	if err := profile_own(&p.default_id, default_id, p.allocator); err != nil {return err}
	return nil
}

// The reserved `default` profile: what the legacy shell keys configure and what other profiles
// inherit a starting directory from. Unlike profile_default it ignores shell.default_profile.
profile_base :: proc(p: ^Profiles) -> ^Profile {
	return profile_find(p, PROFILE_DEFAULT_ID)
}

profile_default :: proc(p: ^Profiles) -> ^Profile {
	if found := profile_find(p, p.default_id); found != nil {return found}
	return profile_base(p)
}

// Whether Settings may delete `profile`: never the reserved default or a machine profile.
profile_can_remove :: proc(profile: ^Profile) -> bool {
	return profile.id != PROFILE_DEFAULT_ID && !profile.builtin
}

// The profile a launch should use. An unknown or commandless ID falls back to the default
// profile; `requested` is false so a restart can prefer the session's recorded command line.
profile_resolve :: proc(s: ^Settings, id: string) -> (profile: ^Profile, requested: bool) {
	if id == "" {return profile_default(&s.profiles), true}
	if found := profile_find(&s.profiles, id); found != nil && found.command != "" {
		return found, true
	}
	return profile_default(&s.profiles), false
}

profile_visible :: proc(profile: ^Profile) -> bool {
	return !profile.hidden && profile.command != ""
}

// A profile found on this machine rather than written in settings.ini.
Detected_Profile :: struct {
	id, name, command, directory: string,
}

@(private)
profile_remove_at :: proc(p: ^Profiles, index: int) {
	if index < 0 || index >= len(p.items) {return}
	profile_destroy(&p.items[index], p.allocator)
	ordered_remove(&p.items, index)
}

// Detection is rebuilt from the machine on every load; entries the file owns stay.
profiles_begin_detection :: proc(p: ^Profiles) {
	for i := len(p.items) - 1; i >= 0; i -= 1 {
		if p.items[i].detected {profile_remove_at(p, i)}
	}
}

// Fills unset fields from a detected shell. File fields and hidden flags win.
@(require_results)
profile_detect :: proc(s: ^Settings, detected: Detected_Profile) -> runtime.Allocator_Error {
	p := &s.profiles
	profile := profile_find(p, detected.id)
	// The built-in default already represents this shell. Keep its stable ID rather than
	// adding a second machine profile; explicitly configured profiles keep their own identity.
	metadata_only := profile != nil && profile.id != PROFILE_DEFAULT_ID && profile.set <= {.Hidden}
	if profile == nil || metadata_only {
		default := profile_base(p)
		if default != nil && strings.equal_fold(
			strings.trim_space(default.command), strings.trim_space(detected.command),
		) {
			if err := profile_own(&default.detection_id, detected.id, p.allocator);
			   err != nil {return err}
			default.builtin = true
			if metadata_only {
				for item, index in p.items {
					if item.id == detected.id {profile_remove_at(p, index); break}
				}
			}
			return nil
		}
	}
	created := profile == nil
	if created {
		profile, _ = profiles_add(p, detected.id)
		if profile == nil {return nil}
	}
	if created {profile.detected = true}
	if err := profile_own(&profile.detection_id, detected.id, p.allocator); err != nil {return err}
	profile.builtin = true
	if .Name not_in profile.set {
		profile_own(&profile.name, detected.name, p.allocator) or_return
	}
	if .Command not_in profile.set {
		profile_own(&profile.command, detected.command, p.allocator) or_return
	}
	if .Directory not_in profile.set {
		profile_own(&profile.directory, detected.directory, p.allocator) or_return
	}
	profile.set += {.Name, .Command, .Directory}
	return nil
}

// Fills `out` with profile indices: explicit profile.order first, then unlisted IDs sorted by
// ID. Hidden and commandless profiles are skipped when `visible_only` is set.
// Returns the number written; `out` must hold at least len(p.items) entries.
profiles_in_order :: proc(p: ^Profiles, out: []int, visible_only := false) -> int {
	count := 0
	used: [PROFILE_LIMIT]bool
	for id in p.order {
		for &profile, index in p.items {
			if profile.id != id || used[index] {continue}
			used[index] = true
			if visible_only && !profile_visible(&profile) {continue}
			if count < len(out) {
				out[count] = index
				count += 1
			}
		}
	}
	pending: [PROFILE_LIMIT]int
	pending_count := 0
	for &profile, index in p.items {
		if used[index] {continue}
		if visible_only && !profile_visible(&profile) {continue}
		insert := pending_count
		for insert > 0 && text_less(profile.id, p.items[pending[insert - 1]].id) {
			pending[insert] = pending[insert - 1]
			insert -= 1
		}
		pending[insert] = index
		pending_count += 1
	}
	for index in pending[:pending_count] {
		if count >= len(out) {break}
		out[count] = index
		count += 1
	}
	return count
}

@(private)
text_less :: proc(a, b: string) -> bool {
	for i in 0 ..< min(len(a), len(b)) {
		if a[i] != b[i] {return a[i] < b[i]}
	}
	return len(a) < len(b)
}

// Whether `id` already has an explicit place in profile.order. Unlisted machine profiles use
// implicit ID order until the owner reorders the table.
profile_order_has :: proc(p: ^Profiles, id: string) -> bool {
	for known in p.order {
		if known == id {return true}
	}
	return false
}

// Moves the profile at `from` into the gap before `to`, which is indexed in `ids` before the move.
// `out` receives the reordered IDs and must hold at least len(ids) entries.
profile_move :: proc(ids: []string, from, to: int, out: []string) -> []string {
	count := min(len(ids), len(out))
	if count == 0 {return out[:0]}
	index := clamp(from, 0, count - 1)
	slot := clamp(to, 0, count)
	if slot > index {slot -= 1}
	written := 0
	for id, i in ids[:count] {
		if i == index {continue}
		if written == slot {
			out[written] = ids[index]
			written += 1
		}
		out[written] = id
		written += 1
	}
	if written < count {
		out[written] = ids[index]
		written += 1
	}
	return out[:written]
}

// The order text after a move: the given IDs in order, then every other ID in `others` that is
// not already listed. Stale IDs are dropped because nothing reads them.
@(require_results)
profile_order_text :: proc(
	ids, others: []string,
	allocator := context.allocator,
) -> (
	text: string,
	alloc_error: runtime.Allocator_Error,
) {
	builder := strings.builder_make(allocator) or_return
	defer strings.builder_destroy(&builder)
	first := true
	for id in ids {
		if id == "" {continue}
		if !first {
			if write_error := write_parts(&builder, ", "); write_error != nil {
				return "", write_error
			}
		}
		if write_error := write_parts(&builder, id); write_error != nil {return "", write_error}
		first = false
	}
	for id in others {
		if id == "" {continue}
		listed := false
		for known in ids {listed ||= known == id}
		if listed {continue}
		if !first {
			if write_error := write_parts(&builder, ", "); write_error != nil {
				return "", write_error
			}
		}
		if write_error := write_parts(&builder, id); write_error != nil {return "", write_error}
		first = false
	}
	return strings.clone(strings.to_string(builder), allocator)
}

// Rewrites the legacy shell keys into profile.default.* and adds the new selection keys. Returns
// the owned replacement text only when something changed, so an already migrated file is not
// rewritten on every load. Comments, the BOM and the line ending convention are preserved.
@(require_results)
migrate_text :: proc(
	text: string,
	allocator := context.allocator,
) -> (
	updated: string,
	migrated: bool,
	err: runtime.Allocator_Error,
) {
	scanner := line_scanner_init(text)
	legacy, default_written, has_default: bit_set[Legacy_Shell_Field]
	has_default_profile := false
	has_order := false
	has_profile := false
	last_shell_line := 0
	first_profile_line := 0
	for {
		line, ok := line_next(&scanner)
		if !ok {break}
		if !line.split {continue}
		if field, matches := legacy_shell_field(line.key); matches {legacy += {field}}
		if id, name, shaped := profile_key_split(line.key); shaped && id == PROFILE_DEFAULT_ID {
			profile_field, known := profile_field_from_name(name)
			for target, field in legacy_shell_profile_fields {
				if known && target == profile_field {has_default += {field}}
			}
		}
		if line.key == "shell.default_profile" {has_default_profile = true}
		if line.key == PROFILE_ORDER_KEY {has_order = true}
		if strings.has_prefix(line.key, PROFILE_PREFIX) {
			has_profile = true
			if first_profile_line == 0 {first_profile_line = line.number}
		}
		if strings.has_prefix(line.key, "shell.") {last_shell_line = line.number}
	}
	need := legacy != {} || has_profile && (!has_default_profile || !has_order)
	if !need {return "", false, nil}

	builder, build_error := strings.builder_make(allocator)
	if build_error != nil {return "", false, build_error}
	defer strings.builder_destroy(&builder)
	if scanner.bom {
		if err = write_parts(&builder, UTF8_BOM); err != nil {return}
	}
	insert_after := last_shell_line
	if insert_after == 0 {insert_after = first_profile_line - 1}
	inserted := false
	rescanner := line_scanner_init(text)
	for {
		line, ok := line_next(&rescanner)
		if !ok {break}
		if !inserted && line.number == insert_after + 1 {
			if err = write_selection_keys(
				&builder,
				rescanner.eol,
				has_default_profile,
				has_order,
			); err != nil {return}
			inserted = true
		}
		if line.split {
			if field, matches := legacy_shell_field(line.key); matches {
				if field in has_default || field in default_written {continue}
				default_written += {field}
				name := profile_field_names[legacy_shell_profile_fields[field]]
				if err = write_parts(&builder, PROFILE_PREFIX, PROFILE_DEFAULT_ID, ".", name, " = ");
				   err != nil {return}
				if err = write_migrated_value(&builder, line.value); err != nil {return}
				if err = write_parts(&builder, line.eol); err != nil {return}
				continue
			}
		}
		if err = write_parts(&builder, line.raw); err != nil {return}
	}
	if !inserted {
		if len(text) > 0 && text[len(text) - 1] != '\n' {
			if err = write_parts(&builder, rescanner.eol); err != nil {return}
		}
		if err = write_selection_keys(
			&builder,
			rescanner.eol,
			has_default_profile,
			has_order,
		); err != nil {return}
	}
	updated, err = strings.clone(strings.to_string(builder), allocator)
	migrated = err == nil
	return
}

@(private)
write_selection_keys :: proc(
	b: ^strings.Builder,
	eol: string,
	has_default_profile, has_order: bool,
) -> runtime.Allocator_Error {
	if !has_default_profile {
		if err := write_parts(b, "shell.default_profile = default", eol); err != nil {
			return err
		}
	}
	if !has_order {
		if err := write_parts(b, PROFILE_ORDER_KEY, " = default", eol); err != nil {return err}
	}
	return nil
}

@(private)
write_migrated_value :: proc(b: ^strings.Builder, raw: string) -> runtime.Allocator_Error {
	trimmed := strings.trim_space(raw)
	if len(trimmed) >= 2 && trimmed[0] == '"' && trimmed[len(trimmed) - 1] == '"' {
		return write_parts(b, trimmed)
	}
	return write_parts(b, "\"", raw, "\"")
}

// Interactive order edits are all or nothing: any empty, malformed or repeated entry refuses them.
@(private)
profile_order_text_valid :: proc(text: string) -> bool {
	offset := 0
	for token in order_token_next(text, &offset) {
		if !token.valid || token.repeated {return false}
	}
	return true
}

// Removes every profile.ID.* line while preserving comments, BOM and line endings.
@(require_results)
remove_profile_text :: proc(
	text, id: string,
	allocator := context.allocator,
) -> (
	string,
	runtime.Allocator_Error,
) {
	builder, build_error := strings.builder_make(allocator)
	if build_error != nil {return "", build_error}
	defer strings.builder_destroy(&builder)
	scanner := line_scanner_init(text)
	if scanner.bom {
		if err := write_parts(&builder, UTF8_BOM); err != nil {return "", err}
	}
	prefix := fmt.tprintf("%s%s.", PROFILE_PREFIX, id)
	for {
		line, ok := line_next(&scanner)
		if !ok {break}
		if line.split && strings.has_prefix(line.key, prefix) {continue}
		if err := write_parts(&builder, line.raw); err != nil {return "", err}
	}
	return strings.clone(strings.to_string(builder), allocator)
}

// Serializes one profile row from the settings editor. The returned text is temporary and is
// consumed immediately by edit_text.
profile_edit_text :: proc(key, value: string) -> (serialized, issue: string) {
	if key == PROFILE_ORDER_KEY {
		if !profile_order_text_valid(value) {
			return "", "Use comma-separated profile IDs, each lowercase with digits, - or _."
		}
		return value, ""
	}
	id, field_name, shaped := profile_key_split(key)
	if !shaped {
		return "", "Expected profile.ID.name, profile.ID.command, profile.ID.directory, " +
			"profile.ID.icon, profile.ID.hidden or profile.order."
	}
	if !id_valid(id, PROFILE_ID_MAX_LENGTH) {
		return "", "Invalid profile ID. Use lowercase letters, digits, - and _."
	}
	field, known := profile_field_from_name(field_name)
	if !known {
		return "", "Unknown profile field. Expected name, command, directory, icon or hidden."
	}
	text, field_issue := profile_field_check(field, value, .Interactive_Field)
	if field_issue != .None {return "", profile_problem_text(field_issue, .Interactive_Field, value)}
	if field == .Hidden {return text, ""}
	builder, build_error := strings.builder_make(context.temp_allocator)
	if build_error != nil {return "", "Could not allocate the settings change."}
	defer strings.builder_destroy(&builder)
	if write_parts(&builder, "\"", value, "\"") != nil {
		return "", "Could not allocate the settings change."
	}
	return strings.to_string(builder), ""
}

