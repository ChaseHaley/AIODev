package settings

import "cosmos:colour"
import theme_api "cosmos:theme"
import "base:runtime"
import "core:fmt"
import "core:strings"

CUSTOM_THEME_PREFIX :: "theme.custom."
CUSTOM_THEME_LIMIT :: 64

// The persisted key of one custom theme field. Temporary.
@(private)
custom_theme_field_key :: proc(id, field: string) -> string {
	return fmt.tprintf("%s%s.%s", CUSTOM_THEME_PREFIX, id, field)
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
	// The Neovim colorscheme, without a plugin or background: the settings file's form of a theme
	// file's neovim object.
	Neovim,
	Color,
}

// What a theme.custom.ID.FIELD key names. The file and Settings check keys with this one grammar
// and word its problems for their own readers.
Custom_Theme_Key :: struct {
	id, field: string,
	kind:      Custom_Theme_Field,
	token:     theme_api.Token,
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
	if !theme_api.id_valid(id) {return {}, .Id}
	parsed = {id = id, field = field}
	switch field {
	case "base":
		parsed.kind = .Base
	case "name":
		parsed.kind = .Name
	case "neovim":
		parsed.kind = .Neovim
	case:
		token, found := theme_api.token_find(field)
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
		if !theme_api.id_valid(value) {return "", "Expected a theme ID such as studio-dark or tide-light."}
		return value, ""
	case .Name:
		if !text_valid(value) {return "", "Expected UTF-8 text without NUL bytes."}
		return fmt.tprintf("\"%s\"", value), ""
	case .Neovim:
		if !theme_api.neovim_colorscheme_valid(value) {
			return "", "Expected a Neovim colorscheme such as tokyonight-day, or aiodev for the generated one."
		}
		return value, ""
	case .Color:
		v, link := theme_api.value_parse(parsed.token, value, policy)
		if link == .None {return theme_api.value_text(parsed.token, v), ""}
		if clause := theme_api.link_issue(parsed.token, value, link); clause != "" {
			return "", fmt.tprintf("%s%s.", strings.to_upper(clause[:1], context.temp_allocator), clause[1:])
		}
		if theme_api.token_alpha(parsed.token) {
			return "", "Expected a color such as #rrggbb or #rrggbbaa."
		}
		return "", "Expected a color such as #rrggbb."
	}
	return "", ""
}

@(private, require_results)
custom_theme_add :: proc(s: ^Settings, id: string) -> (^theme_api.Layer, runtime.Allocator_Error) {
	if found := theme_api.find(s.themes[:], id); found != nil {return found, nil}
	if len(s.themes) >= CUSTOM_THEME_LIMIT {return nil, nil}
	owned, err := strings.clone(id, s.allocator)
	if err != nil {return nil, err}
	if _, append_error := append(&s.themes, theme_api.Layer{id = owned}); append_error != nil {
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
	case .Neovim:
		duplicate = theme.neovim.colorscheme != ""
	case .Color:
		duplicate = parsed.token in theme.overrides
	}
	if duplicate {
		if err := duplicate_key_diagnostic(diagnostics, key, line); err != nil {return err}
	}
	switch parsed.kind {
	case .Base:
		if !theme_api.id_valid(value) {
			return diagnostic_append(
				diagnostics,
				line,
				key,
				"expected a theme ID such as studio-dark or tide-light",
			)
		}
		base, clone_error := strings.clone(theme_api.legacy_base(value), s.allocator)
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
	case .Neovim:
		if !theme_api.neovim_colorscheme_valid(value) {
			return diagnostic_append(
				diagnostics,
				line,
				key,
				"expected a Neovim colorscheme such as tokyonight-day, or aiodev for the generated one",
			)
		}
		colorscheme, clone_error := strings.clone(value, s.allocator)
		if clone_error != nil {return clone_error}
		theme_api.neovim_destroy(theme.neovim, s.allocator)
		theme.neovim = {colorscheme = colorscheme}
	case .Color:
		token := parsed.token
		v, problem := theme_api.value_parse(token, value, .Strict)
		if problem != .None {
			message := theme_api.link_issue(token, value, problem)
			if message == "" {
				expected := theme_api.token_alpha(token) ? "#rrggbb or #rrggbbaa" : "#rrggbb"
				joined, message_error := strings.concatenate(
					{"invalid color \"", value, "\", expected ", expected},
					context.temp_allocator,
				)
				message = message_error != nil ? "invalid color" : joined
			}
			return diagnostic_append(diagnostics, line, key, message)
		}
		theme.colors[token] = v.color
		theme.linked -= {token}
		if v.linked {theme.linked += {token}; theme.target[token] = v.target}
		theme.overrides += {token}
	}
	return nil
}

// Adds the compiled-in default theme when no file or settings line defines its ID.
@(private, require_results)
theme_default_add :: proc(s: ^Settings) -> runtime.Allocator_Error {
	if theme_api.find(s.themes[:], theme_api.DEFAULT_ID) != nil {return nil}
	file, issue := theme_api.file_parse(theme_api.DEFAULT_TEXT)
	assert(issue == "", "invalid default theme")
	stored, add_error := custom_theme_add(s, theme_api.DEFAULT_ID)
	if add_error != nil || stored == nil {return add_error}
	return custom_theme_store(s, stored, file)
}

// Fills a slot from custom_theme_add with a parsed file theme, owning its temporary strings.
@(private, require_results)
custom_theme_store :: proc(
	s: ^Settings,
	stored: ^theme_api.Layer,
	file: theme_api.Layer,
) -> (
	err: runtime.Allocator_Error,
) {
	theme := file
	theme.id = stored.id
	theme.base, theme.name, theme.neovim = "", "", {}
	defer if err != nil {
		delete(theme.base, s.allocator)
		delete(theme.name, s.allocator)
		theme_api.neovim_destroy(theme.neovim, s.allocator)
	}
	if file.base != "" {theme.base = strings.clone(file.base, s.allocator) or_return}
	if file.name != "" {theme.name = strings.clone(file.name, s.allocator) or_return}
	if file.neovim.colorscheme != "" {theme.neovim = theme_api.neovim_clone(file.neovim, s.allocator) or_return}
	stored^ = theme
	return nil
}

// What the theme selector shows for a theme: its name, or its ID when it has none. Temporary.
theme_display_name :: proc(s: ^Settings, id: string) -> string {
	if custom := theme_api.find(s.themes[:], id); custom != nil && custom.name != "" {return custom.name}
	return id
}

// Resolves the active theme once per load, so the number of themes costs nothing per frame. An
// unknown name or base falls back to the default theme, and colors that follow each other in a loop
// to the default theme's colors; both are reported when the caller collects diagnostics.
@(private, require_results)
resolve_theme :: proc(s: ^Settings, diagnostics: ^[dynamic]Diagnostic) -> runtime.Allocator_Error {
	custom := theme_api.find(s.themes[:], s.theme.name)
	missing := custom == nil ? s.theme.name : ""
	for next, depth := custom, 0; next != nil && next.base != "" && depth < theme_api.BASE_DEPTH; depth += 1 {
		base := theme_api.find(s.themes[:], next.base)
		if base == nil {missing = next.base}
		next = base
	}
	loop := ""
	if custom == nil {
		s.active_theme = theme_api.default()
	} else {
		s.active_theme, loop = theme_api.resolve_checked(s.themes[:], custom)
	}
	if diagnostics != nil && missing != "" {
		message := fmt.tprintf("unknown theme \"%s\"; using %s", missing, theme_api.DEFAULT_ID)
		theme_line := setting_line(s, "theme.name")
		if err := diagnostic_append(diagnostics, theme_line, "theme.name", message); err != nil {
			return err
		}
	}
	if diagnostics != nil && loop != "" {
		message := fmt.tprintf("theme colors follow each other in a loop (%s); using the default colors", loop)
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
theme_base :: proc(s: ^Settings) -> theme_api.Theme {
	custom := theme_api.find(s.themes[:], s.theme.name)
	if custom == nil || custom.external {return s.active_theme}
	if base := theme_api.find(s.themes[:], custom.base); base != nil && base != custom {
		return theme_api.resolve(s.themes[:], base)
	}
	return theme_api.default()
}

// Whether the active theme is defined in the settings file and so may be edited in place.
theme_custom :: proc(s: ^Settings) -> bool {
	custom := theme_api.find(s.themes[:], s.theme.name)
	return custom != nil && !custom.external
}
