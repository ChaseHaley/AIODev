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
	Markdown_Text,
	Markdown_Headings,
	Markdown_Code,
	Markdown_Blocks,
	Markdown_Tables,
	Diff,
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
	.Accent           = {"Accent & focus", "Interface"},
	.Tabs             = {"Tab colors", "Interface"},
	.Pane_Borders     = {"Pane borders", "Interface"},
	.Status           = {"Status", "Interface"},
	.Scrollbar        = {"Scrollbar", "Interface"},
	.Markdown_Text     = {"Markdown text", "Interface"},
	.Markdown_Headings = {"Markdown headings", "Interface"},
	.Markdown_Code     = {"Markdown links and code", "Interface"},
	.Markdown_Blocks   = {"Markdown blocks", "Interface"},
	.Markdown_Tables   = {"Markdown tables", "Interface"},
	.Diff             = {"Diff colors", "Interface"},
	.Shell_Text       = {"Shell text", "Terminal"},
	.Selection_Search = {"Selection & search", "Terminal"},
	.Ansi             = {"ANSI 0–7", "Terminal"},
	.Ansi_Bright      = {"ANSI bright 8–15", "Terminal"},
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
	{.Md_Paragraph_Text, .Markdown_Text, "Paragraph"},
	{.Md_Paragraph_Background, .Markdown_Text, "Paragraph fill"},
	{.Md_Strong_Text, .Markdown_Text, "Bold"},
	{.Md_Strong_Background, .Markdown_Text, "Bold fill"},
	{.Md_Emphasis_Text, .Markdown_Text, "Italic"},
	{.Md_Emphasis_Background, .Markdown_Text, "Italic fill"},
	{.Md_Strike_Text, .Markdown_Text, "Strike"},
	{.Md_Strike_Background, .Markdown_Text, "Strike fill"},
	{.Md_Markup_Text, .Markdown_Text, "Markup"},
	{.Md_Markup_Background, .Markdown_Text, "Markup fill"},
	{.Md_Heading_Text, .Markdown_Headings, "Headings"},
	{.Md_Heading_Background, .Markdown_Headings, "Headings fill"},
	{.Md_H1_Text, .Markdown_Headings, "H1"},
	{.Md_H1_Background, .Markdown_Headings, "H1 fill"},
	{.Md_H2_Text, .Markdown_Headings, "H2"},
	{.Md_H2_Background, .Markdown_Headings, "H2 fill"},
	{.Md_H3_Text, .Markdown_Headings, "H3"},
	{.Md_H3_Background, .Markdown_Headings, "H3 fill"},
	{.Md_H4_Text, .Markdown_Headings, "H4"},
	{.Md_H4_Background, .Markdown_Headings, "H4 fill"},
	{.Md_H5_Text, .Markdown_Headings, "H5"},
	{.Md_H5_Background, .Markdown_Headings, "H5 fill"},
	{.Md_H6_Text, .Markdown_Headings, "H6"},
	{.Md_H6_Background, .Markdown_Headings, "H6 fill"},
	{.Code_Background, .Markdown_Code, "Code"},
	{.Md_Link_Text, .Markdown_Code, "Link"},
	{.Md_Link_Background, .Markdown_Code, "Link fill"},
	{.Md_Wikilink_Text, .Markdown_Code, "Wikilink"},
	{.Md_Wikilink_Background, .Markdown_Code, "Wikilink fill"},
	{.Md_Inline_Code_Text, .Markdown_Code, "Inline code"},
	{.Md_Inline_Code_Background, .Markdown_Code, "Inline fill"},
	{.Md_Code_Block_Text, .Markdown_Code, "Block code"},
	{.Md_Code_Block_Background, .Markdown_Code, "Block fill"},
	{.Md_Quote_Text, .Markdown_Blocks, "Quote"},
	{.Md_Quote_Background, .Markdown_Blocks, "Quote fill"},
	{.Md_Quote_Bar, .Markdown_Blocks, "Quote bar"},
	{.Md_List_Marker_Text, .Markdown_Blocks, "List marker"},
	{.Md_List_Item_Background, .Markdown_Blocks, "Item fill"},
	{.Md_Task_Open_Background, .Markdown_Blocks, "Open box"},
	{.Md_Task_Done_Background, .Markdown_Blocks, "Done box"},
	{.Md_Task_Done_Text, .Markdown_Blocks, "Check mark"},
	{.Md_Rule, .Markdown_Blocks, "Rule"},
	{.Md_Table_Header_Text, .Markdown_Tables, "Header"},
	{.Md_Table_Header_Background, .Markdown_Tables, "Header fill"},
	{.Md_Table_Cell_Text, .Markdown_Tables, "Cell"},
	{.Md_Table_Cell_Background, .Markdown_Tables, "Cell fill"},
	{.Md_Table_Border, .Markdown_Tables, "Table border"},
	{.Md_Property_Key_Text, .Markdown_Tables, "Prop. name"},
	{.Md_Property_Value_Text, .Markdown_Tables, "Prop. value"},
	{.Md_Properties_Background, .Markdown_Tables, "Prop. fill"},
	{.Diff_Added, .Diff, "Added lines"},
	{.Diff_Removed, .Diff, "Removed lines"},
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

// A color group's place in the Colors section, after Manage theme.
@(private)
settings_color_group_area :: proc(title: string) -> (rank: int, found: bool) {
	for info, group in COLOR_GROUPS {
		if info.title == title {return len(SETTINGS_GROUP_AREAS) + int(group), true}
	}
	return
}

// The key of the color `token` follows in `t`, or "" when it holds its own color.
@(private)
settings_color_link :: proc(t: settings.Theme, token: settings.Theme_Token) -> string {
	tokens := settings.THEME_TOKENS
	return token in t.linked ? tokens[t.target[token]].key : ""
}

// The text a color row shows: a Clear color that is none is empty, as an optional one is.
@(private)
settings_color_value :: proc(token: settings.Theme_Token, c: settings.Theme_Color) -> string {
	tokens := settings.THEME_TOKENS
	if tokens[token].kind == .Clear && c.a == 0 {return ""}
	return settings.theme_color_text(token, c)
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
			ref           = info.key,
			link          = settings_color_link(s.active_theme, tile.token),
			default_link  = settings_color_link(base, tile.token),
			value         = settings_color_value(tile.token, s.active_theme.colors[tile.token]),
			default_value = settings_color_value(tile.token, base.colors[tile.token]),
			kind          = info.kind == .Optional || info.kind == .Clear ? .Optional_Color : .Color,
			clear         = info.kind == .Clear,
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
		colors := strings.builder_make(context.temp_allocator)
		for row in p.rows {
			if row.action != .Theme_Color {continue}
			if strings.builder_len(colors) > 0 {strings.write_byte(&colors, ';')}
			fmt.sbprintf(&colors, "%s=%s", row.ref, row.value)
			if row.link != "" {fmt.sbprintf(&colors, ">%s", row.link)}
		}
		state_text(r, "settings.board.colors", strings.to_string(colors))
		for part in ui.Board_Part {
			name := fmt.tprintf("settings.board.%s", strings.to_lower(fmt.tprint(part), context.temp_allocator))
			state_rect(r, name, ui.color_board_rect(p, page, part))
		}
	}
}
