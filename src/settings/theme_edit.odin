package settings

import "base:runtime"
import "core:fmt"
import "core:strings"

Theme_Edit_Error :: enum {
	None,
	Allocation,
	// The edit was refused; `issue` says why.
	Invalid,
	// The active theme cannot take this edit, such as renaming a built-in theme.
	Unavailable,
}

// Sets one color of the active theme. Built-in themes are never changed: the first edit saves a
// custom theme based on the built-in variant, selects it and returns its new ID in `created`. An
// empty value returns a custom theme's color to its base. `updated` and `created` are owned; `issue`
// is temporary.
@(require_results)
theme_color_edit :: proc(
	source, token_key, value: string,
	allocator := context.allocator,
	themes_directory: string = "",
) -> (
	updated, created, issue: string,
	error: Theme_Edit_Error,
) {
	if _, found := token_find(token_key); !found {return "", "", "", .Unavailable}
	s, diagnostics, parse_error := parse(source, allocator, themes_directory)
	if parse_error != nil {return "", "", "", .Allocation}
	diagnostics_destroy(&diagnostics)
	defer destroy(&s)
	if custom := custom_theme_find(&s, s.theme.name); custom != nil && custom.external {
		copy, id, copy_error := theme_duplicate(source, allocator, themes_directory)
		defer delete(copy, allocator)
		if copy_error != .None {return "", "", "", copy_error}
		updated, _, issue, error = theme_color_edit(copy, token_key, value, allocator, themes_directory)
		if error != .None {delete(id, allocator); return}
		return updated, id, issue, error
	}
	revision, clone_error := strings.clone(source, allocator)
	if clone_error != nil {return "", "", "", .Allocation}
	defer delete(revision, allocator)
	id := s.theme.name
	if !theme_custom(&s) {
		if value == "" {
			updated, clone_error = strings.clone(source, allocator)
			if clone_error != nil {return "", "", "", .Allocation}
			return
		}
		base := Builtin_Theme{builtin_name(&s), s.theme.mode}
		names := THEME_NAMES
		id = theme_id_free(&s, fmt.tprintf("%s-custom", names[base.name]))
		base_key := fmt.tprintf("%s%s.base", CUSTOM_THEME_PREFIX, id)
		if issue, error = theme_edit_line(&revision, base_key, builtin_id(base), allocator);
		   error != .None {return}
		key := fmt.tprintf("%s%s.%s", CUSTOM_THEME_PREFIX, id, token_key)
		if issue, error = theme_edit_line(&revision, key, value, allocator); error != .None {return}
		if issue, error = theme_edit_line(&revision, "theme.name", id, allocator); error != .None {return}
		created, clone_error = strings.clone(id, allocator)
		if clone_error != nil {return "", "", "", .Allocation}
	} else {
		key := fmt.tprintf("%s%s.%s", CUSTOM_THEME_PREFIX, id, token_key)
		if value == "" {
			if error = theme_remove_lines(&revision, key, false, allocator); error != .None {return}
		} else if issue, error = theme_edit_line(&revision, key, value, allocator); error != .None {
			return
		}
	}
	updated, revision = revision, ""
	return
}

// Saves the active theme under a new ID and selects it: a custom theme with all its colors, or an
// empty custom theme based on a built-in variant.
@(require_results)
theme_duplicate :: proc(
	source: string,
	allocator := context.allocator,
	themes_directory: string = "",
) -> (
	updated, created: string,
	error: Theme_Edit_Error,
) {
	s, diagnostics, parse_error := parse(source, allocator, themes_directory)
	if parse_error != nil {return "", "", .Allocation}
	diagnostics_destroy(&diagnostics)
	defer destroy(&s)
	if len(s.themes) >= CUSTOM_THEME_LIMIT {return "", "", .Invalid}
	revision, clone_error := strings.clone(source, allocator)
	if clone_error != nil {return "", "", .Allocation}
	defer delete(revision, allocator)
	id: string
	if custom := custom_theme_find(&s, s.theme.name); custom != nil {
		id = theme_id_free(&s, fmt.tprintf("%s-copy", custom.id))
		if _, error = theme_edit_line(
			&revision,
			fmt.tprintf("%s%s.base", CUSTOM_THEME_PREFIX, id),
			builtin_id(custom.base),
			allocator,
		); error != .None {return}
		tokens := THEME_TOKENS
		for token in custom.overrides {
			key := fmt.tprintf("%s%s.%s", CUSTOM_THEME_PREFIX, id, tokens[token].key)
			text := theme_color_text(token, custom.colors[token])
			if text == "" {continue}
			if _, error = theme_edit_line(&revision, key, text, allocator); error != .None {return}
		}
	} else {
		base := Builtin_Theme{builtin_name(&s), s.theme.mode}
		names := THEME_NAMES
		id = theme_id_free(&s, fmt.tprintf("%s-custom", names[base.name]))
		if _, error = theme_edit_line(
			&revision,
			fmt.tprintf("%s%s.base", CUSTOM_THEME_PREFIX, id),
			builtin_id(base),
			allocator,
		); error != .None {return}
	}
	if _, error = theme_edit_line(&revision, "theme.name", id, allocator); error != .None {return}
	created, clone_error = strings.clone(id, allocator)
	if clone_error != nil {return "", "", .Allocation}
	updated, revision = revision, ""
	return
}

// Renames the active custom theme, rewriting every line it owns and the selection.
@(require_results)
theme_rename :: proc(
	source, new_id: string,
	allocator := context.allocator,
	themes_directory: string = "",
) -> (
	updated, issue: string,
	error: Theme_Edit_Error,
) {
	s, diagnostics, parse_error := parse(source, allocator, themes_directory)
	if parse_error != nil {return "", "", .Allocation}
	diagnostics_destroy(&diagnostics)
	defer destroy(&s)
	if !theme_custom(&s) {return "", "", .Unavailable}
	if custom_theme_find(&s, s.theme.name).external {return "", "", .Unavailable}
	if !theme_id_valid(new_id) {
		return "", "Use lowercase letters, digits, - and _, and no built-in theme name.", .Invalid
	}
	if new_id != s.theme.name && custom_theme_find(&s, new_id) != nil {
		return "", "Another theme uses this ID.", .Invalid
	}
	old_prefix := fmt.tprintf("%s%s.", CUSTOM_THEME_PREFIX, s.theme.name)
	new_prefix := fmt.tprintf("%s%s.", CUSTOM_THEME_PREFIX, new_id)
	builder, build_error := strings.builder_make(allocator)
	if build_error != nil {return "", "", .Allocation}
	defer strings.builder_destroy(&builder)
	scanner := line_scanner_init(source)
	if scanner.bom && write_parts(&builder, UTF8_BOM) != nil {return "", "", .Allocation}
	for {
		line, ok := line_next(&scanner)
		if !ok {break}
		written: runtime.Allocator_Error
		if line.split && strings.has_prefix(line.key, old_prefix) {
			written = write_parts(
				&builder,
				new_prefix,
				line.key[len(old_prefix):],
				" = ",
				line.value,
				line.eol,
			)
		} else {
			written = write_parts(&builder, line.raw)
		}
		if written != nil {return "", "", .Allocation}
	}
	revision, clone_error := strings.clone(strings.to_string(builder), allocator)
	if clone_error != nil {return "", "", .Allocation}
	defer delete(revision, allocator)
	if issue, error = theme_edit_line(&revision, "theme.name", new_id, allocator); error != .None {return}
	updated, revision = revision, ""
	return
}

// Removes the active custom theme and selects the built-in variant it was based on.
@(require_results)
theme_delete :: proc(
	source: string,
	allocator := context.allocator,
	themes_directory: string = "",
) -> (
	updated, selected: string,
	error: Theme_Edit_Error,
) {
	s, diagnostics, parse_error := parse(source, allocator, themes_directory)
	if parse_error != nil {return "", "", .Allocation}
	diagnostics_destroy(&diagnostics)
	defer destroy(&s)
	custom := custom_theme_find(&s, s.theme.name)
	if custom == nil || custom.external {return "", "", .Unavailable}
	revision, clone_error := strings.clone(source, allocator)
	if clone_error != nil {return "", "", .Allocation}
	defer delete(revision, allocator)
	prefix := fmt.tprintf("%s%s.", CUSTOM_THEME_PREFIX, custom.id)
	if error = theme_remove_lines(&revision, prefix, true, allocator); error != .None {return}
	names, modes := THEME_NAMES, THEME_MODES
	if _, error = theme_edit_line(&revision, "theme.name", names[custom.base.name], allocator);
	   error != .None {return}
	if _, error = theme_edit_line(&revision, "theme.mode", modes[custom.base.mode], allocator);
	   error != .None {return}
	selected, clone_error = strings.clone(names[custom.base.name], allocator)
	if clone_error != nil {return "", "", .Allocation}
	updated, revision = revision, ""
	return
}

// The built-in a custom theme would start from: the selected built-in, or Studio for an unknown
// name.
@(private)
builtin_name :: proc(s: ^Settings) -> Theme_Name {
	name, _ := builtin_find(s.theme.name)
	return name
}

// `wanted`, or `wanted-2`, `wanted-3` and so on, whichever no theme uses yet. The result is
// temporary.
@(private)
theme_id_free :: proc(s: ^Settings, wanted: string) -> string {
	stem := wanted
	if len(stem) > PROFILE_ID_MAX_LENGTH - 3 {stem = stem[:PROFILE_ID_MAX_LENGTH - 3]}
	stem = strings.trim_right(stem, "-_")
	id := stem
	for number := 2; custom_theme_find(s, id) != nil; number += 1 {
		id = fmt.tprintf("%s-%d", stem, number)
	}
	return id
}

@(private, require_results)
theme_edit_line :: proc(
	text: ^string,
	key, value: string,
	allocator: runtime.Allocator,
) -> (
	issue: string,
	error: Theme_Edit_Error,
) {
	updated, message, alloc_error := edit_text(text^, key, value, allocator)
	defer delete(message, allocator)
	if alloc_error != nil {
		delete(updated, allocator)
		delete(message, allocator)
		return "", .Allocation
	}
	if message != "" {
		delete(updated, allocator)
		return strings.clone(message, context.temp_allocator), .Invalid
	}
	delete(text^, allocator)
	text^ = updated
	return
}

// Drops every line whose key is `key`, or starts with it when `prefix` is set.
@(private, require_results)
theme_remove_lines :: proc(
	text: ^string,
	key: string,
	prefix: bool,
	allocator: runtime.Allocator,
) -> Theme_Edit_Error {
	builder, build_error := strings.builder_make(allocator)
	if build_error != nil {return .Allocation}
	defer strings.builder_destroy(&builder)
	scanner := line_scanner_init(text^)
	if scanner.bom && write_parts(&builder, UTF8_BOM) != nil {return .Allocation}
	for {
		line, ok := line_next(&scanner)
		if !ok {break}
		if line.split && (prefix ? strings.has_prefix(line.key, key) : line.key == key) {continue}
		if write_parts(&builder, line.raw) != nil {return .Allocation}
	}
	updated, clone_error := strings.clone(strings.to_string(builder), allocator)
	if clone_error != nil {return .Allocation}
	delete(text^, allocator)
	text^ = updated
	return .None
}

@(private)
LEGACY_COLOR_PREFIX :: "colors."

@(private)
LEGACY_COLOR_COMMENTS :: [?]string {
	"# Default foreground color.",
	"# Default background color.",
	"# Shell foreground; empty follows the theme.",
	"# Shell background; empty follows the theme.",
	"# Cursor color.",
	"# Text under the block cursor.",
	"# Selection background color.",
	"# Selection foreground; empty preserves the cell color.",
	"# Text color of search matches.",
	"# Background of search matches.",
	"# Background of the selected search match.",
}

// Settings files from before custom themes override single terminal colors with colors.* lines.
// Those lines move into a custom theme based on the selected built-in variant, so the colors a
// person chose survive; empty lines, which followed the theme, are dropped with the comment that
// the default file wrote above each one.
@(require_results)
migrate_theme_text :: proc(
	text: string,
	allocator := context.allocator,
) -> (
	updated: string,
	migrated: bool,
	err: runtime.Allocator_Error,
) {
	Legacy :: struct {
		token: Theme_Token,
		value: string,
	}
	colors: [len(Theme_Token)]Legacy
	count := 0
	found := false
	scanner := line_scanner_init(text)
	for {
		line, ok := line_next(&scanner)
		if !ok {break}
		if !line.split || !strings.has_prefix(line.key, LEGACY_COLOR_PREFIX) {continue}
		token, known := token_find(line.key[len(LEGACY_COLOR_PREFIX):])
		if !known || !token_terminal(token) {continue}
		found = true
		if line.value == "" {continue}
		if _, valid := theme_color_parse(token, line.value, .Strict); !valid {continue}
		duplicate := false
		for &c in colors[:count] {
			if c.token == token {c.value, duplicate = line.value, true}
		}
		if !duplicate {
			colors[count] = {token, line.value}
			count += 1
		}
	}
	if !found {return "", false, nil}

	builder := strings.builder_make(allocator) or_return
	defer strings.builder_destroy(&builder)
	rescanner := line_scanner_init(text)
	if rescanner.bom {write_parts(&builder, UTF8_BOM) or_return}
	held: string
	for {
		line, ok := line_next(&rescanner)
		if !ok {break}
		legacy := false
		if line.split && strings.has_prefix(line.key, LEGACY_COLOR_PREFIX) {
			token, known := token_find(line.key[len(LEGACY_COLOR_PREFIX):])
			legacy = known && token_terminal(token)
		}
		if legacy {
			if held != "" && !legacy_color_comment(strings.trim_space(held)) {
				write_parts(&builder, held) or_return
			}
			held = ""
			continue
		}
		if held != "" {write_parts(&builder, held) or_return}
		held = ""
		if strings.has_prefix(line.text, "#") {
			held = line.raw
			continue
		}
		write_parts(&builder, line.raw) or_return
	}
	if held != "" {write_parts(&builder, held) or_return}
	revision := strings.clone(strings.to_string(builder), allocator) or_return
	defer delete(revision, allocator)
	if count > 0 {
		s, diagnostics, parse_error := parse(revision, allocator)
		if parse_error != nil {return "", false, parse_error}
		diagnostics_destroy(&diagnostics)
		defer destroy(&s)
		base := Builtin_Theme{builtin_name(&s), s.theme.mode}
		names := THEME_NAMES
		id := theme_id_free(&s, fmt.tprintf("%s-custom", names[base.name]))
		lines := make([dynamic][2]string, 0, count + 2, context.temp_allocator)
		append(&lines, [2]string{fmt.tprintf("%s%s.base", CUSTOM_THEME_PREFIX, id), builtin_id(base)})
		tokens := THEME_TOKENS
		for c in colors[:count] {
			key := fmt.tprintf("%s%s.%s", CUSTOM_THEME_PREFIX, id, tokens[c.token].key)
			append(&lines, [2]string{key, c.value})
		}
		append(&lines, [2]string{"theme.name", id})
		for pair in lines {
			if _, error := theme_edit_line(&revision, pair[0], pair[1], allocator); error != .None {
				return "", false, .Out_Of_Memory
			}
		}
	}
	updated, revision = revision, ""
	return updated, true, nil
}

@(private)
legacy_color_comment :: proc(text: string) -> bool {
	if strings.has_prefix(text, "# ANSI palette color ") {return true}
	for comment in LEGACY_COLOR_COMMENTS {
		if text == comment {return true}
	}
	return false
}
