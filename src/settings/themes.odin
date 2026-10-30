package settings

import "aio:colour"
import "core:math"
import "core:strings"

Theme_Name :: enum int {
	Studio,
	Tide,
	Ember,
	Tokyo_Night,
	Tokyo_Storm,
	Tokyo_Moon,
}
Theme_Mode :: enum int {
	Dark,
	Light,
}
THEME_NAMES :: [Theme_Name]string {
	.Studio = "studio",
	.Tide   = "tide",
	.Ember  = "ember",
	.Tokyo_Night = "tokyonight-night",
	.Tokyo_Storm = "tokyonight-storm",
	.Tokyo_Moon = "tokyonight-moon",
}
THEME_MODES :: [Theme_Mode]string {
	.Dark  = "dark",
	.Light = "light",
}
// One shipped palette variant. Custom themes start from one and override single colors.
Builtin_Theme :: struct {
	name: Theme_Name,
	mode: Theme_Mode,
}
// `name` is the active theme's ID: a built-in name, whose variant `mode` picks, or a custom ID.
Theme_Settings :: struct {
	name: string,
	mode: Theme_Mode,
}
Pane_Settings :: struct {
	gap, corner_radius:            int,
	show_headers:                  bool,
	confirm_shell_switch:          bool,
	minimum_columns, minimum_rows: int,
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

// A theme defined in the settings file: a built-in variant plus the colors it overrides.
// `base_set` records an explicit base line, so a repeated one is reported like any duplicate key.
Custom_Theme :: struct {
	id:        string,
	base:      Builtin_Theme,
	colors:    [Theme_Token]Theme_Color,
	overrides: bit_set[Theme_Token],
	base_set:  bool,
}

@(private)
Builtin_Colors :: struct {
	window, chrome, pane, raised, text, muted, faint, accent, accent_text: Color,
	success, warning, danger, info:                                        Color,
	terminal:                                                              Color_Settings,
}

token_find :: proc(key: string) -> (Theme_Token, bool) {
	for info, token in THEME_TOKENS {
		if info.key == key {return token, true}
	}
	return {}, false
}

token_terminal :: proc(token: Theme_Token) -> bool {return token >= FIRST_TERMINAL_TOKEN}

builtin_find :: proc(name: string) -> (Theme_Name, bool) {
	for text, n in THEME_NAMES {
		if text == name {return n, true}
	}
	return {}, false
}

// The `studio-dark` form a custom theme's base uses.
builtin_id :: proc(b: Builtin_Theme, allocator := context.temp_allocator) -> string {
	names, modes := THEME_NAMES, THEME_MODES
	id, _ := strings.concatenate({names[b.name], "-", modes[b.mode]}, allocator)
	return id
}

builtin_parse :: proc(text: string) -> (Builtin_Theme, bool) {
	names, modes := THEME_NAMES, THEME_MODES
	for name, n in names {
		for mode, m in modes {
			if len(text) == len(name) + 1 + len(mode) &&
			   strings.has_prefix(text, name) &&
			   text[len(name)] == '-' &&
			   text[len(name) + 1:] == mode {return {n, m}, true}
		}
	}
	return {}, false
}

builtin_theme :: proc(b: Builtin_Theme) -> Theme {
	opaque :: proc(c: Color) -> Theme_Color {return {c.r, c.g, c.b, 255}}
	alpha :: proc(c: Color, a: f32) -> Theme_Color {return {c.r, c.g, c.b, u8(math.round(a * 255))}}
	p := builtin_colors(b)
	light := b.mode == .Light
	t: Theme
	t.colors = #partial {
		.Window                     = opaque(p.window),
		.Tab_Bar                    = opaque(p.chrome),
		.Tab_Text                   = opaque(p.muted),
		.Tab_Active                 = opaque(p.pane),
		.Tab_Active_Text            = opaque(p.text),
		.Tab_Indicator              = opaque(p.accent),
		.Rail_Active                = alpha(p.accent, light ? 0.10 : 0.14),
		.Pane                       = opaque(p.pane),
		.Pane_Border                = alpha(p.text, light ? 0.09 : 0.08),
		.Pane_Focus                 = alpha(p.accent, 0.50),
		.Surface                    = opaque(p.raised),
		.Text                       = opaque(p.text),
		.Muted                      = opaque(p.muted),
		.Faint                      = opaque(p.faint),
		.Accent                     = opaque(p.accent),
		.Accent_Text                = opaque(p.accent_text),
		.Border                     = alpha(p.text, light ? 0.09 : 0.08),
		.Focus                      = alpha(p.accent, 0.50),
		.Selection                  = alpha(p.accent, light ? 0.10 : 0.14),
		.Success                    = opaque(p.success),
		.Warning                    = opaque(p.warning),
		.Danger                     = opaque(p.danger),
		.Info                       = opaque(p.info),
		.Foreground                 = opaque(p.terminal.foreground),
		.Background                 = opaque(p.terminal.background),
		.Cursor                     = opaque(p.terminal.cursor),
		.Cursor_Text                = opaque(p.terminal.cursor_text),
		.Selection_Background       = opaque(p.terminal.selection_background),
		.Search_Foreground          = opaque(p.terminal.search_foreground),
		.Search_Background          = opaque(p.terminal.search_background),
		.Search_Selected_Background = opaque(p.terminal.search_selected_background),
	}
	for c, i in p.terminal.palette {
		t.colors[Theme_Token(int(Theme_Token.Palette_0) + i)] = opaque(c)
	}
	theme_finish(&t)
	return t
}

custom_theme_resolve :: proc(c: ^Custom_Theme) -> Theme {
	t := builtin_theme(c.base)
	for token in c.overrides {t.colors[token] = c.colors[token]}
	theme_finish(&t)
	return t
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

@(private)
builtin_colors :: proc(b: Builtin_Theme) -> Builtin_Colors {
	if b.name >= .Tokyo_Night {return tokyo_colors(b)}
	@(static, rodata)
	themes := #partial [Theme_Name][Theme_Mode]Builtin_Colors {
		.Studio = {
			.Dark = {
				window = {0x0c, 0x0c, 0x0e},
				chrome = {0x0c, 0x0c, 0x0e},
				pane = {0x12, 0x12, 0x15},
				raised = {0x1b, 0x1b, 0x20},
				text = {0xec, 0xec, 0xf1},
				muted = {0x9a, 0x9a, 0xa5},
				faint = {0x83, 0x83, 0x8d},
				accent = {0xa1, 0x94, 0xff},
				accent_text = {0x14, 0x0e, 0x33},
				success = {0x7b, 0xd5, 0x9c},
				warning = {0xe8, 0xc5, 0x6b},
				danger = {0xff, 0x7c, 0x87},
				info = {0x7f, 0xb6, 0xff},
				terminal = {
					foreground = {0xec, 0xec, 0xf1},
					background = {0x12, 0x12, 0x15},
					cursor = {0xec, 0xec, 0xf1},
					cursor_text = {0x12, 0x12, 0x15},
					selection_background = {0x2c, 0x28, 0x47},
					search_foreground = {0x12, 0x12, 0x15},
					search_background = {0xe8, 0xc5, 0x6b},
					search_selected_background = {0xa1, 0x94, 0xff},
					palette = {
						{0x1b, 0x1b, 0x20},
						{0xff, 0x7c, 0x87},
						{0x7b, 0xd5, 0x9c},
						{0xe8, 0xc5, 0x6b},
						{0x7f, 0xb6, 0xff},
						{0xe0, 0x9b, 0xf0},
						{0x6f, 0xd6, 0xd6},
						{0xc9, 0xc9, 0xd1},
						{0x6e, 0x6e, 0x79},
						{0xff, 0x9a, 0xa3},
						{0x9b, 0xe3, 0xb5},
						{0xf2, 0xd6, 0x8c},
						{0xa3, 0xcb, 0xff},
						{0xeb, 0xb7, 0xf5},
						{0x95, 0xe3, 0xe3},
						{0xf4, 0xf4, 0xf7},
					},
				},
			},
			.Light = {
				window = {0xf5, 0xf5, 0xf7},
				chrome = {0xef, 0xef, 0xf2},
				pane = {0xff, 0xff, 0xff},
				raised = {0xff, 0xff, 0xff},
				text = {0x18, 0x18, 0x1b},
				muted = {0x52, 0x52, 0x5c},
				faint = {0x6b, 0x6b, 0x75},
				accent = {0x5b, 0x45, 0xe0},
				accent_text = {0xff, 0xff, 0xff},
				success = {0x1f, 0x7a, 0x3b},
				warning = {0x82, 0x60, 0x0a},
				danger = {0xc0, 0x2f, 0x3f},
				info = {0x1d, 0x5f, 0xc4},
				terminal = {
					foreground = {0x18, 0x18, 0x1b},
					background = {0xff, 0xff, 0xff},
					cursor = {0x18, 0x18, 0x1b},
					cursor_text = {0xff, 0xff, 0xff},
					selection_background = {0xe4, 0xe0, 0xfb},
					search_foreground = {0x18, 0x18, 0x1b},
					search_background = {0xf6, 0xdc, 0x8f},
					search_selected_background = {0xc4, 0xb9, 0xff},
					palette = {
						{0x3f, 0x3f, 0x46},
						{0xc0, 0x2f, 0x3f},
						{0x1f, 0x7a, 0x3b},
						{0x82, 0x60, 0x0a},
						{0x1d, 0x5f, 0xc4},
						{0x8b, 0x3a, 0xa8},
						{0x0e, 0x76, 0x76},
						{0xd4, 0xd4, 0xda},
						{0x6e, 0x6e, 0x78},
						{0xb0, 0x24, 0x35},
						{0x16, 0x69, 0x2f},
						{0x6f, 0x52, 0x07},
						{0x1a, 0x52, 0xa8},
						{0x78, 0x2f, 0x92},
						{0x0b, 0x64, 0x64},
						{0xf4, 0xf4, 0xf7},
					},
				},
			},
		},
		.Tide = {
			.Dark = {
				window = {0x0e, 0x14, 0x19},
				chrome = {0x11, 0x19, 0x20},
				pane = {0x15, 0x1e, 0x26},
				raised = {0x1c, 0x27, 0x31},
				text = {0xe0, 0xe8, 0xef},
				muted = {0x97, 0xa7, 0xb5},
				faint = {0x80, 0x8f, 0x9b},
				accent = {0x4f, 0xcd, 0xb3},
				accent_text = {0x04, 0x20, 0x1a},
				success = {0x80, 0xd4, 0x8c},
				warning = {0xe6, 0xc6, 0x6c},
				danger = {0xf2, 0x82, 0x82},
				info = {0x72, 0xb8, 0xff},
				terminal = {
					foreground = {0xe0, 0xe8, 0xef},
					background = {0x15, 0x1e, 0x26},
					cursor = {0xe0, 0xe8, 0xef},
					cursor_text = {0x15, 0x1e, 0x26},
					selection_background = {0x1d, 0x3b, 0x3d},
					search_foreground = {0x15, 0x1e, 0x26},
					search_background = {0xe6, 0xc6, 0x6c},
					search_selected_background = {0x4f, 0xcd, 0xb3},
					palette = {
						{0x1c, 0x27, 0x31},
						{0xf2, 0x82, 0x82},
						{0x80, 0xd4, 0x8c},
						{0xe6, 0xc6, 0x6c},
						{0x72, 0xb8, 0xff},
						{0xc4, 0x9c, 0xf0},
						{0x5f, 0xd0, 0xe0},
						{0xc3, 0xce, 0xd8},
						{0x6c, 0x7c, 0x89},
						{0xff, 0x9d, 0x9d},
						{0xa0, 0xe2, 0xaa},
						{0xf0, 0xd6, 0x8f},
						{0x9a, 0xcd, 0xff},
						{0xd6, 0xb8, 0xf6},
						{0x8c, 0xdf, 0xeb},
						{0xf2, 0xf6, 0xf9},
					},
				},
			},
			.Light = {
				window = {0xe7, 0xed, 0xf1},
				chrome = {0xe2, 0xe9, 0xee},
				pane = {0xf8, 0xfa, 0xfc},
				raised = {0xff, 0xff, 0xff},
				text = {0x14, 0x21, 0x2b},
				muted = {0x44, 0x53, 0x5f},
				faint = {0x5a, 0x69, 0x76},
				accent = {0x0b, 0x81, 0x70},
				accent_text = {0xff, 0xff, 0xff},
				success = {0x2b, 0x7a, 0x37},
				warning = {0x7f, 0x5d, 0x0b},
				danger = {0xb5, 0x3a, 0x3a},
				info = {0x1f, 0x61, 0xb0},
				terminal = {
					foreground = {0x14, 0x21, 0x2b},
					background = {0xf8, 0xfa, 0xfc},
					cursor = {0x14, 0x21, 0x2b},
					cursor_text = {0xf8, 0xfa, 0xfc},
					selection_background = {0xd5, 0xec, 0xe8},
					search_foreground = {0x14, 0x21, 0x2b},
					search_background = {0xf3, 0xd9, 0x8c},
					search_selected_background = {0x9f, 0xdc, 0xcf},
					palette = {
						{0x3a, 0x47, 0x52},
						{0xb5, 0x3a, 0x3a},
						{0x2b, 0x7a, 0x37},
						{0x7f, 0x5d, 0x0b},
						{0x1f, 0x61, 0xb0},
						{0x74, 0x42, 0xb0},
						{0x0f, 0x70, 0x82},
						{0xd3, 0xdb, 0xe1},
						{0x64, 0x73, 0x80},
						{0xa1, 0x2f, 0x2f},
						{0x22, 0x69, 0x2e},
						{0x6c, 0x4f, 0x08},
						{0x1a, 0x52, 0x96},
						{0x63, 0x37, 0x9a},
						{0x0b, 0x5f, 0x6f},
						{0xf8, 0xfa, 0xfc},
					},
				},
			},
		},
		.Ember = {
			.Dark = {
				window = {0x17, 0x14, 0x12},
				chrome = {0x1c, 0x18, 0x15},
				pane = {0x22, 0x1d, 0x1a},
				raised = {0x2c, 0x26, 0x23},
				text = {0xee, 0xe6, 0xde},
				muted = {0xab, 0x9d, 0x90},
				faint = {0x99, 0x8c, 0x80},
				accent = {0xf0, 0xa3, 0x5e},
				accent_text = {0x1d, 0x12, 0x09},
				success = {0xa6, 0xcf, 0x8a},
				warning = {0xe9, 0xc4, 0x6a},
				danger = {0xef, 0x7d, 0x6f},
				info = {0x93, 0xbc, 0xe4},
				terminal = {
					foreground = {0xee, 0xe6, 0xde},
					background = {0x22, 0x1d, 0x1a},
					cursor = {0xee, 0xe6, 0xde},
					cursor_text = {0x22, 0x1d, 0x1a},
					selection_background = {0x47, 0x33, 0x1f},
					search_foreground = {0x22, 0x1d, 0x1a},
					search_background = {0xe9, 0xc4, 0x6a},
					search_selected_background = {0xf0, 0xa3, 0x5e},
					palette = {
						{0x2c, 0x26, 0x23},
						{0xef, 0x7d, 0x6f},
						{0xa6, 0xcf, 0x8a},
						{0xe9, 0xc4, 0x6a},
						{0x93, 0xbc, 0xe4},
						{0xd7, 0xa0, 0xdb},
						{0x8c, 0xd0, 0xc4},
						{0xd6, 0xcc, 0xc2},
						{0x7d, 0x70, 0x65},
						{0xff, 0x9a, 0x8d},
						{0xbf, 0xe0, 0xa6},
						{0xf3, 0xd5, 0x8e},
						{0xb3, 0xd1, 0xee},
						{0xe6, 0xbd, 0xe9},
						{0xab, 0xdf, 0xd6},
						{0xf7, 0xf1, 0xeb},
					},
				},
			},
			.Light = {
				window = {0xec, 0xe5, 0xde},
				chrome = {0xe7, 0xdf, 0xd7},
				pane = {0xfb, 0xf8, 0xf5},
				raised = {0xff, 0xff, 0xff},
				text = {0x2b, 0x22, 0x1b},
				muted = {0x5c, 0x4f, 0x45},
				faint = {0x6f, 0x60, 0x55},
				accent = {0xa8, 0x54, 0x0f},
				accent_text = {0xff, 0xff, 0xff},
				success = {0x3d, 0x7a, 0x2b},
				warning = {0x86, 0x60, 0x0f},
				danger = {0xb3, 0x3e, 0x2e},
				info = {0x2d, 0x62, 0x98},
				terminal = {
					foreground = {0x2b, 0x22, 0x1b},
					background = {0xfb, 0xf8, 0xf5},
					cursor = {0x2b, 0x22, 0x1b},
					cursor_text = {0xfb, 0xf8, 0xf5},
					selection_background = {0xf1, 0xdc, 0xc8},
					search_foreground = {0x2b, 0x22, 0x1b},
					search_background = {0xf3, 0xd6, 0x8d},
					search_selected_background = {0xf0, 0xb9, 0x8a},
					palette = {
						{0x4a, 0x3f, 0x37},
						{0xb3, 0x3e, 0x2e},
						{0x3d, 0x7a, 0x2b},
						{0x86, 0x60, 0x0f},
						{0x2d, 0x62, 0x98},
						{0x8e, 0x4a, 0x94},
						{0x22, 0x76, 0x6a},
						{0xdd, 0xd3, 0xc9},
						{0x76, 0x67, 0x5b},
						{0x9e, 0x34, 0x24},
						{0x33, 0x6a, 0x23},
						{0x71, 0x50, 0x0b},
						{0x25, 0x53, 0x83},
						{0x7a, 0x3e, 0x80},
						{0x1b, 0x63, 0x59},
						{0xfb, 0xf8, 0xf5},
					},
				},
			},
		},
	}
	return themes[b.name][b.mode]
}
