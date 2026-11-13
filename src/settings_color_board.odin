package main

import "aio:settings"
import "aio:ui"
import "core:fmt"
import "core:strings"

// The state report below uses strings only in control builds.
_ :: strings

// The Colors section's swatch board: the role group and short tile label of every theme color, and
// the card the board's inspector shows for the active theme.

@(private)
Color_Group :: enum {
	Surfaces,
	Text,
	Accent,
	Tabs,
	Pane_Borders,
	Status,
	Scrollbar,
	Shell_Text,
	Selection_Search,
	Ansi,
	Ansi_Bright,
}

// Group titles are page groups, so they differ from General's Tabs and Panes.
@(private, rodata)
COLOR_GROUPS := [Color_Group]struct {
	title, side: string,
} {
	.Surfaces         = {"Surfaces", "Interface"},
	.Text             = {"Text", "Interface"},
	.Accent           = {"Accent & Focus", "Interface"},
	.Tabs             = {"Tab Colors", "Interface"},
	.Pane_Borders     = {"Pane Borders", "Interface"},
	.Status           = {"Status", "Interface"},
	.Scrollbar        = {"Scrollbar", "Interface"},
	.Shell_Text       = {"Shell Text", "Terminal"},
	.Selection_Search = {"Selection & Search", "Terminal"},
	.Ansi             = {"ANSI 0–7", "Terminal"},
	.Ansi_Bright      = {"ANSI Bright 8–15", "Terminal"},
}

@(private)
Color_Tile :: struct {
	token: settings.Theme_Token,
	group: Color_Group,
	label: string,
}

// Every theme color once, in board order.
@(private, rodata)
COLOR_TILES := [?]Color_Tile {
	{.Window, .Surfaces, "Window"},
	{.Tab_Bar, .Surfaces, "Tab bar"},
	{.Pane, .Surfaces, "Pane"},
	{.Surface, .Surfaces, "Popup"},
	{.Text, .Text, "Text"},
	{.Muted, .Text, "Secondary"},
	{.Faint, .Text, "Hint"},
	{.Accent_Text, .Text, "On accent"},
	{.Accent, .Accent, "Accent"},
	{.Focus, .Accent, "Focus ring"},
	{.Selection, .Accent, "Selection"},
	{.Border, .Accent, "Border"},
	{.Tab_Text, .Tabs, "Tab text"},
	{.Tab_Active, .Tabs, "Active tab"},
	{.Tab_Active_Text, .Tabs, "Active tab text"},
	{.Tab_Indicator, .Tabs, "Tab indicator"},
	{.Rail_Active, .Tabs, "Active rail tab"},
	{.Pane_Border, .Pane_Borders, "Pane border"},
	{.Pane_Focus, .Pane_Borders, "Focused pane"},
	{.Success, .Status, "Success"},
	{.Warning, .Status, "Warning"},
	{.Danger, .Status, "Danger"},
	{.Info, .Status, "Info"},
	{.Scrollbar_Track, .Scrollbar, "Track"},
	{.Scrollbar, .Scrollbar, "Thumb"},
	{.Scrollbar_Hover, .Scrollbar, "Thumb hover"},
	{.Scrollbar_Active, .Scrollbar, "Thumb pressed"},
	{.Foreground, .Shell_Text, "Foreground"},
	{.Background, .Shell_Text, "Background"},
	{.Cursor, .Shell_Text, "Cursor"},
	{.Cursor_Text, .Shell_Text, "Cursor text"},
	{.Selection_Background, .Selection_Search, "Selection"},
	{.Selection_Foreground, .Selection_Search, "Selection text"},
	{.Search_Foreground, .Selection_Search, "Match text"},
	{.Search_Background, .Selection_Search, "Match"},
	{.Search_Selected_Background, .Selection_Search, "Current match"},
	{.Palette_0, .Ansi, "Black"},
	{.Palette_1, .Ansi, "Red"},
	{.Palette_2, .Ansi, "Green"},
	{.Palette_3, .Ansi, "Yellow"},
	{.Palette_4, .Ansi, "Blue"},
	{.Palette_5, .Ansi, "Magenta"},
	{.Palette_6, .Ansi, "Cyan"},
	{.Palette_7, .Ansi, "White"},
	{.Palette_8, .Ansi_Bright, "Bright black"},
	{.Palette_9, .Ansi_Bright, "Bright red"},
	{.Palette_10, .Ansi_Bright, "Bright green"},
	{.Palette_11, .Ansi_Bright, "Bright yellow"},
	{.Palette_12, .Ansi_Bright, "Bright blue"},
	{.Palette_13, .Ansi_Bright, "Bright magenta"},
	{.Palette_14, .Ansi_Bright, "Bright cyan"},
	{.Palette_15, .Ansi_Bright, "Bright white"},
}
#assert(len(COLOR_TILES) == len(settings.Theme_Token))

// A color group's place in the Colors section, after Manage Theme.
@(private)
settings_color_group_area :: proc(title: string) -> (rank: int, found: bool) {
	for info, group in COLOR_GROUPS {
		if info.title == title {return len(SETTINGS_GROUP_AREAS) + int(group), true}
	}
	return
}

// One row per theme color in board order, each showing the value in effect; a custom theme's Reset
// returns a color to its base theme. Then the board's groups and the card for the active theme.
@(private, require_results)
settings_add_color_rows :: proc(p: ^ui.Editor, s: ^settings.Settings) -> bool {
	base := settings.theme_base(s)
	tokens := settings.THEME_TOKENS
	for tile in COLOR_TILES {
		info := tokens[tile.token]
		row := ui.Editor_Row {
			key           = fmt.tprintf("%s%s", SETTINGS_COLOR_PREFIX, info.key),
			title         = info.title,
			description   = info.description,
			badge         = tile.label,
			value         = settings.theme_color_text(tile.token, s.active_theme.colors[tile.token]),
			default_value = settings.theme_color_text(tile.token, base.colors[tile.token]),
			kind          = info.kind == .Optional ? .Optional_Color : .Color,
			action        = .Theme_Color,
		}
		if ui.editor_add(p, row, COLOR_GROUPS[tile.group].title) != nil {return false}
	}
	for info in COLOR_GROUPS {
		if !ui.editor_board_group(p, info.title, info.side) {return false}
	}
	return ui.editor_board_card(p, settings_color_card(s)) == nil
}

// The theme the board edits: a custom theme with its base, or a theme file that a change copies.
@(private)
settings_color_card :: proc(s: ^settings.Settings) -> ui.Board_Card {
	name := settings.theme_display_name(s, s.theme.name)
	if !settings.theme_custom(s) {
		return {
			title = name,
			badge = "Theme file",
			detail = fmt.tprintf("%s · read-only", s.theme.name),
			note = "Changing a color saves a custom copy and switches to it.",
			base = fmt.tprintf("Theme file · %s", name),
		}
	}
	custom := settings.custom_theme_find(s, s.theme.name)
	base_id := custom.base != "" ? custom.base : settings.DEFAULT_THEME_ID
	base := settings.theme_display_name(s, base_id)
	return {
		title = name,
		badge = "Custom",
		detail = fmt.tprintf("%s · based on %s", custom.id, base),
		base = fmt.tprintf("Base · %s", base),
		custom = true,
	}
}

when AIO_CONTROL {
	// The board's verification keys: whether it shows, the color in its inspector, its height in page
	// lines and DIPs, where each tile and inspector part is drawn, and whether it still moves.
	settings_board_state_report :: proc(r: ^State_Report, p: ^ui.Editor, page: ui.Editor_Layout) {
		shown := ui.color_board_shown(p)
		state_value(r, "settings.board.shown", shown)
		state_text(r, "settings.board.key", ui.color_board_token_key(p))
		state_value(r, "settings.board.control", p.board.control)
		state_value(r, "settings.board.animating", ui.color_board_animating(p))
		lines := shown ? ui.color_board_lines(p, page) : 0
		state_value(r, "settings.board.lines", lines)
		height := f32(lines) * page.row_height / max(page.scale, 0.001)
		state_valuef(r, "settings.board.height", "%g", height)
		tiles := strings.builder_make(context.temp_allocator)
		card := strings.builder_make(context.temp_allocator)
		if shown {
			for item, index in p.items {
				if item.row < 0 {continue}
				row := &p.rows[item.row]
				places := row.action == .Theme_Color ? &tiles : &card
				rect := ui.editor_row_parts(p, page, index).row
				if strings.builder_len(places^) > 0 {strings.write_byte(places, ';')}
				fmt.sbprintf(places, "%s@%g,%g,%g,%g", row.key, rect.x, rect.y, rect.width, rect.height)
			}
		}
		state_text(r, "settings.board.tiles", strings.to_string(tiles))
		state_text(r, "settings.board.card", strings.to_string(card))
		for part in ui.Board_Part {
			name := fmt.tprintf("settings.board.%s", strings.to_lower(fmt.tprint(part), context.temp_allocator))
			state_rect(r, name, ui.color_board_rect(p, page, part))
		}
	}
}
