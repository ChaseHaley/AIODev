package settings

// One optional colour setting: where its override lives, which resolved colour it replaces, and
// whether an empty value follows the theme. Hex parsing, schema kinds and editor layout stay out.
Color_Entry :: struct {
	key, title, description: string,
	override_offset:         uintptr,
	resolved_offset:         uintptr,
	resolved_optional:       bool,
	theme_fallback:          bool,
}

COLOR_ENTRIES :: [?]Color_Entry {
	{
		"colors.foreground",
		"Foreground Color",
		"Shell foreground; empty follows the theme.",
		offset_of(Color_Overrides, foreground),
		offset_of(Color_Settings, foreground),
		false,
		true,
	},
	{
		"colors.background",
		"Background Color",
		"Shell background; empty follows the theme.",
		offset_of(Color_Overrides, background),
		offset_of(Color_Settings, background),
		false,
		true,
	},
	{
		"colors.cursor",
		"Cursor Color",
		"Cursor color.",
		offset_of(Color_Overrides, cursor),
		offset_of(Color_Settings, cursor),
		false,
		true,
	},
	{
		"colors.cursor_text",
		"Cursor Text Color",
		"Text under the block cursor.",
		offset_of(Color_Overrides, cursor_text),
		offset_of(Color_Settings, cursor_text),
		false,
		true,
	},
	{
		"colors.selection_background",
		"Selection Background",
		"Selection background color.",
		offset_of(Color_Overrides, selection_background),
		offset_of(Color_Settings, selection_background),
		false,
		true,
	},
	// Selection text is the exception: an empty value keeps the cell colors, so it has no theme
	// fallback and its resolved field stores the optional value itself.
	{
		"colors.selection_foreground",
		"Selection Text Color",
		"Selection foreground; empty preserves the cell color.",
		offset_of(Color_Overrides, selection_foreground),
		offset_of(Color_Settings, selection_foreground),
		true,
		false,
	},
	{
		"colors.search_foreground",
		"Search Match Text Color",
		"Text color of search matches.",
		offset_of(Color_Overrides, search_foreground),
		offset_of(Color_Settings, search_foreground),
		false,
		true,
	},
	{
		"colors.search_background",
		"Search Match Background",
		"Background of search matches.",
		offset_of(Color_Overrides, search_background),
		offset_of(Color_Settings, search_background),
		false,
		true,
	},
	{
		"colors.search_selected_background",
		"Selected Match Background",
		"Background of the selected search match.",
		offset_of(Color_Overrides, search_selected_background),
		offset_of(Color_Settings, search_selected_background),
		false,
		true,
	},
	{
		"colors.palette.0",
		"ANSI Black",
		"ANSI palette color 0.",
		offset_of(Color_Overrides, palette) + 0 * size_of(Maybe(Color)),
		offset_of(Color_Settings, palette) + 0 * size_of(Color),
		false,
		true,
	},
	{
		"colors.palette.1",
		"ANSI Red",
		"ANSI palette color 1.",
		offset_of(Color_Overrides, palette) + 1 * size_of(Maybe(Color)),
		offset_of(Color_Settings, palette) + 1 * size_of(Color),
		false,
		true,
	},
	{
		"colors.palette.2",
		"ANSI Green",
		"ANSI palette color 2.",
		offset_of(Color_Overrides, palette) + 2 * size_of(Maybe(Color)),
		offset_of(Color_Settings, palette) + 2 * size_of(Color),
		false,
		true,
	},
	{
		"colors.palette.3",
		"ANSI Yellow",
		"ANSI palette color 3.",
		offset_of(Color_Overrides, palette) + 3 * size_of(Maybe(Color)),
		offset_of(Color_Settings, palette) + 3 * size_of(Color),
		false,
		true,
	},
	{
		"colors.palette.4",
		"ANSI Blue",
		"ANSI palette color 4.",
		offset_of(Color_Overrides, palette) + 4 * size_of(Maybe(Color)),
		offset_of(Color_Settings, palette) + 4 * size_of(Color),
		false,
		true,
	},
	{
		"colors.palette.5",
		"ANSI Magenta",
		"ANSI palette color 5.",
		offset_of(Color_Overrides, palette) + 5 * size_of(Maybe(Color)),
		offset_of(Color_Settings, palette) + 5 * size_of(Color),
		false,
		true,
	},
	{
		"colors.palette.6",
		"ANSI Cyan",
		"ANSI palette color 6.",
		offset_of(Color_Overrides, palette) + 6 * size_of(Maybe(Color)),
		offset_of(Color_Settings, palette) + 6 * size_of(Color),
		false,
		true,
	},
	{
		"colors.palette.7",
		"ANSI White",
		"ANSI palette color 7.",
		offset_of(Color_Overrides, palette) + 7 * size_of(Maybe(Color)),
		offset_of(Color_Settings, palette) + 7 * size_of(Color),
		false,
		true,
	},
	{
		"colors.palette.8",
		"ANSI Bright Black",
		"ANSI palette color 8.",
		offset_of(Color_Overrides, palette) + 8 * size_of(Maybe(Color)),
		offset_of(Color_Settings, palette) + 8 * size_of(Color),
		false,
		true,
	},
	{
		"colors.palette.9",
		"ANSI Bright Red",
		"ANSI palette color 9.",
		offset_of(Color_Overrides, palette) + 9 * size_of(Maybe(Color)),
		offset_of(Color_Settings, palette) + 9 * size_of(Color),
		false,
		true,
	},
	{
		"colors.palette.10",
		"ANSI Bright Green",
		"ANSI palette color 10.",
		offset_of(Color_Overrides, palette) + 10 * size_of(Maybe(Color)),
		offset_of(Color_Settings, palette) + 10 * size_of(Color),
		false,
		true,
	},
	{
		"colors.palette.11",
		"ANSI Bright Yellow",
		"ANSI palette color 11.",
		offset_of(Color_Overrides, palette) + 11 * size_of(Maybe(Color)),
		offset_of(Color_Settings, palette) + 11 * size_of(Color),
		false,
		true,
	},
	{
		"colors.palette.12",
		"ANSI Bright Blue",
		"ANSI palette color 12.",
		offset_of(Color_Overrides, palette) + 12 * size_of(Maybe(Color)),
		offset_of(Color_Settings, palette) + 12 * size_of(Color),
		false,
		true,
	},
	{
		"colors.palette.13",
		"ANSI Bright Magenta",
		"ANSI palette color 13.",
		offset_of(Color_Overrides, palette) + 13 * size_of(Maybe(Color)),
		offset_of(Color_Settings, palette) + 13 * size_of(Color),
		false,
		true,
	},
	{
		"colors.palette.14",
		"ANSI Bright Cyan",
		"ANSI palette color 14.",
		offset_of(Color_Overrides, palette) + 14 * size_of(Maybe(Color)),
		offset_of(Color_Settings, palette) + 14 * size_of(Color),
		false,
		true,
	},
	{
		"colors.palette.15",
		"ANSI Bright White",
		"ANSI palette color 15.",
		offset_of(Color_Overrides, palette) + 15 * size_of(Maybe(Color)),
		offset_of(Color_Settings, palette) + 15 * size_of(Color),
		false,
		true,
	},
}

@(private)
resolve_colors :: proc(s: ^Settings) {
	s.colors = theme_resolve(s.theme).terminal
	overrides := uintptr(&s.color_overrides)
	colors := uintptr(&s.colors)
	for entry in COLOR_ENTRIES {
		override := (cast(^Maybe(Color))(overrides + entry.override_offset))^
		if entry.resolved_optional {
			(cast(^Maybe(Color))(colors + entry.resolved_offset))^ = override
		} else if color, ok := override.?; ok {
			(cast(^Color)(colors + entry.resolved_offset))^ = color
		}
	}
}

// The theme color that an empty optional color setting uses. Selection text has none: empty keeps cell colors.
theme_color :: proc(s: ^Settings, key: string) -> (Color, bool) {
	for entry in COLOR_ENTRIES {
		if entry.key != key {continue}
		if !entry.theme_fallback {return {}, false}
		terminal := theme_resolve(s.theme).terminal
		return (cast(^Color)(uintptr(&terminal) + entry.resolved_offset))^, true
	}
	return {}, false
}
