package settings

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

PROFILE_PREFIX :: "profile."
PROFILE_ORDER_KEY :: "profile.order"
PROFILE_DEFAULT_ID :: "default"
DEFAULT_PROFILE_COMMAND :: "pwsh.exe -NoLogo"
DEFAULT_PROFILE_DIRECTORY :: "~"
PROFILE_ID_MAX_LENGTH :: 32
PROFILE_LIMIT :: 64
PROFILE_DEFAULT_FIELDS :: [3]string{"command", "directory", "icon"}

// One named shell. Fields are the effective values after profiles_finalize; the `_set` flags
// record whether the file or detection supplied them, so a later finalize can inherit the rest.
Profile :: struct {
	id, name, command, directory, icon: string,
	hidden, detected:                  bool,
	line:                              int,
	name_set, command_set:             bool,
	directory_set, icon_set:           bool,
	hidden_set:                        bool,
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
	for &profile in p.items {
		for field in ([?]string {
			profile.id,
			profile.name,
			profile.command,
			profile.directory,
			profile.icon,
		}) {delete(field, p.allocator)}
	}
	delete(p.items)
	for id in p.order {delete(id, p.allocator)}
	delete(p.order)
	delete(p.default_id, p.allocator)
	p^ = {}
}

profile_find :: proc(p: ^Profiles, id: string) -> ^Profile {
	for &profile in p.items {
		if profile.id == id {return &profile}
	}
	return nil
}

// Appends a profile with an owned ID. `nil` means the limit was reached.
@(require_results)
profiles_add :: proc(
	p: ^Profiles,
	id: string,
	line: int,
) -> (
	^Profile,
	runtime.Allocator_Error,
) {
	if found := profile_find(p, id); found != nil {return found, nil}
	if len(p.items) >= PROFILE_LIMIT {return nil, nil}
	owned, err := strings.clone(id, p.allocator)
	if err != nil {return nil, err}
	if _, append_error := append(&p.items, Profile{id = owned, line = line});
	   append_error != nil {
		delete(owned, p.allocator)
		return nil, append_error
	}
	return &p.items[len(p.items) - 1], nil
}

profile_id_valid :: proc(id: string) -> bool {
	if len(id) == 0 || len(id) > PROFILE_ID_MAX_LENGTH {return false}
	if id[0] == '-' || id[0] == '_' {return false}
	for c in id {
		letter := c >= 'a' && c <= 'z'
		digit := c >= '0' && c <= '9'
		if !letter && !digit && c != '_' && c != '-' {return false}
	}
	return true
}

profile_field_valid :: proc(field: string) -> bool {
	for name in ([?]string{"name", "command", "directory", "icon", "hidden"}) {
		if field == name {return true}
	}
	return false
}

// Splits "profile.ID.field"; `profile.order` is handled before this is called.
profile_key_split :: proc(key: string) -> (id, field: string, shaped: bool) {
	if !strings.has_prefix(key, PROFILE_PREFIX) {return "", "", false}
	rest := key[len(PROFILE_PREFIX):]
	dot := strings.last_index_byte(rest, '.')
	if dot <= 0 || dot + 1 >= len(rest) {return "", "", false}
	return rest[:dot], rest[dot + 1:], true
}

// The three pre-profile shell keys. They stay accepted so a file whose migration cannot be
// written still launches; the file format otherwise uses profile.default.*.
legacy_shell_slot :: proc(key: string) -> (slot: int, matches: bool) {
	switch key {
	case "shell.command":
		return 0, true
	case "shell.directory":
		return 1, true
	case "shell.icon":
		return 2, true
	}
	return 0, false
}

legacy_shell_entry :: proc(slot: int) -> Schema_Entry {
	switch slot {
	case 0:
		return {
			key = "shell.command",
			kind = .String,
			offset = offset_of(Settings, shell) + offset_of(Shell_Settings, command),
			default_value = DEFAULT_PROFILE_COMMAND,
			minimum = 1,
			maximum = 32767,
		}
	case 1:
		return {
			key = "shell.directory",
			kind = .String,
			offset = offset_of(Settings, shell) + offset_of(Shell_Settings, directory),
			default_value = DEFAULT_PROFILE_DIRECTORY,
			minimum = 1,
			maximum = 32767,
		}
	case 2:
		return {
			key = "shell.icon",
			kind = .String,
			offset = offset_of(Settings, shell) + offset_of(Shell_Settings, icon),
			maximum = 32767,
		}
	}
	unreachable()
}

@(private)
profile_text_value :: proc(input: string) -> (text, issue: string) {
	text = input
	if len(text) > 0 && text[0] == '"' {
		if len(text) < 2 || text[len(text) - 1] != '"' {
			return "", "expected a closing double quote"
		}
		text = text[1:len(text) - 1]
	}
	if !utf8.valid_string(text) || strings.contains(text, "\x00") {
		return "", "expected UTF-8 text without NUL bytes"
	}
	return text, ""
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

@(private)
profile_duplicate_diagnostic :: proc(
	diagnostics: ^[dynamic]Diagnostic,
	key: string,
	line: int,
) -> runtime.Allocator_Error {
	issue, issue_error := problem(
		.Duplicate_Key,
		diagnostics.allocator,
		"duplicate key \"",
		key,
		"\"; last value wins",
	)
	if issue_error != nil {return issue_error}
	return add_diagnostic(diagnostics, line, key, issue.(Problem))
}

@(private, require_results)
parse_profile_order :: proc(
	p: ^Profiles,
	value: string,
	line: int,
	diagnostics: ^[dynamic]Diagnostic,
) -> runtime.Allocator_Error {
	if p.order_line > 0 {
		if err := profile_duplicate_diagnostic(diagnostics, PROFILE_ORDER_KEY, line);
		   err != nil {return err}
	}
	p.order_line = line
	for id in p.order {delete(id, p.allocator)}
	clear(&p.order)
	if strings.trim_space(value) == "" {return nil}
	parts, split_error := strings.split(value, ",", p.allocator)
	if split_error != nil {return split_error}
	defer delete(parts, p.allocator)
	for part in parts {
		id := strings.trim_space(part)
		if id == "" {continue}
		if !profile_id_valid(id) {
			if err := diagnostic_append(
				diagnostics,
				line,
				PROFILE_ORDER_KEY,
				"invalid profile ID in order; use lowercase letters, digits, - and _",
			); err != nil {return err}
			continue
		}
		duplicate := false
		for existing in p.order {duplicate ||= existing == id}
		if duplicate {
			if err := profile_duplicate_diagnostic(diagnostics, PROFILE_ORDER_KEY, line);
			   err != nil {return err}
			continue
		}
		owned, clone_error := strings.clone(id, p.allocator)
		if clone_error != nil {return clone_error}
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
	id, field, shaped := profile_key_split(key)
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
	if !profile_id_valid(id) {
		return diagnostic_append(
			diagnostics,
			line,
			key,
			"invalid profile ID; use lowercase letters, digits, - and _",
			.Unknown_Key,
		)
	}
	if !profile_field_valid(field) {
		message, message_error := strings.concatenate(
			{"unknown profile field \"", field, "\"; expected name, command, ",
			 "directory, icon or hidden"},
			context.temp_allocator,
		)
		if message_error != nil {
			message = "unknown profile field; expected name, command, directory, icon or hidden"
		}
		return diagnostic_append(diagnostics, line, key, message, .Unknown_Key)
	}
	profile, add_error := profiles_add(p, id, line)
	if add_error != nil {return add_error}
	if profile == nil {
		return diagnostic_append(
			diagnostics,
			line,
			key,
			"too many profiles; the limit is 64",
			.Invalid_Value,
		)
	}
	if field == "hidden" {
		if value != "true" && value != "false" {
			message, message_error := strings.concatenate(
				{"invalid boolean \"", value, "\", expected true or false"},
				context.temp_allocator,
			)
			if message_error != nil {message = "expected true or false"}
			return diagnostic_append(diagnostics, line, key, message, .Invalid_Value)
		}
		if profile.hidden_set {
			if err := profile_duplicate_diagnostic(diagnostics, key, line); err != nil {
				return err
			}
		}
		profile.hidden, profile.hidden_set = value == "true", true
		return nil
	}
	text, text_issue := profile_text_value(value)
	if text_issue != "" {
		return diagnostic_append(diagnostics, line, key, text_issue, .Invalid_Value)
	}
	if text == "" && field == "name" {
		return diagnostic_append(
			diagnostics,
			line,
			key,
			"profile name cannot be empty",
			.Invalid_Value,
		)
	}
	if text == "" && field == "command" {
		return diagnostic_append(
			diagnostics,
			line,
			key,
			"profile command line cannot be empty",
			.Invalid_Value,
		)
	}
	duplicate :=
		field == "name" ? profile.name_set : field == "command" ? profile.command_set :
		field == "directory" ? profile.directory_set : field == "icon" ? profile.icon_set : false
	if duplicate {
		if err := profile_duplicate_diagnostic(diagnostics, key, line); err != nil {
			return err
		}
	}
	switch field {
	case "name":
		if err := profile_own(&profile.name, text, p.allocator); err != nil {return err}
		profile.name_set = true
	case "command":
		if err := profile_own(&profile.command, text, p.allocator); err != nil {return err}
		profile.command_set = true
	case "directory":
		if text != "" {
			if err := profile_own(&profile.directory, text, p.allocator); err != nil {return err}
			profile.directory_set = true
		}
	case "icon":
		if err := profile_own(&profile.icon, text, p.allocator); err != nil {return err}
		profile.icon_set = true
	}
	return nil
}

@(private)
profile_name_from_command :: proc(command: string) -> string {
	executable := shell_executable(command)
	switch {
	case strings.equal_fold(executable, "pwsh"):
		return "PowerShell 7"
	case strings.equal_fold(executable, "powershell"):
		return "Windows PowerShell"
	case strings.equal_fold(executable, "cmd"):
		return "Command Prompt"
	case strings.equal_fold(executable, "wsl"):
		return "WSL"
	case strings.equal_fold(executable, "bash"):
		return "Bash"
	}
	return executable
}

// Resolves inheritance and mirrors the default profile into the legacy shell fields. Safe to call
// again after detection adds profiles; values the file or detection set are left alone.
@(require_results)
profiles_finalize :: proc(s: ^Settings) -> runtime.Allocator_Error {
	p := &s.profiles
	default_profile, add_error := profiles_add(p, PROFILE_DEFAULT_ID, 0)
	if add_error != nil {return add_error}
	if default_profile == nil {return .Out_Of_Memory}
	if !default_profile.command_set {
		command := s.shell.command != "" ? s.shell.command : DEFAULT_PROFILE_COMMAND
		if err := profile_own(&default_profile.command, command, p.allocator);
		   err != nil {return err}
	}
	if !default_profile.directory_set {
		directory := s.shell.directory != "" ? s.shell.directory : DEFAULT_PROFILE_DIRECTORY
		if err := profile_own(&default_profile.directory, directory, p.allocator);
		   err != nil {return err}
	}
	if !default_profile.icon_set {
		if err := profile_own(&default_profile.icon, s.shell.icon, p.allocator);
		   err != nil {return err}
	}
	if !default_profile.name_set {
		name := profile_name_from_command(default_profile.command)
		if name == "" {name = PROFILE_DEFAULT_ID}
		if err := profile_own(&default_profile.name, name, p.allocator); err != nil {
			return err
		}
	}
	// Existing callers read shell.command, shell.directory and shell.icon; keep them equal to
	// the resolved default profile so there is one effective source.
	if err := profile_own(&s.shell.command, default_profile.command, p.allocator);
	   err != nil {return err}
	if err := profile_own(&s.shell.directory, default_profile.directory, p.allocator);
	   err != nil {return err}
	if err := profile_own(&s.shell.icon, default_profile.icon, p.allocator); err != nil {
		return err
	}
	for &profile in p.items {
		if profile.id == PROFILE_DEFAULT_ID {continue}
		if !profile.directory_set {
			if err := profile_own(&profile.directory, s.shell.directory, p.allocator);
			   err != nil {return err}
		}
		if !profile.icon_set {
			if err := profile_own(&profile.icon, "", p.allocator); err != nil {return err}
		}
		if !profile.name_set {
			if err := profile_own(&profile.name, profile.id, p.allocator); err != nil {
				return err
			}
		}
	}
	default_id := s.shell.default_profile != "" ? s.shell.default_profile : PROFILE_DEFAULT_ID
	if err := profile_own(&p.default_id, default_id, p.allocator); err != nil {return err}
	return nil
}

profile_default :: proc(p: ^Profiles) -> ^Profile {
	if found := profile_find(p, p.default_id); found != nil {return found}
	return profile_find(p, PROFILE_DEFAULT_ID)
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
	profile := &p.items[index]
	for field in ([?]string {
		profile.id,
		profile.name,
		profile.command,
		profile.directory,
		profile.icon,
	}) {delete(field, p.allocator)}
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
	created := profile == nil
	if created {
		profile, _ = profiles_add(p, detected.id, 0)
		if profile == nil {return nil}
	}
	if created {profile.detected = true}
	if !profile.name_set {
		if err := profile_own(&profile.name, detected.name, p.allocator); err != nil {return err}
		profile.name_set = true
	}
	if !profile.command_set {
		if err := profile_own(&profile.command, detected.command, p.allocator);
		   err != nil {return err}
		profile.command_set = true
	}
	if !profile.directory_set {
		if err := profile_own(&profile.directory, detected.directory, p.allocator);
		   err != nil {return err}
		profile.directory_set = true
	}
	return nil
}

// Fills `out` with profile indices: explicit profile.order first, then unlisted IDs sorted by
// ID. Hidden profiles and profiles without a command are skipped when `visible_only` is set.
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

// Whether `id` already has an explicit place in profile.order. Detected profiles that are only
// detected keep their implicit ID order; a drag must not write them into the file.
profile_order_has :: proc(p: ^Profiles, id: string) -> bool {
	for known in p.order {
		if known == id {return true}
	}
	return false
}

// Whether another profile already shows `name`. Surrounding space and case are ignored, and the
// profile named by `id` is skipped so re-saving an unchanged name is allowed.
profile_name_taken :: proc(p: ^Profiles, id, name: string) -> bool {
	target := strings.trim_space(name)
	if target == "" {return false}
	for &profile in p.items {
		if profile.id == id {continue}
		if strings.equal_fold(strings.trim_space(profile.name), target) {return true}
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
	legacy: [3]bool
	default_written: [3]bool
	has_default: [3]bool
	has_default_profile := false
	has_order := false
	has_profile := false
	last_shell_line := 0
	first_profile_line := 0
	for {
		line, ok := line_next(&scanner)
		if !ok {break}
		if !line.split {continue}
		if slot, matches := legacy_shell_slot(line.key); matches {legacy[slot] = true}
		if strings.has_prefix(line.key, "profile.default.") {
			field := line.key[len("profile.default."):]
			for name, i in PROFILE_DEFAULT_FIELDS {if field == name {has_default[i] = true}}
		}
		if line.key == "shell.default_profile" {has_default_profile = true}
		if line.key == PROFILE_ORDER_KEY {has_order = true}
		if strings.has_prefix(line.key, PROFILE_PREFIX) {
			has_profile = true
			if first_profile_line == 0 {first_profile_line = line.number}
		}
		if strings.has_prefix(line.key, "shell.") {last_shell_line = line.number}
	}
	need :=
		legacy[0] ||
		legacy[1] ||
		legacy[2] ||
		has_profile && (!has_default_profile || !has_order)
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
	fields := PROFILE_DEFAULT_FIELDS
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
			if slot, matches := legacy_shell_slot(line.key); matches {
				if has_default[slot] || default_written[slot] {continue}
				default_written[slot] = true
				field := fields[slot]
				if err = write_parts(&builder, "profile.default.", field, " = "); err != nil {
					return
				}
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

@(private)
profile_order_text_valid :: proc(text: string) -> bool {
	parts, split_error := strings.split(text, ",", context.temp_allocator)
	if split_error != nil {return false}
	for part, i in parts {
		id := strings.trim_space(part)
		if id == "" {return false}
		if !profile_id_valid(id) {return false}
		for previous, j in parts {
			if i == j {continue}
			if strings.trim_space(previous) == id {return false}
		}
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
	id, field, shaped := profile_key_split(key)
	if !shaped {
		return "", "Expected profile.ID.name, profile.ID.command, profile.ID.directory, " +
			"profile.ID.icon, profile.ID.hidden or profile.order."
	}
	if !profile_id_valid(id) {
		return "", "Invalid profile ID. Use lowercase letters, digits, - and _."
	}
	if !profile_field_valid(field) {
		return "", "Unknown profile field. Expected name, command, directory, icon or hidden."
	}
	if field == "hidden" {
		if value != "true" && value != "false" {return "", "Expected true or false."}
		return value, ""
	}
	if field == "name" && value == "" {return "", "A profile needs a name."}
	if field == "command" && value == "" {return "", "A profile needs a command line."}
	if !utf8.valid_string(value) || strings.contains(value, "\x00") {
		return "", "Expected UTF-8 text without NUL bytes."
	}
	builder, build_error := strings.builder_make(context.temp_allocator)
	if build_error != nil {return "", "Could not allocate the settings change."}
	defer strings.builder_destroy(&builder)
	if write_parts(&builder, "\"", value, "\"") != nil {
		return "", "Could not allocate the settings change."
	}
	return strings.to_string(builder), ""
}

