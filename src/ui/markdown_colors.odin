package ui

import "cosmos:colour"
import "cosmos:render"
import "aio:settings"

// The colours of Markdown's elements, resolved from the theme once whenever it changes, so drawing a
// page looks nothing up beyond one entry per run. A zero colour (alpha 0) is none: as a background it
// draws nothing, and as text it keeps the colour of the text around.

// An element's text and the fill behind it.
Markdown_Pair :: struct {
	text, background: render.Color,
}

Markdown_Colors :: struct {
	paragraph, strong, emphasis, strike, markup:                         Markdown_Pair,
	// H1 to H6, each already following the shared heading colours unless the theme says otherwise.
	headings:                                                            [6]Markdown_Pair,
	link, wikilink, inline_code, code_block:                             Markdown_Pair,
	quote, table_header, table_cell:                                     Markdown_Pair,
	// A list's marker and the band behind an item.
	list:                                                                Markdown_Pair,
	// A note's frontmatter: the values and the panel behind them, and the names.
	properties, property_key:                                            Markdown_Pair,
	quote_bar, rule, table_border, task_open, task_done, task_check:     render.Color,
	// Where a chain of text colours ends when each of them is none.
	fallback:                                                            render.Color,
}

markdown_colors_from :: proc(t: settings.Theme) -> Markdown_Colors {
	c :: proc(t: settings.Theme, token: settings.Theme_Token) -> render.Color {
		value := t.colors[token]
		if value.a == 0 {return {}}
		return colour.rgba(value.rgb, f32(value.a) / 255)
	}
	pair :: proc(t: settings.Theme, text, background: settings.Theme_Token) -> Markdown_Pair {
		return {c(t, text), c(t, background)}
	}
	m := Markdown_Colors {
		paragraph = pair(t, .Md_Paragraph_Text, .Md_Paragraph_Background),
		strong = pair(t, .Md_Strong_Text, .Md_Strong_Background),
		emphasis = pair(t, .Md_Emphasis_Text, .Md_Emphasis_Background),
		strike = pair(t, .Md_Strike_Text, .Md_Strike_Background),
		markup = pair(t, .Md_Markup_Text, .Md_Markup_Background),
		link = pair(t, .Md_Link_Text, .Md_Link_Background),
		wikilink = pair(t, .Md_Wikilink_Text, .Md_Wikilink_Background),
		inline_code = pair(t, .Md_Inline_Code_Text, .Md_Inline_Code_Background),
		code_block = pair(t, .Md_Code_Block_Text, .Md_Code_Block_Background),
		quote = pair(t, .Md_Quote_Text, .Md_Quote_Background),
		list = pair(t, .Md_List_Marker_Text, .Md_List_Item_Background),
		table_header = pair(t, .Md_Table_Header_Text, .Md_Table_Header_Background),
		table_cell = pair(t, .Md_Table_Cell_Text, .Md_Table_Cell_Background),
		properties = pair(t, .Md_Property_Value_Text, .Md_Properties_Background),
		property_key = {text = c(t, .Md_Property_Key_Text)},
		quote_bar = c(t, .Md_Quote_Bar),
		rule = c(t, .Md_Rule),
		table_border = c(t, .Md_Table_Border),
		task_open = c(t, .Md_Task_Open_Background),
		task_done = c(t, .Md_Task_Done_Background),
		task_check = c(t, .Md_Task_Done_Text),
		fallback = c(t, .Text),
	}
	m.headings = {
		pair(t, .Md_H1_Text, .Md_H1_Background),
		pair(t, .Md_H2_Text, .Md_H2_Background),
		pair(t, .Md_H3_Text, .Md_H3_Background),
		pair(t, .Md_H4_Text, .Md_H4_Background),
		pair(t, .Md_H5_Text, .Md_H5_Background),
		pair(t, .Md_H6_Text, .Md_H6_Background),
	}
	return m
}
