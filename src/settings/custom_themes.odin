package settings

import "aio:colour"
import "base:runtime"
import "core:fmt"
import "core:strings"

CUSTOM_THEME_PREFIX :: "theme.custom."
CUSTOM_THEME_LIMIT :: 64
// How many bases a theme may stack; a cycle stops here.
THEME_BASE_DEPTH :: 8
// Theme IDs share the profile ID grammar but declare their own limit.
THEME_ID_MAX_LENGTH :: 32

theme_id_valid :: proc(id: string) -> bool {return id_valid(id, THEME_ID_MAX_LENGTH)}

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

Custom_Theme_Field :: enum {
	Base,
	Name,
	Color,
}

// What a theme.custom.ID.FIELD key names. The file and Settings check keys with this one grammar
// and word its problems for their own readers.
Custom_Theme_Key :: struct {
	id, field: string,
	kind:      Custom_Theme_Field,
	token:     Theme_Token,
}

Custom_Theme_Key_Problem :: enum {
	None,
	Shape,
	Id,
	Unknown_Color,
}

custom_theme_key :: proc(key: string) -> (parsed: Custom_Theme_Key, problem: Custom_Theme_Key_Problem) {
	id, field, shaped := custom_theme_key_split(key)
	if !shaped {return {}, .Shape}
	if !theme_id_valid(id) {return {}, .Id}
	parsed = {id = id, field = field}
	switch field {
	case "base":
		parsed.kind = .Base
	case "name":
		parsed.kind = .Name
	case:
		token, found := token_find(field)
		if !found {return {}, .Unknown_Color}
		parsed.kind, parsed.token = .Color, token
	}
	return parsed, .None
}

// Validates one custom theme line from Settings and returns its canonical file value. The
// serialized text is temporary and is consumed immediately by edit_text.
custom_theme_value :: proc(
	key, value: string,
	policy: colour.Parse_Policy,
) -> (
	serialized, issue: string,
) {
	parsed, problem := custom_theme_key(key)
	switch problem {
	case .None:
	case .Shape:
		return "", "Expected theme.custom.ID.base or theme.custom.ID.COLOR."
	case .Id:
		return "", "Invalid theme ID. Use lowercase letters, digits, - and _."
	case .Unknown_Color:
		return "", "Unknown theme color."
	}
	switch parsed.kind {
	case .Base:
		if !theme_id_valid(value) {return "", "Expected a theme ID such as studio-dark or tide-light."}
		return value, ""
	case .Name:
		if !text_valid(value) {return "", "Expected UTF-8 text without NUL bytes."}
		return fmt.tprintf("\"%s\"", value), ""
	case .Color:
		c, valid := theme_color_parse(parsed.token, value, policy)
		if !valid {
			tokens := THEME_TOKENS
			if tokens[parsed.token].kind == .Translucent {
				return "", "Expected a color such as #rrggbb or #rrggbbaa."
			}
			return "", "Expected a color such as #rrggbb."
		}
		return theme_color_text(parsed.token, c), ""
	}
	return "", ""
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
	parsed, problem := custom_theme_key(key)
	switch problem {
	case .None:
	case .Shape:
		return diagnostic_append(
			diagnostics,
			line,
			key,
			"expected theme.custom.ID.base or theme.custom.ID.COLOR",
			.Unknown_Key,
		)
	case .Id:
		return diagnostic_append(
			diagnostics,
			line,
			key,
			"invalid theme ID; use lowercase letters, digits, - and _",
			.Unknown_Key,
		)
	case .Unknown_Color:
		_, field, _ := custom_theme_key_split(key)
		message, message_error := strings.concatenate(
			{"unknown theme color \"", field, "\""},
			context.temp_allocator,
		)
		if message_error != nil {message = "unknown theme color"}
		return diagnostic_append(diagnostics, line, key, message, .Unknown_Key)
	}
	theme, add_error := custom_theme_add(s, parsed.id)
	if add_error != nil {return add_error}
	if theme == nil {
		return diagnostic_append(diagnostics, line, key, limit_message("custom themes", CUSTOM_THEME_LIMIT))
	}
	duplicate: bool
	switch parsed.kind {
	case .Base:
		duplicate = theme.base_set
	case .Name:
		duplicate = theme.name_set
	case .Color:
		duplicate = parsed.token in theme.overrides
	}
	if duplicate {
		if err := duplicate_key_diagnostic(diagnostics, key, line); err != nil {return err}
	}
	switch parsed.kind {
	case .Base:
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
	case .Name:
		text, issue := text_value_decode(value)
		if issue != "" {return diagnostic_append(diagnostics, line, key, issue)}
		name, clone_error := strings.clone(text, s.allocator)
		if clone_error != nil {return clone_error}
		delete(theme.name, s.allocator)
		theme.name, theme.name_set = name, true
	case .Color:
		token := parsed.token
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
	}
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
		theme_line := setting_line(s, "theme.name")
		if err := diagnostic_append(diagnostics, theme_line, "theme.name", message); err != nil {
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
