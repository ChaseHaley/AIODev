package settings

import "aio:colour"
import "base:runtime"
import "core:strings"

CUSTOM_THEME_PREFIX :: "theme.custom."
CUSTOM_THEME_LIMIT :: 64

// Custom IDs follow profile IDs and never shadow a built-in theme name.
theme_id_valid :: proc(id: string) -> bool {
	_, builtin := builtin_find(id)
	return !builtin && profile_id_valid(id)
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
	if !theme_id_valid(id) {
		return "", "Invalid theme ID. Use lowercase letters, digits, - and _, and no built-in theme name."
	}
	if field == "base" {
		if _, valid := builtin_parse(value); !valid {
			return "", "Expected a built-in theme variant such as studio-dark or tide-light."
		}
		return value, ""
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
			"invalid theme ID; use lowercase letters, digits, - and _, and no built-in theme name",
			.Unknown_Key,
		)
	}
	token, found := token_find(field)
	if field != "base" && !found {
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
	if field == "base" ? theme.base_set : token in theme.overrides {
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
		base, valid := builtin_parse(value)
		if !valid {
			return diagnostic_append(
				diagnostics,
				line,
				key,
				"expected a built-in theme variant such as studio-dark or tide-light",
			)
		}
		theme.base, theme.base_set = base, true
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

// Resolves the active theme once per load, so the number of themes costs nothing per frame. An
// unknown name falls back to Studio and is reported when the caller collects diagnostics.
@(private, require_results)
resolve_theme :: proc(s: ^Settings, diagnostics: ^[dynamic]Diagnostic) -> runtime.Allocator_Error {
	if name, builtin := builtin_find(s.theme.name); builtin {
		s.active_theme = builtin_theme({name, s.theme.mode})
	} else if custom := custom_theme_find(s, s.theme.name); custom != nil {
		s.active_theme = custom_theme_resolve(custom)
	} else {
		s.active_theme = builtin_theme({.Studio, s.theme.mode})
		if diagnostics != nil {
			message, message_error := strings.concatenate(
				{"unknown theme \"", s.theme.name, "\"; using studio"},
				context.temp_allocator,
			)
			if message_error != nil {message = "unknown theme; using studio"}
			if err := diagnostic_append(diagnostics, s.theme_line, "theme.name", message); err != nil {
				return err
			}
		}
	}
	s.colors = theme_terminal(s.active_theme)
	return nil
}

// The theme a custom theme or a built-in name falls back to for a color it does not override.
theme_base :: proc(s: ^Settings) -> Theme {
	if custom := custom_theme_find(s, s.theme.name); custom != nil {return builtin_theme(custom.base)}
	return s.active_theme
}

// Whether the active theme is defined in the settings file and so may be edited in place.
theme_custom :: proc(s: ^Settings) -> bool {return custom_theme_find(s, s.theme.name) != nil}
