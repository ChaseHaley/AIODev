package settings

import "aio:colour"
import "base:runtime"
import "core:fmt"
import "core:strings"

CUSTOM_THEME_PREFIX :: "theme.custom."
CUSTOM_THEME_LIMIT :: 64
// How many bases a theme may stack; a cycle stops here.
THEME_BASE_DEPTH :: 8

// Theme IDs follow profile IDs.
theme_id_valid :: proc(id: string) -> bool {return profile_id_valid(id)}

// Built-in themes were once a name plus a dark or light mode, and bases named a variant such as
// tokyonight-storm-dark. Each now is one theme file; this maps the old pair to that file's ID.
theme_legacy_id :: proc(name, mode: string) -> (id: string, legacy: bool) {
	switch name {
	case "studio", "tide", "ember":
		return fmt.tprintf("%s-%s", name, mode == "light" ? "light" : "dark"), true
	case "tokyonight-night", "tokyonight-storm", "tokyonight-moon":
		return mode == "light" ? "tokyonight-day" : name, true
	}
	return name, false
}

// A base written before built-in themes became files, such as tokyonight-moon-light, as its file ID.
@(private)
theme_legacy_base :: proc(base: string) -> string {
	for mode in ([?]string{"dark", "light"}) {
		if !strings.has_suffix(base, mode) || len(base) <= len(mode) + 1 {continue}
		name := base[:len(base) - len(mode) - 1]
		if id, legacy := theme_legacy_id(name, mode); legacy {return id}
	}
	return base
}

custom_theme_find :: proc(s: ^Settings, id: string) -> ^Custom_Theme {
	for &theme in s.themes {
		if theme.id == id {return &theme}
	}
	return nil
}

// Splits theme.custom.ID.FIELD. A field may itself contain dots, as palette.3 does.
custom_theme_key_split :: proc(key: string) -> (id, field: string, ok: bool) {
	if !strings.has_prefix(key, CUSTOM_THEME_PREFIX) {return}
	rest := key[len(CUSTOM_THEME_PREFIX):]
	dot := strings.index_byte(rest, '.')
	if dot <= 0 || dot == len(rest) - 1 {return}
	return rest[:dot], rest[dot + 1:], true
}

// Validates one custom theme line and returns its canonical file value. The serialized text is
// temporary and is consumed immediately by edit_text.
custom_theme_value :: proc(
	key, value: string,
	policy: colour.Parse_Policy,
) -> (
	serialized, issue: string,
) {
	id, field, shaped := custom_theme_key_split(key)
	if !shaped {return "", "Expected theme.custom.ID.base or theme.custom.ID.COLOR."}
	if !theme_id_valid(id) {return "", "Invalid theme ID. Use lowercase letters, digits, - and _."}
	if field == "base" {
		if !theme_id_valid(value) {return "", "Expected a theme ID such as studio-dark or tide-light."}
		return value, ""
	}
	if field == "name" {
		if !profile_value_facts(value).valid {return "", "Expected UTF-8 text without NUL bytes."}
		return fmt.tprintf("\"%s\"", value), ""
	}
	token, found := token_find(field)
	if !found {return "", "Unknown theme color."}
	c, valid := theme_color_parse(token, value, policy)
	if !valid {
		tokens := THEME_TOKENS
		if tokens[token].kind == .Translucent {return "", "Expected a color such as #rrggbb or #rrggbbaa."}
		return "", "Expected a color such as #rrggbb."
	}
	return theme_color_text(token, c), ""
}

@(private, require_results)
custom_theme_add :: proc(s: ^Settings, id: string) -> (^Custom_Theme, runtime.Allocator_Error) {
	if found := custom_theme_find(s, id); found != nil {return found, nil}
	if len(s.themes) >= CUSTOM_THEME_LIMIT {return nil, nil}
	owned, err := strings.clone(id, s.allocator)
	if err != nil {return nil, err}
	if _, append_error := append(&s.themes, Custom_Theme{id = owned}); append_error != nil {
		delete(owned, s.allocator)
		return nil, append_error
	}
	return &s.themes[len(s.themes) - 1], nil
}

@(private, require_results)
parse_custom_theme_key :: proc(
	s: ^Settings,
	diagnostics: ^[dynamic]Diagnostic,
	key, value: string,
	line: int,
) -> runtime.Allocator_Error {
	id, field, shaped := custom_theme_key_split(key)
	if !shaped {
		return diagnostic_append(
			diagnostics,
			line,
			key,
			"expected theme.custom.ID.base or theme.custom.ID.COLOR",
			.Unknown_Key,
		)
	}
	if !theme_id_valid(id) {
		return diagnostic_append(
			diagnostics,
			line,
			key,
			"invalid theme ID; use lowercase letters, digits, - and _",
			.Unknown_Key,
		)
	}
	token, found := token_find(field)
	if field != "base" && field != "name" && !found {
		message, message_error := strings.concatenate(
			{"unknown theme color \"", field, "\""},
			context.temp_allocator,
		)
		if message_error != nil {message = "unknown theme color"}
		return diagnostic_append(diagnostics, line, key, message, .Unknown_Key)
	}
	theme, add_error := custom_theme_add(s, id)
	if add_error != nil {return add_error}
	if theme == nil {
		return diagnostic_append(diagnostics, line, key, "too many custom themes; the limit is 64")
	}
	if field == "base" ? theme.base_set : field == "name" ? theme.name_set : token in theme.overrides {
		message, message_error := strings.concatenate(
			{"duplicate key \"", key, "\"; last value wins"},
			context.temp_allocator,
		)
		if message_error != nil {message = "duplicate key; last value wins"}
		if err := diagnostic_append(diagnostics, line, key, message, .Duplicate_Key); err != nil {
			return err
		}
	}
	if field == "base" {
		if !theme_id_valid(value) {
			return diagnostic_append(
				diagnostics,
				line,
				key,
				"expected a theme ID such as studio-dark or tide-light",
			)
		}
		base, clone_error := strings.clone(theme_legacy_base(value), s.allocator)
		if clone_error != nil {return clone_error}
		delete(theme.base, s.allocator)
		theme.base, theme.base_set = base, true
		return nil
	}
	if field == "name" {
		text, issue := profile_text_value(value)
		if issue != "" {return diagnostic_append(diagnostics, line, key, issue)}
		name, clone_error := strings.clone(text, s.allocator)
		if clone_error != nil {return clone_error}
		delete(theme.name, s.allocator)
		theme.name, theme.name_set = name, true
		return nil
	}
	c, valid := theme_color_parse(token, value, .Strict)
	if !valid {
		tokens := THEME_TOKENS
		expected := tokens[token].kind == .Translucent ? "#rrggbb or #rrggbbaa" : "#rrggbb"
		message, message_error := strings.concatenate(
			{"invalid color \"", value, "\", expected ", expected},
			context.temp_allocator,
		)
		if message_error != nil {message = "invalid color"}
		return diagnostic_append(diagnostics, line, key, message)
	}
	theme.colors[token] = c
	theme.overrides += {token}
	return nil
}

// Adds the compiled-in default theme when no file or settings line defines its ID.
@(private, require_results)
theme_default_add :: proc(s: ^Settings) -> runtime.Allocator_Error {
	if custom_theme_find(s, DEFAULT_THEME_ID) != nil {return nil}
	file, issue := theme_file_parse(DEFAULT_THEME_TEXT)
	assert(issue == "", "invalid default theme")
	stored, add_error := custom_theme_add(s, DEFAULT_THEME_ID)
	if add_error != nil || stored == nil {return add_error}
	return custom_theme_store(s, stored, file)
}

// Fills a slot from custom_theme_add with a parsed file theme, owning its temporary strings.
@(private, require_results)
custom_theme_store :: proc(
	s: ^Settings,
	stored: ^Custom_Theme,
	file: Custom_Theme,
) -> runtime.Allocator_Error {
	theme := file
	theme.id = stored.id
	theme.base, theme.name = "", ""
	if file.base != "" {theme.base = strings.clone(file.base, s.allocator) or_return}
	if file.name != "" {
		name, err := strings.clone(file.name, s.allocator)
		if err != nil {
			delete(theme.base, s.allocator)
			return err
		}
		theme.name = name
	}
	stored^ = theme
	return nil
}

// What the theme selector shows for a theme: its name, or its ID when it has none. Temporary.
theme_display_name :: proc(s: ^Settings, id: string) -> string {
	if custom := custom_theme_find(s, id); custom != nil && custom.name != "" {return custom.name}
	return id
}

// Resolves the active theme once per load, so the number of themes costs nothing per frame. An
// unknown name or base falls back to the default theme and is reported when the caller collects
// diagnostics.
@(private, require_results)
resolve_theme :: proc(s: ^Settings, diagnostics: ^[dynamic]Diagnostic) -> runtime.Allocator_Error {
	custom := custom_theme_find(s, s.theme.name)
	missing := custom == nil ? s.theme.name : ""
	for next, depth := custom, 0; next != nil && next.base != "" && depth < THEME_BASE_DEPTH; depth += 1 {
		base := custom_theme_find(s, next.base)
		if base == nil {missing = next.base}
		next = base
	}
	if custom == nil {
		s.active_theme = theme_default()
	} else {
		s.active_theme = custom_theme_resolve(s, custom)
	}
	if diagnostics != nil && missing != "" {
		message := fmt.tprintf("unknown theme \"%s\"; using %s", missing, DEFAULT_THEME_ID)
		if err := diagnostic_append(diagnostics, s.theme_line, "theme.name", message); err != nil {
			return err
		}
	}
	s.colors = theme_terminal(s.active_theme)
	return nil
}

// The theme the active custom theme falls back to for a color it does not override; any other
// theme is its own base.
theme_base :: proc(s: ^Settings) -> Theme {
	custom := custom_theme_find(s, s.theme.name)
	if custom == nil || custom.external {return s.active_theme}
	if base := custom_theme_find(s, custom.base); base != nil && base != custom {
		return custom_theme_resolve(s, base)
	}
	return theme_default()
}

// Whether the active theme is defined in the settings file and so may be edited in place.
theme_custom :: proc(s: ^Settings) -> bool {
	custom := custom_theme_find(s, s.theme.name)
	return custom != nil && !custom.external
}
