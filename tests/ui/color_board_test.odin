package ui_test

import "aio:platform"
import "aio:render"
import "aio:ui"
import "core:strings"
import "core:testing"
import "core:time"

@(rodata, private)
board_sections := [?]string{"General", "Colors"}

// A page whose second section is a color board: a card group, then two groups of tiles under
// different side headings. Accent differs from its base, and the pane and background share a value.
@(private)
board_fixture :: proc(t: ^testing.T, p: ^ui.Editor) -> ui.Editor_Layout {
	rows := [?]struct {
		row:   ui.Editor_Row,
		group: string,
	} {
		{{key = "pane.gap", title = "Pane Gap", value = "5", default_value = "5", kind = .Integer, maximum = 24},
			"Panes"},
		{{key = "theme.display_name", title = "Theme Name", value = "Mine", kind = .Text, action = .Theme_Name},
			"Manage Theme"},
		{{key = "theme.duplicate", title = "Save as New Theme", value = "Save Copy", kind = .Action,
			action = .Theme_Duplicate}, "Manage Theme"},
		{{key = "theme.delete", title = "Delete Theme", value = "Delete…", kind = .Action,
			action = .Theme_Delete}, "Manage Theme"},
		{{key = "colors.window", title = "Window Background", badge = "Window", value = "#0c0c0e",
			default_value = "#0c0c0e", kind = .Color, action = .Theme_Color}, "Surfaces"},
		{{key = "colors.pane", title = "Pane Background", badge = "Pane", value = "#121215",
			default_value = "#121215", kind = .Color, action = .Theme_Color}, "Surfaces"},
		{{key = "colors.surface", title = "Popup Background", badge = "Popup", value = "#1b1b20",
			default_value = "#1b1b20", kind = .Color, action = .Theme_Color}, "Surfaces"},
		{{key = "colors.accent", title = "Accent", badge = "Highlight", value = "#ff8800",
			default_value = "#a194ff", kind = .Color, action = .Theme_Color}, "Surfaces"},
		{{key = "colors.background", title = "Background", badge = "Background", value = "#121215",
			default_value = "#121215", kind = .Color, action = .Theme_Color}, "Shell Text"},
		{{key = "colors.cursor", title = "Cursor", description = "Cursor color.", badge = "Cursor",
			value = "#ececf1", default_value = "#ececf1", kind = .Color, action = .Theme_Color}, "Shell Text"},
		{{key = "colors.selection_foreground", title = "Selection Text", badge = "Selection text",
			kind = .Optional_Color, action = .Theme_Color}, "Shell Text"},
	}
	for r in rows {testing.expect_value(t, ui.editor_add(p, r.row, r.group), nil)}
	for &group in p.groups {
		switch group.title {
		case "Manage Theme":
			group.section, group.rank = 1, 0
		case "Surfaces":
			group.section, group.rank = 1, 1
		case "Shell Text":
			group.section, group.rank = 1, 2
		}
	}
	testing.expect(t, ui.editor_board_group(p, "Surfaces", "Interface"))
	testing.expect(t, ui.editor_board_group(p, "Shell Text", "Terminal"))
	card := ui.Board_Card{title = "Mine", badge = "Custom", detail = "mine", base = "Base · Studio Dark", custom = true}
	testing.expect_value(t, ui.editor_board_card(p, card), nil)
	p.sections = board_sections[:]
	l := ui.editor_layout({0, 40, 1200, 900}, 1, true)
	ui.editor_filter(p)
	ui.editor_fit(p, l)
	ui.editor_section_show(p, 1)
	ui.editor_fit(p, l)
	return l
}

@(private)
board_item :: proc(p: ^ui.Editor, key: string) -> int {
	for item, index in p.items {
		if item.row >= 0 && p.rows[item.row].key == key {return index}
	}
	return -1
}

@(private)
board_press :: proc(p: ^ui.Editor, l: ui.Editor_Layout, r: render.Rect) -> ui.Editor_Outcome {
	x, y := center(r)
	return ui.editor_press(p, l, nil, x, y, false)
}

@(test)
color_board_shows_its_section_and_search_lists_its_colors_as_rows :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	board_fixture(t, &p)
	testing.expect(t, ui.color_board_shown(&p))
	testing.expect_value(t, ui.editor_row(&p).key, "colors.window")
	testing.expect_value(t, ui.color_board_token_key(&p), "colors.window")

	// A search spans every section, lists matching colors as rows and counts them on their tab.
	ui.editor_text(&p, "cursor")
	testing.expect(t, !ui.color_board_shown(&p))
	keys := visible_keys(&p)
	if testing.expect_value(t, len(keys), 2) {testing.expect_value(t, keys[1], "colors.cursor")}
	testing.expect_value(t, ui.editor_section_counts(&p)[1], 1)
	testing.expect_value(t, ui.editor_row(&p).key, "colors.cursor")
	// Tile labels are searched too.
	ui.editor_key(&p, key({key = .Escape}))
	ui.editor_text(&p, "highlight")
	testing.expect_value(t, ui.editor_row(&p).key, "colors.accent")

	// Leaving the search returns to the board on the color it chose.
	ui.editor_key(&p, key({key = .Escape}))
	testing.expect(t, ui.color_board_shown(&p))
	testing.expect_value(t, ui.editor_row(&p).key, "colors.accent")

	// A reveal from another section lands on the color's tile, as a palette jump does.
	ui.editor_section_show(&p, 0)
	testing.expect(t, !ui.color_board_shown(&p))
	testing.expect(t, ui.editor_reveal(&p, ui.Reveal_Row{"colors.cursor"}))
	testing.expect(t, ui.color_board_shown(&p))
	testing.expect_value(t, ui.color_board_token_key(&p), "colors.cursor")

	// The outline lands on a group's first tile.
	ui.editor_jump(&p, 1)
	testing.expect_value(t, ui.editor_row(&p).key, "colors.window")
	ui.editor_jump(&p, 2)
	testing.expect_value(t, ui.editor_row(&p).key, "colors.background")
	testing.expect_value(t, p.groups[ui.editor_active_group(&p)].title, "Shell Text")
}

@(test)
color_board_keyboard_moves_edits_and_walks_like_a_form :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	board_fixture(t, &p)
	// Tab from the search reaches the board as one stop on its tile; arrows move between tiles.
	ui.editor_key(&p, key({key = .Tab}))
	testing.expect_value(t, ui.editor_focus(&p), ui.Editor_Focus.Control)
	testing.expect_value(t, p.board.control, ui.Board_Control.Tile)
	ui.editor_key(&p, key({key = .Arrow_Right}))
	testing.expect_value(t, ui.editor_row(&p).key, "colors.pane")
	ui.editor_key(&p, key({key = .End}))
	testing.expect_value(t, ui.editor_row(&p).key, "colors.selection_foreground")
	ui.editor_key(&p, key({key = .Home}))
	testing.expect_value(t, ui.editor_row(&p).key, "colors.window")
	ui.editor_key(&p, key({key = .Arrow_Down}))
	testing.expect_value(t, ui.editor_row(&p).key, "colors.background")
	ui.editor_key(&p, key({key = .Arrow_Up}))
	testing.expect_value(t, ui.editor_row(&p).key, "colors.window")

	// Enter edits the hex value and Enter saves it; Escape leaves without saving.
	testing.expect_value(t, ui.editor_key(&p, key({key = .Enter})), ui.Editor_Outcome.Changed)
	testing.expect_value(t, p.board.control, ui.Board_Control.Hex)
	ui.editor_text(&p, "#102030")
	testing.expect_value(t, ui.field_string(&p.value), "#102030")
	testing.expect_value(t, ui.editor_key(&p, key({key = .Enter})), ui.Editor_Outcome.Save)
	testing.expect_value(t, p.board.control, ui.Board_Control.Tile)
	ui.editor_key(&p, key({key = .Enter}))
	ui.editor_text(&p, "#ffffff")
	testing.expect_value(t, ui.editor_key(&p, key({key = .Escape})), ui.Editor_Outcome.Changed)
	testing.expect_value(t, ui.field_string(&p.value), "#0c0c0e")
	testing.expect_value(t, p.board.control, ui.Board_Control.Tile)
	testing.expect_value(t, ui.editor_focus(&p), ui.Editor_Focus.Control)
	// Typing on a focused tile edits its value; arrows on a tile type nothing.
	ui.editor_text(&p, "#")
	testing.expect_value(t, p.board.control, ui.Board_Control.Hex)
	testing.expect_value(t, ui.field_string(&p.value), "#")
	ui.editor_key(&p, key({key = .Escape}))

	// Tab walks the tile, the card's controls, the hex field, then Reset to Defaults and the search.
	Stop :: struct {
		key:     string,
		control: ui.Board_Control,
	}
	stops := [?]Stop{{"theme.display_name", .Tile}, {"theme.duplicate", .Tile}, {"theme.delete", .Tile},
		{"colors.window", .Hex}}
	for stop in stops {
		ui.editor_key(&p, key({key = .Tab}))
		testing.expect_value(t, ui.editor_row(&p).key, stop.key)
		testing.expect_value(t, p.board.control, stop.control)
		testing.expect_value(t, ui.editor_focus(&p), ui.Editor_Focus.Control)
	}
	ui.editor_key(&p, key({key = .Tab}))
	testing.expect_value(t, ui.editor_focus(&p), ui.Editor_Focus.Reset_All)
	ui.editor_key(&p, key({key = .Tab}))
	testing.expect_value(t, ui.editor_focus(&p), ui.Editor_Focus.Search)
	ui.editor_key(&p, key({key = .Tab}))
	testing.expect_value(t, ui.editor_row(&p).key, "colors.window")
	testing.expect_value(t, p.board.control, ui.Board_Control.Tile)
	ui.editor_key(&p, key({key = .Tab, modifiers = {.Shift}}))
	testing.expect_value(t, ui.editor_focus(&p), ui.Editor_Focus.Search)

	// A color that differs from its base adds Reset after the hex field; an optional one, No Color.
	ui.editor_key(&p, key({key = .Tab}))
	for _ in 0 ..< 3 {ui.editor_key(&p, key({key = .Arrow_Right}))}
	testing.expect_value(t, ui.editor_row(&p).key, "colors.accent")
	ui.editor_key(&p, key({key = .Tab, modifiers = {.Shift}}))
	testing.expect_value(t, ui.editor_focus(&p), ui.Editor_Focus.Search)
	ui.editor_key(&p, key({key = .Tab, modifiers = {.Shift}}))
	testing.expect_value(t, ui.editor_focus(&p), ui.Editor_Focus.Reset_All)
	ui.editor_key(&p, key({key = .Tab, modifiers = {.Shift}}))
	testing.expect_value(t, p.board.control, ui.Board_Control.Reset)
	testing.expect_value(t, ui.editor_key(&p, key({key = .Space})), ui.Editor_Outcome.Reset)
	ui.editor_key(&p, key({key = .Tab, modifiers = {.Shift}}))
	testing.expect_value(t, p.board.control, ui.Board_Control.Hex)
	ui.editor_key(&p, key({key = .Escape}))
	ui.editor_key(&p, key({key = .End}))
	ui.editor_key(&p, key({key = .Tab}))
	ui.editor_key(&p, key({key = .Tab}))
	ui.editor_key(&p, key({key = .Tab}))
	ui.editor_key(&p, key({key = .Tab}))
	testing.expect_value(t, p.board.control, ui.Board_Control.Hex)
	ui.editor_key(&p, key({key = .Tab}))
	testing.expect_value(t, p.board.control, ui.Board_Control.No_Color)
	testing.expect_value(t, ui.editor_key(&p, key({key = .Enter})), ui.Editor_Outcome.Save)
	testing.expect_value(t, ui.field_string(&p.value), "")
}

@(test)
color_board_pointer_selects_picks_resets_and_runs_card_actions :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	l := board_fixture(t, &p)
	pane := ui.editor_row_parts(&p, l, board_item(&p, "colors.pane")).row
	testing.expect_value(t, board_press(&p, l, pane), ui.Editor_Outcome.Changed)
	testing.expect_value(t, ui.editor_row(&p).key, "colors.pane")
	testing.expect_value(t, ui.editor_focus(&p), ui.Editor_Focus.Control)
	x, y := center(pane)
	testing.expect_value(t, ui.editor_pointer(&p, l, x, y), platform.Cursor_Shape.Hand)

	// The picker is always open beside the board: a wheel press picks and drags, a release saves.
	wheel := ui.color_board_rect(&p, l, .Wheel)
	testing.expect(t, wheel.width > 0)
	before := strings.clone(ui.field_string(&p.value), context.temp_allocator)
	right := wheel.x + wheel.width - 2
	testing.expect_value(t, ui.editor_press(&p, l, nil, right, wheel.y + wheel.height / 2, false),
		ui.Editor_Outcome.Changed)
	testing.expect(t, ui.editor_dragging(&p))
	testing.expect(t, ui.field_string(&p.value) != before)
	testing.expect(t, ui.editor_drag(&p, l, nil, wheel.x + wheel.width / 2, wheel.y + wheel.height / 2))
	testing.expect_value(t, ui.editor_release(&p), ui.Editor_Outcome.Save)
	testing.expect(t, !ui.editor_dragging(&p))
	ramp := ui.color_board_rect(&p, l, .Ramp)
	ui.editor_press(&p, l, nil, ramp.x, ramp.y + ramp.height / 2, false)
	testing.expect_value(t, ui.field_string(&p.value), "#000000")
	testing.expect_value(t, ui.editor_release(&p), ui.Editor_Outcome.Save)
	hex := ui.color_board_rect(&p, l, .Hex)
	testing.expect(t, ui.editor_over_text(&p, l, hex.x + 4, hex.y + hex.height / 2))

	// Reset does nothing while the color matches its base, and resets one that differs.
	reset := ui.color_board_rect(&p, l, .Reset)
	testing.expect_value(t, board_press(&p, l, reset), ui.Editor_Outcome.Changed)
	accent := ui.editor_row_parts(&p, l, board_item(&p, "colors.accent")).row
	board_press(&p, l, accent)
	testing.expect_value(t, board_press(&p, l, reset), ui.Editor_Outcome.Reset)
	testing.expect_value(t, ui.editor_row(&p).key, "colors.accent")

	// Card buttons run their row's action; the inspector keeps its color meanwhile.
	duplicate := ui.editor_row_parts(&p, l, board_item(&p, "theme.duplicate")).row
	testing.expect_value(t, board_press(&p, l, duplicate), ui.Editor_Outcome.Save)
	testing.expect_value(t, ui.editor_row(&p).key, "theme.duplicate")
	testing.expect_value(t, ui.color_board_token_key(&p), "colors.accent")
	name := ui.editor_row_parts(&p, l, board_item(&p, "theme.display_name")).field
	testing.expect_value(t, board_press(&p, l, name), ui.Editor_Outcome.Changed)
	testing.expect_value(t, ui.editor_row(&p).key, "theme.display_name")
	testing.expect_value(t, ui.editor_focus(&p), ui.Editor_Focus.Control)
	testing.expect(t, ui.editor_over_text(&p, l, name.x + 4, name.y + name.height / 2))

	// No Color clears an optional color.
	optional := ui.editor_row_parts(&p, l, board_item(&p, "colors.selection_foreground")).row
	board_press(&p, l, optional)
	none := ui.color_board_rect(&p, l, .No_Color)
	testing.expect(t, none.width > 0)
	testing.expect_value(t, board_press(&p, l, none), ui.Editor_Outcome.Save)
	testing.expect_value(t, ui.field_string(&p.value), "")
}

@(test)
color_board_ring_slides_between_tiles_and_settles :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	l := board_fixture(t, &p)
	start := time.tick_now()
	ui.editor_animate(&p, true, test_frame(start))
	testing.expect(t, !ui.editor_animating(&p), "a page at rest has nothing moving")
	from := ui.color_board_rect(&p, l, .Ring)
	ui.editor_key(&p, key({key = .Tab}))
	ui.editor_key(&p, key({key = .Arrow_Right}))
	to := ui.editor_row_parts(&p, l, board_item(&p, "colors.pane")).row
	ui.editor_animate(&p, true, test_frame(time.tick_add(start, TEST_FRAME_PERIOD)))
	testing.expect(t, ui.editor_animating(&p))
	moving := ui.color_board_rect(&p, l, .Ring)
	testing.expect(t, moving.x > from.x && moving.x < to.x, "the ring is between the tiles")
	ui.editor_animate(&p, true, test_frame(time.tick_add(start, TEST_FRAME_PERIOD + 140 * time.Millisecond)))
	testing.expect(t, !ui.editor_animating(&p))
	testing.expect_value(t, ui.color_board_rect(&p, l, .Ring).x, to.x)

	// Without animations the ring lands on the next tile at once.
	ui.editor_key(&p, key({key = .Arrow_Right}))
	ui.editor_animate(&p, false, test_frame(time.tick_add(start, time.Second)))
	testing.expect(t, !ui.editor_animating(&p))
	surface := ui.editor_row_parts(&p, l, board_item(&p, "colors.surface")).row
	testing.expect_value(t, ui.color_board_rect(&p, l, .Ring).x, surface.x)

	// A tile under the pointer lights up over 80 ms and then rests.
	window := ui.editor_row_parts(&p, l, board_item(&p, "colors.window")).row
	x, y := center(window)
	testing.expect(t, ui.editor_hover(&p, l, x, y))
	later := time.tick_add(start, 2 * time.Second)
	ui.editor_animate(&p, true, test_frame(later))
	testing.expect(t, ui.editor_animating(&p))
	ui.editor_animate(&p, true, test_frame(time.tick_add(later, 80 * time.Millisecond + TEST_FRAME_PERIOD)))
	testing.expect(t, !ui.editor_animating(&p))
	testing.expect(t, !ui.editor_hover(&p, l, x, y), "the same hover changes nothing")
}
