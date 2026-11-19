package settings

import "aio:colour"
import "core:fmt"
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
	Scrollbar_Track,
	Scrollbar,
	Scrollbar_Hover,
	Scrollbar_Active,
	Code_Background,
	Diff_Added,
	Diff_Removed,
	Md_Paragraph_Text,
	Md_Paragraph_Background,
	Md_Strong_Text,
	Md_Strong_Background,
	Md_Emphasis_Text,
	Md_Emphasis_Background,
	Md_Strike_Text,
	Md_Strike_Background,
	Md_Markup_Text,
	Md_Markup_Background,
	Md_Heading_Text,
	Md_Heading_Background,
	Md_H1_Text,
	Md_H1_Background,
	Md_H2_Text,
	Md_H2_Background,
	Md_H3_Text,
	Md_H3_Background,
	Md_H4_Text,
	Md_H4_Background,
	Md_H5_Text,
	Md_H5_Background,
	Md_H6_Text,
	Md_H6_Background,
	Md_Link_Text,
	Md_Link_Background,
	Md_Wikilink_Text,
	Md_Wikilink_Background,
	Md_Inline_Code_Text,
	Md_Inline_Code_Background,
	Md_Code_Block_Text,
	Md_Code_Block_Background,
	Md_Quote_Text,
	Md_Quote_Background,
	Md_Quote_Bar,
	Md_List_Marker_Text,
	Md_List_Item_Background,
	Md_Task_Open_Background,
	Md_Task_Done_Background,
	Md_Task_Done_Text,
	Md_Rule,
	Md_Table_Header_Text,
	Md_Table_Header_Background,
	Md_Table_Cell_Text,
	Md_Table_Cell_Background,
	Md_Table_Border,
	Md_Property_Key_Text,
	Md_Property_Value_Text,
	Md_Properties_Background,
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
// selection text color alone, whose empty value keeps each cell's own colors. Clear colors, the
// Markdown element colors, take an alpha byte too and may be none (alpha 0), meaning no fill or the
// text color around; unlike an optional color, none is a value, so another color may follow them.
Token_Kind :: enum {
	Opaque,
	Translucent,
	Optional,
	Clear,
}
Token_Info :: struct {
	key, title, description: string,
	kind:                    Token_Kind,
}
THEME_TOKENS :: [Theme_Token]Token_Info {
	.Window = {"window", "Window background", "Behind panes and around pane cards.", .Opaque},
	.Tab_Bar = {
		"tab_bar",
		"Tab bar background",
		"Title bar, horizontal tab strip and vertical tab rail.",
		.Opaque,
	},
	.Tab_Text = {"tab_text", "Tab text", "Titles and close buttons of inactive tabs.", .Opaque},
	.Tab_Active = {
		"tab_active",
		"Active tab background",
		"The selected tab in the horizontal tab strip.",
		.Translucent,
	},
	.Tab_Active_Text = {"tab_active_text", "Active tab text", "Title of the selected tab.", .Opaque},
	.Tab_Indicator = {
		"tab_indicator",
		"Active tab indicator",
		"Underline or bar marking the selected tab.",
		.Opaque,
	},
	.Rail_Active = {
		"rail_active",
		"Active vertical tab background",
		"The selected tab in the vertical tab rail.",
		.Translucent,
	},
	.Pane = {"pane", "Pane background", "Settings and other non-terminal panes.", .Opaque},
	.Pane_Border = {
		"pane_border",
		"Pane border",
		"Outline of unfocused panes and shared split dividers.",
		.Translucent,
	},
	.Pane_Focus = {"pane_focus", "Focused pane border", "Outline of the focused pane.", .Translucent},
	.Surface = {
		"surface",
		"Popup background",
		"Menus, the everything palette, notices and dialogs.",
		.Opaque,
	},
	.Text = {"text", "Text", "Primary interface text.", .Opaque},
	.Muted = {"muted", "Secondary text", "Labels, descriptions and inactive controls.", .Opaque},
	.Faint = {"faint", "Hint text", "Working directories, placeholders and hints.", .Opaque},
	.Accent = {"accent", "Accent", "Primary buttons, toggles, links and highlights.", .Opaque},
	.Accent_Text = {"accent_text", "Text on accent", "Text drawn on accent fills.", .Opaque},
	.Border = {"border", "Border", "Hairlines around controls, popups and headers.", .Translucent},
	.Focus = {"focus", "Focus ring", "Keyboard focus outlines.", .Translucent},
	.Selection = {
		"selection",
		"Selection highlight",
		"Selected list items, pressed toggles and marked tabs.",
		.Translucent,
	},
	.Success = {"success", "Success", "Success notices and states.", .Opaque},
	.Warning = {"warning", "Warning", "Warning notices and states.", .Opaque},
	.Danger = {"danger", "Danger", "Errors and destructive actions.", .Opaque},
	.Info = {"info", "Information", "Informational notices.", .Opaque},
	.Scrollbar_Track = {
		"scrollbar_track",
		"Scrollbar track",
		"Scrollbar track while the pointer is over it.",
		.Translucent,
	},
	.Scrollbar = {"scrollbar", "Scrollbar", "Scrollbar thumb at rest.", .Translucent},
	.Scrollbar_Hover = {
		"scrollbar_hover",
		"Scrollbar hover",
		"Scrollbar thumb under the pointer.",
		.Translucent,
	},
	.Scrollbar_Active = {
		"scrollbar_active",
		"Scrollbar pressed",
		"Scrollbar thumb while dragged.",
		.Translucent,
	},
	.Code_Background = {
		"code_background",
		"Code background",
		"Code, inline code and frontmatter in Markdown panes.",
		.Translucent,
	},
	.Diff_Added = {
		"diff_added",
		"Added lines",
		"Lines a change added in Agent changes.",
		.Translucent,
	},
	.Diff_Removed = {
		"diff_removed",
		"Removed lines",
		"Lines a change removed in Agent changes.",
		.Translucent,
	},
	.Md_Paragraph_Text = {"markdown_paragraph_text", "Paragraph text", "Body text in Markdown panes.", .Clear},
	.Md_Paragraph_Background = {
		"markdown_paragraph_background",
		"Paragraph background",
		"Behind Markdown paragraphs; none shows the pane.",
		.Clear,
	},
	.Md_Strong_Text = {"markdown_strong_text", "Bold text", "Bold words; none keeps the text around.", .Clear},
	.Md_Strong_Background = {"markdown_strong_background", "Bold background", "Behind bold words.", .Clear},
	.Md_Emphasis_Text = {
		"markdown_emphasis_text",
		"Italic text",
		"Italic words; none keeps the text around.",
		.Clear,
	},
	.Md_Emphasis_Background = {
		"markdown_emphasis_background",
		"Italic background",
		"Behind italic words.",
		.Clear,
	},
	.Md_Strike_Text = {
		"markdown_strike_text",
		"Strikethrough text",
		"Struck-through words; none keeps the text around.",
		.Clear,
	},
	.Md_Strike_Background = {
		"markdown_strike_background",
		"Strikethrough background",
		"Behind struck-through words.",
		.Clear,
	},
	.Md_Markup_Text = {
		"markdown_markup_text",
		"Markup text",
		"Syntax such as # and ** on the line being edited.",
		.Clear,
	},
	.Md_Markup_Background = {
		"markdown_markup_background",
		"Markup background",
		"Behind the syntax on the line being edited.",
		.Clear,
	},
	.Md_Heading_Text = {
		"markdown_heading_text",
		"Heading text",
		"Every heading level without its own color; none keeps the text around.",
		.Clear,
	},
	.Md_Heading_Background = {
		"markdown_heading_background",
		"Heading background",
		"Behind every heading level without its own.",
		.Clear,
	},
	.Md_H1_Text = {"markdown_h1_text", "Heading 1 text", "Level 1 headings; follows Heading text.", .Clear},
	.Md_H1_Background = {
		"markdown_h1_background",
		"Heading 1 background",
		"Behind level 1 headings; follows Heading background.",
		.Clear,
	},
	.Md_H2_Text = {"markdown_h2_text", "Heading 2 text", "Level 2 headings; follows Heading text.", .Clear},
	.Md_H2_Background = {
		"markdown_h2_background",
		"Heading 2 background",
		"Behind level 2 headings; follows Heading background.",
		.Clear,
	},
	.Md_H3_Text = {"markdown_h3_text", "Heading 3 text", "Level 3 headings; follows Heading text.", .Clear},
	.Md_H3_Background = {
		"markdown_h3_background",
		"Heading 3 background",
		"Behind level 3 headings; follows Heading background.",
		.Clear,
	},
	.Md_H4_Text = {"markdown_h4_text", "Heading 4 text", "Level 4 headings; follows Heading text.", .Clear},
	.Md_H4_Background = {
		"markdown_h4_background",
		"Heading 4 background",
		"Behind level 4 headings; follows Heading background.",
		.Clear,
	},
	.Md_H5_Text = {"markdown_h5_text", "Heading 5 text", "Level 5 headings; follows Heading text.", .Clear},
	.Md_H5_Background = {
		"markdown_h5_background",
		"Heading 5 background",
		"Behind level 5 headings; follows Heading background.",
		.Clear,
	},
	.Md_H6_Text = {"markdown_h6_text", "Heading 6 text", "Level 6 headings; follows Heading text.", .Clear},
	.Md_H6_Background = {
		"markdown_h6_background",
		"Heading 6 background",
		"Behind level 6 headings; follows Heading background.",
		.Clear,
	},
	.Md_Link_Text = {"markdown_link_text", "Link text", "Links, autolinks and image descriptions.", .Clear},
	.Md_Link_Background = {"markdown_link_background", "Link background", "Behind links.", .Clear},
	.Md_Wikilink_Text = {
		"markdown_wikilink_text",
		"Wikilink text",
		"[[Note]] links and embeds; follows Link text.",
		.Clear,
	},
	.Md_Wikilink_Background = {
		"markdown_wikilink_background",
		"Wikilink background",
		"Behind [[Note]] links; follows Link background.",
		.Clear,
	},
	.Md_Inline_Code_Text = {
		"markdown_inline_code_text",
		"Inline code text",
		"Inline code; none keeps the text around.",
		.Clear,
	},
	.Md_Inline_Code_Background = {
		"markdown_inline_code_background",
		"Inline code background",
		"Behind inline code; follows Code background.",
		.Clear,
	},
	.Md_Code_Block_Text = {"markdown_code_block_text", "Code block text", "Text of fenced code blocks.", .Clear},
	.Md_Code_Block_Background = {
		"markdown_code_block_background",
		"Code block background",
		"Behind fenced code blocks; follows Code background.",
		.Clear,
	},
	.Md_Quote_Text = {"markdown_quote_text", "Quote text", "Text inside block quotes.", .Clear},
	.Md_Quote_Background = {"markdown_quote_background", "Quote background", "Behind block quotes.", .Clear},
	.Md_Quote_Bar = {"markdown_quote_bar", "Quote bar", "The bar beside a block quote.", .Clear},
	.Md_List_Marker_Text = {
		"markdown_list_marker_text",
		"List marker text",
		"Bullets and numbers of list items.",
		.Clear,
	},
	.Md_List_Item_Background = {
		"markdown_list_item_background",
		"List item background",
		"Behind list items.",
		.Clear,
	},
	.Md_Task_Open_Background = {
		"markdown_task_open_background",
		"Unchecked box",
		"The box of an unchecked task.",
		.Clear,
	},
	.Md_Task_Done_Background = {
		"markdown_task_done_background",
		"Checked box",
		"The box of a checked task.",
		.Clear,
	},
	.Md_Task_Done_Text = {"markdown_task_done_text", "Check mark", "The tick in a checked task's box.", .Clear},
	.Md_Rule = {"markdown_rule", "Horizontal rule", "Horizontal rules in Markdown panes.", .Clear},
	.Md_Table_Header_Text = {
		"markdown_table_header_text",
		"Table header text",
		"Header cells of Markdown tables.",
		.Clear,
	},
	.Md_Table_Header_Background = {
		"markdown_table_header_background",
		"Table header background",
		"Behind the header row of Markdown tables.",
		.Clear,
	},
	.Md_Table_Cell_Text = {"markdown_table_cell_text", "Table text", "Body cells of Markdown tables.", .Clear},
	.Md_Table_Cell_Background = {
		"markdown_table_cell_background",
		"Table background",
		"Behind the body rows of Markdown tables.",
		.Clear,
	},
	.Md_Table_Border = {
		"markdown_table_border",
		"Table border",
		"The rules between Markdown table rows.",
		.Clear,
	},
	.Md_Property_Key_Text = {
		"markdown_property_key_text",
		"Property name",
		"Names in a note's frontmatter properties.",
		.Clear,
	},
	.Md_Property_Value_Text = {
		"markdown_property_value_text",
		"Property value",
		"Values in a note's frontmatter properties.",
		.Clear,
	},
	.Md_Properties_Background = {
		"markdown_properties_background",
		"Properties background",
		"Behind a note's frontmatter properties; follows Code background.",
		.Clear,
	},
	.Foreground = {"foreground", "Foreground", "Default shell text.", .Opaque},
	.Background = {
		"background",
		"Background",
		"Default shell background and its pane card.",
		.Opaque,
	},
	.Cursor = {
		"cursor",
		"Cursor",
		"Color of the cursor in terminals and text fields; empty follows the accent.",
		.Optional,
	},
	.Cursor_Text = {
		"cursor_text",
		"Cursor text",
		"Text under a block cursor; empty follows the text on accent.",
		.Optional,
	},
	.Selection_Background = {
		"selection_background",
		"Selection background",
		"Background of selected text.",
		.Opaque,
	},
	.Selection_Foreground = {
		"selection_foreground",
		"Selection text",
		"Selected text color; empty keeps each cell's own color.",
		.Optional,
	},
	.Search_Foreground = {"search_foreground", "Search match text", "Text of search matches.", .Opaque},
	.Search_Background = {
		"search_background",
		"Search match background",
		"Background of search matches.",
		.Opaque,
	},
	.Search_Selected_Background = {
		"search_selected_background",
		"Selected match background",
		"Background of the selected search match.",
		.Opaque,
	},
	.Palette_0 = {"palette.0", "ANSI black", "ANSI palette color 0.", .Opaque},
	.Palette_1 = {"palette.1", "ANSI red", "ANSI palette color 1.", .Opaque},
	.Palette_2 = {"palette.2", "ANSI green", "ANSI palette color 2.", .Opaque},
	.Palette_3 = {"palette.3", "ANSI yellow", "ANSI palette color 3.", .Opaque},
	.Palette_4 = {"palette.4", "ANSI blue", "ANSI palette color 4.", .Opaque},
	.Palette_5 = {"palette.5", "ANSI magenta", "ANSI palette color 5.", .Opaque},
	.Palette_6 = {"palette.6", "ANSI cyan", "ANSI palette color 6.", .Opaque},
	.Palette_7 = {"palette.7", "ANSI white", "ANSI palette color 7.", .Opaque},
	.Palette_8 = {"palette.8", "ANSI bright black", "ANSI palette color 8.", .Opaque},
	.Palette_9 = {"palette.9", "ANSI bright red", "ANSI palette color 9.", .Opaque},
	.Palette_10 = {"palette.10", "ANSI bright green", "ANSI palette color 10.", .Opaque},
	.Palette_11 = {"palette.11", "ANSI bright yellow", "ANSI palette color 11.", .Opaque},
	.Palette_12 = {"palette.12", "ANSI bright blue", "ANSI palette color 12.", .Opaque},
	.Palette_13 = {"palette.13", "ANSI bright magenta", "ANSI palette color 13.", .Opaque},
	.Palette_14 = {"palette.14", "ANSI bright cyan", "ANSI palette color 14.", .Opaque},
	.Palette_15 = {"palette.15", "ANSI bright white", "ANSI palette color 15.", .Opaque},
}

// A resolved theme. `light` follows the window background and `terminal_light` the shell
// background, so a custom theme needs no separate mode. A color in `linked` follows the color
// `target` names; its entry in `colors` already holds the color it ends at.
Theme :: struct {
	colors:                [Theme_Token]Theme_Color,
	linked:                bit_set[Theme_Token],
	target:                [Theme_Token]Theme_Token,
	light, terminal_light: bool,
}

// A theme from a file or the settings file: the colors it sets over its base, another theme's ID.
// Without a base, missing colors come from the default theme. `name` is free display text; the ID
// stays the stable key. `base_set` and `name_set` record explicit lines, so a repeated one is
// reported like any duplicate key. `external` marks a theme file. A color in `linked` holds no
// color of its own: it follows the color `target` names, wherever that ends up in the resolved theme.
Custom_Theme :: struct {
	id, base, name:     string,
	colors:             [Theme_Token]Theme_Color,
	overrides:          bit_set[Theme_Token],
	linked:             bit_set[Theme_Token],
	target:             [Theme_Token]Theme_Token,
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

// Whether a color may carry an alpha byte: a translucent interface color or a Clear one.
token_alpha :: proc(token: Theme_Token) -> bool {
	tokens := THEME_TOKENS
	return tokens[token].kind == .Translucent || tokens[token].kind == .Clear
}

// Applies a theme's overrides over its bases, nearest last, then resolves the colors that follow
// another color. A missing base ends the chain at the default theme, and the depth bound ends a
// cycle.
custom_theme_resolve :: proc(s: ^Settings, c: ^Custom_Theme) -> Theme {
	t, _ := custom_theme_resolve_checked(s, c)
	return t
}

// custom_theme_resolve, also naming the loop of followed colors that the theme could not resolve,
// such as "accent -> cursor -> accent"; empty when there is none. The colors that were part of or
// led into the loop take the default theme's color. The loop text is temporary.
custom_theme_resolve_checked :: proc(s: ^Settings, c: ^Custom_Theme) -> (t: Theme, loop: string) {
	chain: [THEME_BASE_DEPTH]^Custom_Theme
	count := 0
	for next := c; next != nil && count < len(chain); count += 1 {
		chain[count] = next
		next = next.base == "" || s == nil ? nil : custom_theme_find(s, next.base)
	}
	// The default theme already follows the default links, which a layer may replace.
	t = theme_default()
	for i := count - 1; i >= 0; i -= 1 {
		layer := chain[i]
		for token in layer.overrides {
			t.colors[token] = layer.colors[token]
			t.linked -= {token}
			if token in layer.linked {t.linked += {token}; t.target[token] = layer.target[token]}
		}
	}
	loop = theme_links_resolve(&t)
	theme_finish(&t)
	return
}

// Gives every followed color the color it ends at, once, so nothing follows a link per frame. A color
// whose links never end falls back to the default theme's own color and stops following.
@(private)
theme_links_resolve :: proc(t: ^Theme) -> (loop: string) {
	if t.linked == {} {return ""}
	tokens := THEME_TOKENS
	resolved: [Theme_Token]Theme_Color
	refused: bit_set[Theme_Token]
	for token in t.linked {
		end, reached := token, false
		for _ in 0 ..< len(Theme_Token) {
			if end not_in t.linked {reached = true; break}
			end = t.target[end]
		}
		if !reached {refused += {token}; continue}
		resolved[token] = t.colors[end]
		if tokens[token].kind != .Translucent && tokens[token].kind != .Clear {resolved[token].a = 255}
	}
	if refused != {} {
		loop = theme_loop_text(t.linked, &t.target)
		fallback := theme_default()
		for token in refused {resolved[token] = fallback.colors[token]}
	}
	for token in t.linked {t.colors[token] = resolved[token]}
	t.linked -= refused
	return
}

// Whether `token` may follow `target`: another color that always has a value. The optional colors
// may be empty, so nothing follows them. A Clear color may be none, which only another Clear color
// can follow, since the rest have no such value.
theme_link_valid :: proc(token, target: Theme_Token) -> bool {
	tokens := THEME_TOKENS
	if token == target || tokens[target].kind == .Optional {return false}
	return tokens[target].kind != .Clear || tokens[token].kind == .Clear
}

// A color that a loop of followed colors passes through, or false when every link ends.
@(private)
theme_links_loop :: proc(
	linked: bit_set[Theme_Token],
	target: ^[Theme_Token]Theme_Token,
) -> (
	on: Theme_Token,
	found: bool,
) {
	for token in linked {
		at := token
		for _ in 0 ..< len(Theme_Token) {
			if at not_in linked {break}
			at = target[at]
		}
		if at in linked {return at, true}
	}
	return
}

// "accent -> cursor -> accent" for the first loop of followed colors, starting at the loop's first
// color in token order; empty when there is none. The result is temporary.
@(private)
theme_loop_text :: proc(linked: bit_set[Theme_Token], target: ^[Theme_Token]Theme_Token) -> string {
	on, found := theme_links_loop(linked, target)
	if !found {return ""}
	start := on
	for at := target[on]; at != on; at = target[at] {start = min(start, at)}
	tokens := THEME_TOKENS
	b := strings.builder_make(context.temp_allocator)
	at := start
	for {
		strings.write_string(&b, tokens[at].key)
		strings.write_string(&b, " -> ")
		at = target[at]
		if at == start {break}
	}
	strings.write_string(&b, tokens[start].key)
	return strings.to_string(b)
}

// The colors a token follows until a theme says otherwise, so the Markdown element colors draw what
// the shared colors do and move with them in every theme. Theme files need not list them. A token with
// no entry holds a concrete color; a Clear one with none is none.
@(rodata)
TOKEN_DEFAULT_LINKS := #partial [Theme_Token]Maybe(Theme_Token) {
	.Md_Paragraph_Text         = .Text,
	.Md_Markup_Text            = .Muted,
	.Md_H1_Text                = .Md_Heading_Text,
	.Md_H1_Background          = .Md_Heading_Background,
	.Md_H2_Text                = .Md_Heading_Text,
	.Md_H2_Background          = .Md_Heading_Background,
	.Md_H3_Text                = .Md_Heading_Text,
	.Md_H3_Background          = .Md_Heading_Background,
	.Md_H4_Text                = .Md_Heading_Text,
	.Md_H4_Background          = .Md_Heading_Background,
	.Md_H5_Text                = .Md_Heading_Text,
	.Md_H5_Background          = .Md_Heading_Background,
	.Md_H6_Text                = .Md_Heading_Text,
	.Md_H6_Background          = .Md_Heading_Background,
	.Md_Link_Text              = .Accent,
	.Md_Wikilink_Text          = .Md_Link_Text,
	.Md_Wikilink_Background    = .Md_Link_Background,
	.Md_Inline_Code_Background = .Code_Background,
	.Md_Code_Block_Text        = .Text,
	.Md_Code_Block_Background  = .Code_Background,
	.Md_Quote_Text             = .Muted,
	.Md_Quote_Bar              = .Border,
	.Md_List_Marker_Text       = .Muted,
	.Md_Task_Open_Background   = .Border,
	.Md_Task_Done_Background   = .Accent,
	.Md_Task_Done_Text         = .Accent_Text,
	.Md_Rule                   = .Border,
	.Md_Table_Header_Text      = .Text,
	.Md_Table_Cell_Text        = .Text,
	.Md_Table_Border           = .Border,
	.Md_Property_Key_Text      = .Muted,
	.Md_Property_Value_Text    = .Text,
	.Md_Properties_Background  = .Code_Background,
}

// Marks every token with a default link as following it, over the colors `t` holds.
@(private)
theme_default_links :: proc(t: ^Theme) {
	for follows, token in TOKEN_DEFAULT_LINKS {
		if target, has := follows.?; has {t.linked += {token}; t.target[token] = target}
	}
}

// Whether a theme file may leave `token` out: it follows a default link or may be none.
@(private)
theme_file_optional :: proc(token: Theme_Token) -> bool {
	tokens := THEME_TOKENS
	return TOKEN_DEFAULT_LINKS[token] != nil || tokens[token].kind == .Clear
}

// The compiled-in theme, complete in every color: the file's own colors are concrete, and the colors it
// leaves out follow their default links, resolved here, as they do in every other theme.
theme_default :: proc() -> Theme {
	file, issue := theme_file_parse(DEFAULT_THEME_TEXT)
	complete := issue == "" && file.linked == {}
	for token in Theme_Token {complete &&= token in file.overrides || theme_file_optional(token)}
	assert(complete, "invalid default theme")
	t := Theme {
		colors = file.colors,
	}
	theme_default_links(&t)
	_ = theme_links_resolve(&t)
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

// The color of the cursor in every surface: the theme's own, or its accent when it sets none.
theme_cursor :: proc(t: Theme) -> Color {
	if c := t.colors[.Cursor]; c.a != 0 {return c.rgb}
	return t.colors[.Accent].rgb
}

// The text under a block cursor: the theme's own, or the text on accent when it sets none.
theme_cursor_text :: proc(t: Theme) -> Color {
	if c := t.colors[.Cursor_Text]; c.a != 0 {return c.rgb}
	return t.colors[.Accent_Text].rgb
}

// The terminal colors a theme gives every session.
theme_terminal :: proc(t: Theme) -> Color_Settings {
	c := Color_Settings {
		foreground                 = t.colors[.Foreground].rgb,
		background                 = t.colors[.Background].rgb,
		cursor                     = theme_cursor(t),
		cursor_text                = theme_cursor_text(t),
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

// How a theme file or settings line writes a Clear color that is none.
NONE_COLOR_TEXT :: "#00000000"

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
	case .Clear:
		// None is written out, so a line that says "none" is not a line that is missing.
		if c.a == 0 {return NONE_COLOR_TEXT}
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
	case .Clear:
		if text == "" {return {}, true}
		value, ok := colour.parse_translucent(text, policy)
		if value.a == 0 {value = {}}
		return value, ok
	}
	return {}, false
}

// What a theme file or settings line holds for one color: a concrete color, or the color it follows.
Theme_Value :: struct {
	color:  Theme_Color,
	target: Theme_Token,
	linked: bool,
}

Theme_Value_Problem :: enum {
	None,
	// Neither a color nor a theme color's key.
	Invalid,
	// Reads as a theme color's key, but no theme color has it.
	Unknown_Link,
	Self_Link,
	// The target may be empty, so it has no color to follow.
	Optional_Link,
}

// Parses one color's value: the key of another theme color, such as accent, or a color as the token
// allows.
theme_value_parse :: proc(
	token: Theme_Token,
	text: string,
	policy: colour.Parse_Policy,
) -> (
	value: Theme_Value,
	problem: Theme_Value_Problem,
) {
	if target, found := token_find(strings.trim_space(text)); found {
		if target == token {return {}, .Self_Link}
		if !theme_link_valid(token, target) {return {}, .Optional_Link}
		return {target = target, linked = true}, .None
	}
	color, valid := theme_color_parse(token, text, policy)
	if valid {return {color = color}, .None}
	for i in 0 ..< len(text) {
		c := text[i]
		keyed := (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '.'
		if !keyed || (i == 0 && (c < 'a' || c > 'z')) {return {}, .Invalid}
	}
	return {}, len(text) > 0 ? .Unknown_Link : .Invalid
}

// Why a followed color was refused, as a clause. Temporary; empty for a problem of the color itself.
@(private)
theme_link_issue :: proc(token: Theme_Token, text: string, problem: Theme_Value_Problem) -> string {
	tokens := THEME_TOKENS
	switch problem {
	case .Unknown_Link:
		return fmt.tprintf(
			"no theme color is named \"%s\"; expected #rrggbb or the key of a theme color such as accent",
			text,
		)
	case .Self_Link:
		return fmt.tprintf("%s cannot follow itself", tokens[token].key)
	case .Optional_Link:
		return fmt.tprintf("%s may be empty, so no color can follow it", text)
	case .Invalid, .None:
	}
	return ""
}

// The file text of one theme color: the key of the color it follows, or its own color as
// theme_color_text writes it.
theme_value_text :: proc(token: Theme_Token, value: Theme_Value) -> string {
	tokens := THEME_TOKENS
	if value.linked {return tokens[value.target].key}
	return theme_color_text(token, value.color)
}
