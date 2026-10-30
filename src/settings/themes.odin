package settings

import "aio:colour"
import "core:strings"

// The fallback theme, compiled in so a missing or emptied themes folder still has one. It is also the
// root every theme's missing colors come from.
DEFAULT_THEME_ID :: "studio-dark"
@(private)
DEFAULT_THEME_TEXT :: #load("../../themes/studio-dark.theme.json", string)

// `name` is the active theme's ID: a theme file's or a custom theme's.
Theme_Settings :: struct {
	name: string,
}
Pane_Settings :: struct {
	gap, corner_radius:            int,
	show_headers:                  bool,
	confirm_shell_switch:          bool,
	minimum_columns, minimum_rows: int,
	focus_border, unfocused_dim:   int,
}
Theme_Color :: colour.Translucent

// Every color a theme owns, interface and terminal alike. Interface colors are semantic roles
// shared by every control that plays the role, never one per control.
Theme_Token :: enum {
	Window,
	Tab_Bar,
	Tab_Text,
	Tab_Active,
	Tab_Active_Text,
	Tab_Indicator,
	Rail_Active,
	Pane,
	Pane_Border,
	Pane_Focus,
	Surface,
	Text,
	Muted,
	Faint,
	Accent,
	Accent_Text,
	Border,
	Focus,
	Selection,
	Success,
	Warning,
	Danger,
	Info,
	Foreground,
	Background,
	Cursor,
	Cursor_Text,
	Selection_Background,
	Selection_Foreground,
	Search_Foreground,
	Search_Background,
	Search_Selected_Background,
	Palette_0,
	Palette_1,
	Palette_2,
	Palette_3,
	Palette_4,
	Palette_5,
	Palette_6,
	Palette_7,
	Palette_8,
	Palette_9,
	Palette_10,
	Palette_11,
	Palette_12,
	Palette_13,
	Palette_14,
	Palette_15,
}
FIRST_TERMINAL_TOKEN :: Theme_Token.Foreground

// Opaque colors are `#rrggbb`; translucent interface colors may add an alpha byte. Optional is the
// selection text color alone, whose empty value keeps each cell's own colors.
Token_Kind :: enum {
	Opaque,
	Translucent,
	Optional,
}
Token_Info :: struct {
	key, title, description: string,
	kind:                    Token_Kind,
}
THEME_TOKENS :: [Theme_Token]Token_Info {
	.Window = {"window", "Window Background", "Behind panes and around pane cards.", .Opaque},
	.Tab_Bar = {
		"tab_bar",
		"Tab Bar Background",
		"Title bar, horizontal tab strip and vertical tab rail.",
		.Opaque,
	},
	.Tab_Text = {"tab_text", "Tab Text", "Titles and close buttons of inactive tabs.", .Opaque},
	.Tab_Active = {
		"tab_active",
		"Active Tab Background",
		"The selected tab in the horizontal tab strip.",
		.Translucent,
	},
	.Tab_Active_Text = {"tab_active_text", "Active Tab Text", "Title of the selected tab.", .Opaque},
	.Tab_Indicator = {
		"tab_indicator",
		"Active Tab Indicator",
		"Underline or bar marking the selected tab.",
		.Opaque,
	},
	.Rail_Active = {
		"rail_active",
		"Active Vertical Tab Background",
		"The selected tab in the vertical tab rail.",
		.Translucent,
	},
	.Pane = {"pane", "Pane Background", "Settings and other non-terminal panes.", .Opaque},
	.Pane_Border = {
		"pane_border",
		"Pane Border",
		"Outline of unfocused panes and shared split dividers.",
		.Translucent,
	},
	.Pane_Focus = {"pane_focus", "Focused Pane Border", "Outline of the focused pane.", .Translucent},
	.Surface = {
		"surface",
		"Popup Background",
		"Menus, the command palette, notices and dialogs.",
		.Opaque,
	},
	.Text = {"text", "Text", "Primary interface text.", .Opaque},
	.Muted = {"muted", "Secondary Text", "Labels, descriptions and inactive controls.", .Opaque},
	.Faint = {"faint", "Hint Text", "Working directories, placeholders and hints.", .Opaque},
	.Accent = {"accent", "Accent", "Primary buttons, toggles, links and highlights.", .Opaque},
	.Accent_Text = {"accent_text", "Text on Accent", "Text drawn on accent fills.", .Opaque},
	.Border = {"border", "Border", "Hairlines around controls, popups and headers.", .Translucent},
	.Focus = {"focus", "Focus Ring", "Keyboard focus outlines.", .Translucent},
	.Selection = {
		"selection",
		"Selection Highlight",
		"Selected list items, pressed toggles and marked tabs.",
		.Translucent,
	},
	.Success = {"success", "Success", "Success notices and states.", .Opaque},
	.Warning = {"warning", "Warning", "Warning notices and states.", .Opaque},
	.Danger = {"danger", "Danger", "Errors and destructive actions.", .Opaque},
	.Info = {"info", "Information", "Informational notices.", .Opaque},
	.Foreground = {"foreground", "Foreground", "Default shell text.", .Opaque},
	.Background = {
		"background",
		"Background",
		"Default shell background and its pane card.",
		.Opaque,
	},
	.Cursor = {"cursor", "Cursor", "Cursor color.", .Opaque},
	.Cursor_Text = {"cursor_text", "Cursor Text", "Text under the block cursor.", .Opaque},
	.Selection_Background = {
		"selection_background",
		"Selection Background",
		"Background of selected text.",
		.Opaque,
	},
	.Selection_Foreground = {
		"selection_foreground",
		"Selection Text",
		"Selected text color; empty keeps each cell's own color.",
		.Optional,
	},
	.Search_Foreground = {"search_foreground", "Search Match Text", "Text of search matches.", .Opaque},
	.Search_Background = {
		"search_background",
		"Search Match Background",
		"Background of search matches.",
		.Opaque,
	},
	.Search_Selected_Background = {
		"search_selected_background",
		"Selected Match Background",
		"Background of the selected search match.",
		.Opaque,
	},
	.Palette_0 = {"palette.0", "ANSI Black", "ANSI palette color 0.", .Opaque},
	.Palette_1 = {"palette.1", "ANSI Red", "ANSI palette color 1.", .Opaque},
	.Palette_2 = {"palette.2", "ANSI Green", "ANSI palette color 2.", .Opaque},
	.Palette_3 = {"palette.3", "ANSI Yellow", "ANSI palette color 3.", .Opaque},
	.Palette_4 = {"palette.4", "ANSI Blue", "ANSI palette color 4.", .Opaque},
	.Palette_5 = {"palette.5", "ANSI Magenta", "ANSI palette color 5.", .Opaque},
	.Palette_6 = {"palette.6", "ANSI Cyan", "ANSI palette color 6.", .Opaque},
	.Palette_7 = {"palette.7", "ANSI White", "ANSI palette color 7.", .Opaque},
	.Palette_8 = {"palette.8", "ANSI Bright Black", "ANSI palette color 8.", .Opaque},
	.Palette_9 = {"palette.9", "ANSI Bright Red", "ANSI palette color 9.", .Opaque},
	.Palette_10 = {"palette.10", "ANSI Bright Green", "ANSI palette color 10.", .Opaque},
	.Palette_11 = {"palette.11", "ANSI Bright Yellow", "ANSI palette color 11.", .Opaque},
	.Palette_12 = {"palette.12", "ANSI Bright Blue", "ANSI palette color 12.", .Opaque},
	.Palette_13 = {"palette.13", "ANSI Bright Magenta", "ANSI palette color 13.", .Opaque},
	.Palette_14 = {"palette.14", "ANSI Bright Cyan", "ANSI palette color 14.", .Opaque},
	.Palette_15 = {"palette.15", "ANSI Bright White", "ANSI palette color 15.", .Opaque},
}

// A resolved theme. `light` follows the window background and `terminal_light` the shell
// background, so a custom theme needs no separate mode.
Theme :: struct {
	colors:                [Theme_Token]Theme_Color,
	light, terminal_light: bool,
}

// A theme from a file or the settings file: the colors it sets over its base, another theme's ID.
// Without a base, missing colors come from the default theme. `name` is free display text; the ID
// stays the stable key. `base_set` and `name_set` record explicit lines, so a repeated one is
// reported like any duplicate key. `external` marks a theme file.
Custom_Theme :: struct {
	id, base, name:     string,
	colors:             [Theme_Token]Theme_Color,
	overrides:          bit_set[Theme_Token],
	base_set, name_set: bool,
	external:           bool,
}

token_find :: proc(key: string) -> (Theme_Token, bool) {
	for info, token in THEME_TOKENS {
		if info.key == key {return token, true}
	}
	return {}, false
}

token_terminal :: proc(token: Theme_Token) -> bool {return token >= FIRST_TERMINAL_TOKEN}

// Applies a theme's overrides over its bases, nearest last. A missing base ends the chain at the
// default theme, and the depth bound ends a cycle.
custom_theme_resolve :: proc(s: ^Settings, c: ^Custom_Theme) -> Theme {
	chain: [THEME_BASE_DEPTH]^Custom_Theme
	count := 0
	for next := c; next != nil && count < len(chain); count += 1 {
		chain[count] = next
		next = next.base == "" || s == nil ? nil : custom_theme_find(s, next.base)
	}
	t := theme_default()
	for i := count - 1; i >= 0; i -= 1 {
		for token in chain[i].overrides {t.colors[token] = chain[i].colors[token]}
	}
	theme_finish(&t)
	return t
}

// The compiled-in theme, complete in every color.
theme_default :: proc() -> Theme {
	file, issue := theme_file_parse(DEFAULT_THEME_TEXT)
	assert(issue == "" && card(file.overrides) == len(Theme_Token), "invalid default theme")
	t := Theme {
		colors = file.colors,
	}
	theme_finish(&t)
	return t
}

// The theme one standalone file describes; its base is ignored. `issue` is temporary.
theme_from_text :: proc(text: string) -> (t: Theme, issue: string) {
	file: Custom_Theme
	file, issue = theme_file_parse(text)
	if issue != "" {return}
	return custom_theme_resolve(nil, &file), ""
}

// Light themes get paper hovers and stronger shell text contrast; brightness decides, not a flag.
@(private)
theme_finish :: proc(t: ^Theme) {
	t.light = color_light(t.colors[.Window].rgb)
	t.terminal_light = color_light(t.colors[.Background].rgb)
}

@(private)
color_light :: proc(c: Color) -> bool {
	return 0.2126 * f32(c.r) + 0.7152 * f32(c.g) + 0.0722 * f32(c.b) > 127.5
}

// The terminal colors a theme gives every session.
theme_terminal :: proc(t: Theme) -> Color_Settings {
	c := Color_Settings {
		foreground                 = t.colors[.Foreground].rgb,
		background                 = t.colors[.Background].rgb,
		cursor                     = t.colors[.Cursor].rgb,
		cursor_text                = t.colors[.Cursor_Text].rgb,
		selection_background       = t.colors[.Selection_Background].rgb,
		search_foreground          = t.colors[.Search_Foreground].rgb,
		search_background          = t.colors[.Search_Background].rgb,
		search_selected_background = t.colors[.Search_Selected_Background].rgb,
	}
	if selection := t.colors[.Selection_Foreground]; selection.a != 0 {
		c.selection_foreground = selection.rgb
	}
	for &value, i in c.palette {
		value = t.colors[Theme_Token(int(Theme_Token.Palette_0) + i)].rgb
	}
	return c
}

// The file text of one theme color: `#rrggbb`, `#rrggbbaa` for a translucent color with alpha, and
// empty for an unset optional color.
theme_color_text :: proc(token: Theme_Token, c: Theme_Color) -> string {
	tokens := THEME_TOKENS
	buffer: [colour.HEX_ALPHA_LENGTH]u8
	text: string
	switch tokens[token].kind {
	case .Optional:
		if c.a == 0 {return ""}
		text = colour.format(c.rgb, buffer[:])
	case .Opaque:
		text = colour.format(c.rgb, buffer[:])
	case .Translucent:
		text = colour.format_translucent(c, buffer[:])
	}
	return strings.clone(text, context.temp_allocator)
}

// Parses one theme color as its token allows; `ok` is false for text the token cannot take.
theme_color_parse :: proc(
	token: Theme_Token,
	text: string,
	policy: colour.Parse_Policy,
) -> (
	Theme_Color,
	bool,
) {
	tokens := THEME_TOKENS
	switch tokens[token].kind {
	case .Optional:
		if text == "" {return {}, true}
		c, ok, _ := colour.parse(text, policy)
		return {c.r, c.g, c.b, 255}, ok
	case .Opaque:
		c, ok, _ := colour.parse(text, policy)
		return {c.r, c.g, c.b, 255}, ok
	case .Translucent:
		return colour.parse_translucent(text, policy)
	}
	return {}, false
}
