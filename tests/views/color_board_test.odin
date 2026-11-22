package views_test

import "cosmos:platform"
import "cosmos:render"
import "aio:views"
import "core:strings"
import "core:testing"
import "core:time"
import "cosmos:ui"

@(rodata, private)
board_sections := [?]string{"General", "Colors"}

// A page whose second section is a color board: a card group, then two groups of tiles under
// different side headings. Accent differs from its base, and the pane and background share a value.
@(private)
board_fixture :: proc(t: ^testing.T, p: ^views.Editor) -> views.Editor_Layout {
	rows := [?]struct {
		row:   views.Editor_Row,
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
	for r in rows {testing.expect_value(t, views.editor_add(p, r.row, r.group), nil)}
	// A color row is named by its key without the prefix, which the page's owner sets as `ref`.
	for &row in p.rows {
		if strings.has_prefix(row.key, "colors.") {row.ref = strings.clone(row.key[len("colors."):])}
	}
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
	testing.expect(t, views.editor_board_group(p, "Surfaces", "Interface"))
	testing.expect(t, views.editor_board_group(p, "Shell Text", "Terminal"))
	card := views.Board_Card{title = "Mine", badge = "Custom", detail = "mine", base = "Base · Studio Dark", custom = true}
	testing.expect_value(t, views.editor_board_card(p, card), nil)
	p.sections = board_sections[:]
	l := views.editor_layout({0, 40, 1200, 900}, 1, true)
	views.editor_filter(p)
	views.editor_fit(p, l)
	views.editor_section_show(p, 1)
	views.editor_fit(p, l)
	return l
}

@(private)
board_item :: proc(p: ^views.Editor, key: string) -> int {
	for item, index in p.items {
		if item.row >= 0 && p.rows[item.row].key == key {return index}
	}
	return -1
}

@(private)
board_press :: proc(p: ^views.Editor, l: views.Editor_Layout, r: render.Rect) -> views.Editor_Outcome {
	x, y := center(r)
	return views.editor_press(p, l, nil, x, y, false)
}

@(test)
color_board_shows_its_section_and_search_lists_its_colors_as_rows :: proc(t: ^testing.T) {
	p: views.Editor
	defer views.editor_destroy(&p)
	board_fixture(t, &p)
	testing.expect(t, views.color_board_shown(&p))
	testing.expect_value(t, views.editor_row(&p).key, "colors.window")
	testing.expect_value(t, views.color_board_token_key(&p), "colors.window")

	// A search spans every section, lists matching colors as rows and counts them on their tab.
	views.editor_text(&p, "cursor")
	testing.expect(t, !views.color_board_shown(&p))
	keys := visible_keys(&p)
	if testing.expect_value(t, len(keys), 2) {testing.expect_value(t, keys[1], "colors.cursor")}
	testing.expect_value(t, views.editor_section_counts(&p)[1], 1)
	testing.expect_value(t, views.editor_row(&p).key, "colors.cursor")
	// Tile labels are searched too.
	views.editor_key(&p, key({key = .Escape}))
	views.editor_text(&p, "highlight")
	testing.expect_value(t, views.editor_row(&p).key, "colors.accent")

	// Leaving the search returns to the board on the color it chose.
	views.editor_key(&p, key({key = .Escape}))
	testing.expect(t, views.color_board_shown(&p))
	testing.expect_value(t, views.editor_row(&p).key, "colors.accent")

	// A reveal from another section lands on the color's tile, as a palette jump does.
	views.editor_section_show(&p, 0)
	testing.expect(t, !views.color_board_shown(&p))
	testing.expect(t, views.editor_reveal(&p, views.Reveal_Row{"colors.cursor"}))
	testing.expect(t, views.color_board_shown(&p))
	testing.expect_value(t, views.color_board_token_key(&p), "colors.cursor")

	// The outline lands on a group's first tile.
	views.editor_jump(&p, 1)
	testing.expect_value(t, views.editor_row(&p).key, "colors.window")
	views.editor_jump(&p, 2)
	testing.expect_value(t, views.editor_row(&p).key, "colors.background")
	testing.expect_value(t, p.groups[views.editor_active_group(&p)].title, "Shell Text")
}

@(test)
color_board_keyboard_moves_edits_and_walks_like_a_form :: proc(t: ^testing.T) {
	p: views.Editor
	defer views.editor_destroy(&p)
	board_fixture(t, &p)
	// Tab from the search reaches the board as one stop on its tile; arrows move between tiles.
	views.editor_key(&p, key({key = .Tab}))
	testing.expect_value(t, views.editor_focus(&p), views.Editor_Focus.Control)
	testing.expect_value(t, p.board.control, views.Board_Control.Tile)
	views.editor_key(&p, key({key = .Arrow_Right}))
	testing.expect_value(t, views.editor_row(&p).key, "colors.pane")
	views.editor_key(&p, key({key = .End}))
	testing.expect_value(t, views.editor_row(&p).key, "colors.selection_foreground")
	views.editor_key(&p, key({key = .Home}))
	testing.expect_value(t, views.editor_row(&p).key, "colors.window")
	views.editor_key(&p, key({key = .Arrow_Down}))
	testing.expect_value(t, views.editor_row(&p).key, "colors.background")
	views.editor_key(&p, key({key = .Arrow_Up}))
	testing.expect_value(t, views.editor_row(&p).key, "colors.window")

	// Enter edits the hex value and Enter saves it; Escape leaves without saving.
	testing.expect_value(t, views.editor_key(&p, key({key = .Enter})), views.Editor_Outcome.Changed)
	testing.expect_value(t, p.board.control, views.Board_Control.Hex)
	views.editor_text(&p, "#102030")
	testing.expect_value(t, ui.field_string(&p.value), "#102030")
	testing.expect_value(t, views.editor_key(&p, key({key = .Enter})), views.Editor_Outcome.Save)
	testing.expect_value(t, p.board.control, views.Board_Control.Tile)
	views.editor_key(&p, key({key = .Enter}))
	views.editor_text(&p, "#ffffff")
	testing.expect_value(t, views.editor_key(&p, key({key = .Escape})), views.Editor_Outcome.Changed)
	testing.expect_value(t, ui.field_string(&p.value), "#0c0c0e")
	testing.expect_value(t, p.board.control, views.Board_Control.Tile)
	testing.expect_value(t, views.editor_focus(&p), views.Editor_Focus.Control)
	// Typing on a focused tile edits its value; arrows on a tile type nothing.
	views.editor_text(&p, "#")
	testing.expect_value(t, p.board.control, views.Board_Control.Hex)
	testing.expect_value(t, ui.field_string(&p.value), "#")
	views.editor_key(&p, key({key = .Escape}))

	// Tab walks the tile, the card's controls, the hex field, then Reset to Defaults and the search.
	Stop :: struct {
		key:     string,
		control: views.Board_Control,
	}
	stops := [?]Stop{{"theme.display_name", .Tile}, {"theme.duplicate", .Tile}, {"theme.delete", .Tile},
		{"colors.window", .Link}, {"colors.window", .Hex}}
	for stop in stops {
		views.editor_key(&p, key({key = .Tab}))
		testing.expect_value(t, views.editor_row(&p).key, stop.key)
		testing.expect_value(t, p.board.control, stop.control)
		testing.expect_value(t, views.editor_focus(&p), views.Editor_Focus.Control)
	}
	views.editor_key(&p, key({key = .Tab}))
	testing.expect_value(t, views.editor_focus(&p), views.Editor_Focus.Reset_All)
	views.editor_key(&p, key({key = .Tab}))
	testing.expect_value(t, views.editor_focus(&p), views.Editor_Focus.Search)
	views.editor_key(&p, key({key = .Tab}))
	testing.expect_value(t, views.editor_row(&p).key, "colors.window")
	testing.expect_value(t, p.board.control, views.Board_Control.Tile)
	views.editor_key(&p, key({key = .Tab, modifiers = {.Shift}}))
	testing.expect_value(t, views.editor_focus(&p), views.Editor_Focus.Search)

	// A color that differs from its base adds Reset after the hex field; an optional one, No Color.
	views.editor_key(&p, key({key = .Tab}))
	for _ in 0 ..< 3 {views.editor_key(&p, key({key = .Arrow_Right}))}
	testing.expect_value(t, views.editor_row(&p).key, "colors.accent")
	views.editor_key(&p, key({key = .Tab, modifiers = {.Shift}}))
	testing.expect_value(t, views.editor_focus(&p), views.Editor_Focus.Search)
	views.editor_key(&p, key({key = .Tab, modifiers = {.Shift}}))
	testing.expect_value(t, views.editor_focus(&p), views.Editor_Focus.Reset_All)
	views.editor_key(&p, key({key = .Tab, modifiers = {.Shift}}))
	testing.expect_value(t, p.board.control, views.Board_Control.Reset)
	testing.expect_value(t, views.editor_key(&p, key({key = .Space})), views.Editor_Outcome.Reset)
	views.editor_key(&p, key({key = .Tab, modifiers = {.Shift}}))
	testing.expect_value(t, p.board.control, views.Board_Control.Hex)
	views.editor_key(&p, key({key = .Escape}))
	views.editor_key(&p, key({key = .End}))
	views.editor_key(&p, key({key = .Tab}))
	views.editor_key(&p, key({key = .Tab}))
	views.editor_key(&p, key({key = .Tab}))
	views.editor_key(&p, key({key = .Tab}))
	testing.expect_value(t, p.board.control, views.Board_Control.Link)
	views.editor_key(&p, key({key = .Tab}))
	testing.expect_value(t, p.board.control, views.Board_Control.Hex)
	views.editor_key(&p, key({key = .Tab}))
	testing.expect_value(t, p.board.control, views.Board_Control.No_Color)
	testing.expect_value(t, views.editor_key(&p, key({key = .Enter})), views.Editor_Outcome.Save)
	testing.expect_value(t, ui.field_string(&p.value), "")
}

@(test)
color_board_pointer_selects_picks_resets_and_runs_card_actions :: proc(t: ^testing.T) {
	p: views.Editor
	defer views.editor_destroy(&p)
	l := board_fixture(t, &p)
	pane := views.editor_row_parts(&p, l, board_item(&p, "colors.pane")).row
	testing.expect_value(t, board_press(&p, l, pane), views.Editor_Outcome.Changed)
	testing.expect_value(t, views.editor_row(&p).key, "colors.pane")
	testing.expect_value(t, views.editor_focus(&p), views.Editor_Focus.Control)
	x, y := center(pane)
	testing.expect_value(t, views.editor_pointer(&p, l, x, y), platform.Cursor_Shape.Hand)

	// The picker is always open beside the board: a wheel press picks and drags, a release saves.
	wheel := views.color_board_rect(&p, l, .Wheel)
	testing.expect(t, wheel.width > 0)
	before := strings.clone(ui.field_string(&p.value), context.temp_allocator)
	right := wheel.x + wheel.width - 2
	testing.expect_value(t, views.editor_press(&p, l, nil, right, wheel.y + wheel.height / 2, false),
		views.Editor_Outcome.Changed)
	testing.expect(t, views.editor_dragging(&p))
	testing.expect(t, ui.field_string(&p.value) != before)
	testing.expect(t, views.editor_drag(&p, l, nil, wheel.x + wheel.width / 2, wheel.y + wheel.height / 2))
	testing.expect_value(t, views.editor_release(&p), views.Editor_Outcome.Save)
	testing.expect(t, !views.editor_dragging(&p))
	ramp := views.color_board_rect(&p, l, .Ramp)
	views.editor_press(&p, l, nil, ramp.x, ramp.y + ramp.height / 2, false)
	testing.expect_value(t, ui.field_string(&p.value), "#000000")
	testing.expect_value(t, views.editor_release(&p), views.Editor_Outcome.Save)
	hex := views.color_board_rect(&p, l, .Hex)
	testing.expect(t, views.editor_over_text(&p, l, hex.x + 4, hex.y + hex.height / 2))

	// Reset does nothing while the color matches its base, and resets one that differs.
	reset := views.color_board_rect(&p, l, .Reset)
	testing.expect_value(t, board_press(&p, l, reset), views.Editor_Outcome.Changed)
	accent := views.editor_row_parts(&p, l, board_item(&p, "colors.accent")).row
	board_press(&p, l, accent)
	testing.expect_value(t, board_press(&p, l, reset), views.Editor_Outcome.Reset)
	testing.expect_value(t, views.editor_row(&p).key, "colors.accent")

	// Card buttons run their row's action; the inspector keeps its color meanwhile.
	duplicate := views.editor_row_parts(&p, l, board_item(&p, "theme.duplicate")).row
	testing.expect_value(t, board_press(&p, l, duplicate), views.Editor_Outcome.Save)
	testing.expect_value(t, views.editor_row(&p).key, "theme.duplicate")
	testing.expect_value(t, views.color_board_token_key(&p), "colors.accent")
	name := views.editor_row_parts(&p, l, board_item(&p, "theme.display_name")).field
	testing.expect_value(t, board_press(&p, l, name), views.Editor_Outcome.Changed)
	testing.expect_value(t, views.editor_row(&p).key, "theme.display_name")
	testing.expect_value(t, views.editor_focus(&p), views.Editor_Focus.Control)
	testing.expect(t, views.editor_over_text(&p, l, name.x + 4, name.y + name.height / 2))

	// No Color clears an optional color.
	optional := views.editor_row_parts(&p, l, board_item(&p, "colors.selection_foreground")).row
	board_press(&p, l, optional)
	none := views.color_board_rect(&p, l, .No_Color)
	testing.expect(t, none.width > 0)
	testing.expect_value(t, board_press(&p, l, none), views.Editor_Outcome.Save)
	testing.expect_value(t, ui.field_string(&p.value), "")
}

@(test)
color_board_ring_slides_between_tiles_and_settles :: proc(t: ^testing.T) {
	p: views.Editor
	defer views.editor_destroy(&p)
	l := board_fixture(t, &p)
	start := time.tick_now()
	views.editor_animate(&p, true, test_frame(start))
	testing.expect(t, !views.editor_animating(&p), "a page at rest has nothing moving")
	from := views.color_board_rect(&p, l, .Ring)
	views.editor_key(&p, key({key = .Tab}))
	views.editor_key(&p, key({key = .Arrow_Right}))
	to := views.editor_row_parts(&p, l, board_item(&p, "colors.pane")).row
	views.editor_animate(&p, true, test_frame(time.tick_add(start, TEST_FRAME_PERIOD)))
	testing.expect(t, views.editor_animating(&p))
	moving := views.color_board_rect(&p, l, .Ring)
	testing.expect(t, moving.x > from.x && moving.x < to.x, "the ring is between the tiles")
	views.editor_animate(&p, true, test_frame(time.tick_add(start, TEST_FRAME_PERIOD + 140 * time.Millisecond)))
	testing.expect(t, !views.editor_animating(&p))
	testing.expect_value(t, views.color_board_rect(&p, l, .Ring).x, to.x)

	// Without animations the ring lands on the next tile at once.
	views.editor_key(&p, key({key = .Arrow_Right}))
	views.editor_animate(&p, false, test_frame(time.tick_add(start, time.Second)))
	testing.expect(t, !views.editor_animating(&p))
	surface := views.editor_row_parts(&p, l, board_item(&p, "colors.surface")).row
	testing.expect_value(t, views.color_board_rect(&p, l, .Ring).x, surface.x)

	// A tile under the pointer lights up over 80 ms and then rests.
	window := views.editor_row_parts(&p, l, board_item(&p, "colors.window")).row
	x, y := center(window)
	testing.expect(t, views.editor_hover(&p, l, x, y))
	later := time.tick_add(start, 2 * time.Second)
	views.editor_animate(&p, true, test_frame(later))
	testing.expect(t, views.editor_animating(&p))
	views.editor_animate(&p, true, test_frame(time.tick_add(later, 80 * time.Millisecond + TEST_FRAME_PERIOD)))
	testing.expect(t, !views.editor_animating(&p))
	testing.expect(t, !views.editor_hover(&p, l, x, y), "the same hover changes nothing")
}

// The saved page the owner would publish after a link or unlink: the row shows the color it resolves to.
@(private)
board_follow :: proc(p: ^views.Editor, key, link, value: string) {
	for &row in p.rows {
		if row.key != key {continue}
		delete(row.link)
		delete(row.value)
		row.link, row.value = strings.clone(link), strings.clone(value)
	}
}

@(test)
color_board_points_a_color_at_another_and_unlinks_it :: proc(t: ^testing.T) {
	p: views.Editor
	defer views.editor_destroy(&p)
	l := board_fixture(t, &p)
	cursor := views.editor_row_parts(&p, l, board_item(&p, "colors.cursor")).row
	board_press(&p, l, cursor)
	testing.expect_value(t, views.color_board_token_key(&p), "colors.cursor")
	link := views.color_board_rect(&p, l, .Link)
	testing.expect(t, link.width > 0)
	testing.expect_value(t, views.color_board_rect(&p, l, .Unlink), render.Rect{})

	// The source field opens a list of the colors this one may follow: Custom color first, then every
	// other color that always has a value, so not itself and not the optional Selection text.
	testing.expect_value(t, board_press(&p, l, link), views.Editor_Outcome.Changed)
	testing.expect_value(t, views.editor_popup(&p), views.Editor_Popup.Choice)
	links := &p.board.links
	if testing.expect_value(t, links.count, 6) {
		testing.expect_value(t, links.choices[0], "")
		testing.expect_value(t, links.choices[1], "window")
		testing.expect_value(t, links.choices[4], "accent")
		for choice in links.choices[:links.count] {testing.expect(t, choice != "cursor")}
	}
	// Escape closes it without a change; the keyboard stays on the source field.
	testing.expect_value(t, views.editor_key(&p, key({key = .Escape})), views.Editor_Outcome.Changed)
	testing.expect_value(t, views.editor_popup(&p), views.Editor_Popup.None)
	testing.expect_value(t, p.board.control, views.Board_Control.Link)

	// Enter reopens it, and picking Accent saves the color's key as its value.
	views.editor_key(&p, key({key = .Enter}))
	testing.expect_value(t, views.editor_popup(&p), views.Editor_Popup.Choice)
	for _ in 0 ..< 4 {views.editor_key(&p, key({key = .Arrow_Down}))}
	testing.expect_value(t, views.editor_key(&p, key({key = .Enter})), views.Editor_Outcome.Save)
	testing.expect_value(t, ui.field_string(&p.value), "accent")
	testing.expect_value(t, views.editor_popup(&p), views.Editor_Popup.None)

	// Once saved the tile follows Accent: Unlink appears, and keeps the resolved color as its own.
	board_follow(&p, "colors.cursor", "accent", "#ff8800")
	unlink := views.color_board_rect(&p, l, .Unlink)
	testing.expect(t, unlink.width > 0)
	testing.expect(t, views.color_board_rect(&p, l, .Link).width < link.width)
	testing.expect_value(t, board_press(&p, l, unlink), views.Editor_Outcome.Save)
	testing.expect_value(t, ui.field_string(&p.value), "#ff8800")

	// Reset applies to a link even when the color it resolves to matches its base.
	board_follow(&p, "colors.cursor", "accent", "#ececf1")
	reset := views.color_board_rect(&p, l, .Reset)
	testing.expect_value(t, board_press(&p, l, reset), views.Editor_Outcome.Reset)

	// Custom color, the list's first choice, unlinks the same way.
	board_press(&p, l, views.color_board_rect(&p, l, .Link))
	for _ in 0 ..< 4 {views.editor_key(&p, key({key = .Arrow_Up}))}
	testing.expect_value(t, views.editor_key(&p, key({key = .Enter})), views.Editor_Outcome.Save)
	testing.expect_value(t, ui.field_string(&p.value), "#ececf1")
}

@(test)
color_board_never_offers_a_target_that_would_make_a_loop :: proc(t: ^testing.T) {
	p: views.Editor
	defer views.editor_destroy(&p)
	l := board_fixture(t, &p)
	// Window follows Pane, which follows Surface: Surface may follow neither of them.
	board_follow(&p, "colors.window", "pane", "#121215")
	board_follow(&p, "colors.pane", "surface", "#1b1b20")
	surface := views.editor_row_parts(&p, l, board_item(&p, "colors.surface")).row
	board_press(&p, l, surface)
	board_press(&p, l, views.color_board_rect(&p, l, .Link))
	links := &p.board.links
	testing.expect_value(t, links.count, 4)
	for choice in links.choices[:links.count] {
		testing.expect(t, choice != "window" && choice != "pane" && choice != "surface", choice)
	}
	// Accent, which nothing follows, may follow any of the others.
	views.editor_key(&p, key({key = .Escape}))
	accent := views.editor_row_parts(&p, l, board_item(&p, "colors.accent")).row
	board_press(&p, l, accent)
	board_press(&p, l, views.color_board_rect(&p, l, .Link))
	testing.expect_value(t, links.count, 6)
}
