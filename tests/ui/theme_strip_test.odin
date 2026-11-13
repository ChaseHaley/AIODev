package ui_test

import "core:testing"
import "core:time"
import "aio:platform"
import "aio:settings"
import "aio:ui"

@(private, rodata)
strip_ids := [?]string{
	"amber", "basalt", "cedar", "dune", "ember", "fjord", "garnet", "harbor", "iris", "juniper", "kelp", "mine",
}

@(private, rodata)
strip_names := [?]string{
	"Amber", "Basalt", "Cedar", "Dune", "Ember", "Fjord", "Garnet", "Harbor", "Iris", "Juniper", "Kelp", "My Theme",
}

// A page with the theme strip first: eleven theme files, then one custom theme, `applied` active. As
// the page owner does, the strip is listed before the page first fits a layout.
@(private)
strip_page :: proc(t: ^testing.T, p: ^ui.Editor, applied: string) {
	theme_row := ui.Editor_Row {
		key = "theme.name", title = "Theme", description = "Theme file or custom theme.", value = applied,
		default_value = "amber", kind = .Choice,
	}
	testing.expect_value(t, ui.editor_add(p, theme_row, "Theme"), nil)
	editor_fixture(t, p)
	theme := settings.theme_default()
	sources: [len(strip_ids)]ui.Theme_Card_Source
	for &source, i in sources {
		source = {id = strip_ids[i], name = strip_names[i], detail = "Theme file", theme = theme}
		source.custom = i == len(strip_ids) - 1
	}
	testing.expect_value(t, ui.editor_theme_strip_load(p, "theme.name", sources[:], applied), nil)
	ui.editor_filter(p)
}

@(private)
strip_settle :: proc(p: ^ui.Editor, enabled := true) {
	start := time.tick_now()
	for frame in 0 ..< 30 {
		ui.editor_animate(p, enabled, test_frame(time.tick_add(start, time.Duration(frame) * TEST_FRAME_PERIOD)))
	}
}

@(test)
theme_strip_owns_three_lines_and_moves_as_one_row :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	strip_page(t, &p, "amber")
	l := page(&p)
	testing.expect(t, ui.editor_select_key(&p, "theme.name"))
	head := p.selected
	testing.expect_value(t, p.rows[p.items[head].row].kind, ui.Row_Kind.Theme_Strip)
	testing.expect_value(t, p.items[head + 1].part, 1)
	testing.expect_value(t, p.items[head + 2].part, 2)
	testing.expect_value(t, p.items[head + 3].row, -1)

	// The arrows pass over the strip's other lines in both directions.
	ui.editor_key(&p, key({key = .Arrow_Down}))
	testing.expect_value(t, ui.editor_row(&p).key, "pane.gap")
	ui.editor_key(&p, key({key = .Arrow_Up}))
	testing.expect_value(t, p.selected, head)

	// A press on the strip's last line selects the row, not a line of its own.
	ui.editor_key(&p, key({key = .Arrow_Down}))
	block := ui.editor_strip_rect(&p, l, head)
	testing.expect_value(t, block.height, 3 * l.row_height)
	_ = ui.editor_press(&p, l, nil, block.x + 4, block.y + block.height - 2, false)
	testing.expect_value(t, p.selected, head)

	// Selecting the row from below on a short page scrolls all three of its lines into view.
	short := ui.editor_layout({0, 40, 1200, 520}, 1)
	ui.editor_fit(&p, short)
	testing.expect(t, ui.editor_select_key(&p, "scrollback.lines"))
	testing.expect(t, ui.editor_select_key(&p, "theme.name"))
	testing.expect(t, p.scroll <= p.selected && p.selected + 3 <= p.scroll + p.visible_rows)
	p.scroll = p.selected + 2
	ui.editor_key(&p, key({key = .Arrow_Down}))
	ui.editor_key(&p, key({key = .Arrow_Up}))
	testing.expect_value(t, p.selected, head)
	testing.expect_value(t, p.scroll, head)

	// Any theme's name finds the row.
	ui.field_set(&p.filter, "juniper")
	ui.editor_filter(&p)
	testing.expect_value(t, ui.editor_row(&p).key, "theme.name")
	testing.expect_value(t, len(p.items), 4)
}

@(test)
theme_strip_keyboard_walks_cards_applies_and_reaches_customize :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	strip_page(t, &p, "cedar")
	_ = page(&p)
	testing.expect(t, ui.editor_select_key(&p, "theme.name"))
	ui.editor_browse(&p)

	// Tab lands on the applied card, as on a checked radio button.
	testing.expect_value(t, ui.editor_key(&p, key({key = .Tab})), ui.Editor_Outcome.Changed)
	testing.expect_value(t, ui.editor_focus(&p), ui.Editor_Focus.Control)
	testing.expect_value(t, p.strip.focus, 2)
	testing.expect_value(t, ui.editor_key(&p, key({key = .Arrow_Right})), ui.Editor_Outcome.Changed)
	testing.expect_value(t, p.strip.focus, 3)
	testing.expect_value(t, p.strip.applied, 2)
	testing.expect_value(t, ui.editor_key(&p, key({key = .Enter})), ui.Editor_Outcome.Save)
	testing.expect_value(t, ui.field_string(&p.value), "dune")
	ui.editor_key(&p, key({key = .End}))
	testing.expect_value(t, p.strip.focus, len(strip_ids) - 1)
	ui.editor_key(&p, key({key = .Home}))
	testing.expect_value(t, p.strip.focus, 0)
	ui.editor_key(&p, key({key = .Arrow_Left}))
	testing.expect_value(t, p.strip.focus, 0)
	testing.expect_value(t, ui.editor_key(&p, key({key = .Space})), ui.Editor_Outcome.Save)
	testing.expect_value(t, ui.field_string(&p.value), "amber")

	// Tab reaches Customize, then leaves the strip; Shift+Tab comes back to Customize first.
	ui.editor_key(&p, key({key = .Tab}))
	testing.expect(t, p.strip.customize_focus)
	testing.expect_value(t, ui.editor_key(&p, key({key = .Enter})), ui.Editor_Outcome.Theme_Customize)
	ui.editor_key(&p, key({key = .Tab, modifiers = {.Shift}}))
	testing.expect(t, !p.strip.customize_focus)
	testing.expect_value(t, ui.editor_row(&p).key, "theme.name")
	ui.editor_key(&p, key({key = .Tab}))
	ui.editor_key(&p, key({key = .Tab}))
	testing.expect_value(t, ui.editor_row(&p).key, "pane.gap")
	ui.editor_key(&p, key({key = .Tab, modifiers = {.Shift}}))
	testing.expect_value(t, ui.editor_row(&p).key, "theme.name")
	testing.expect(t, p.strip.customize_focus)
	testing.expect_value(t, ui.editor_key(&p, key({key = .Space})), ui.Editor_Outcome.Theme_Customize)
}

// Rebuilds `p` as its owner does after a save that made `applied` the active theme: a new page carries
// the strip's state over, then fits the layout.
@(private)
strip_rebuild :: proc(t: ^testing.T, p: ^ui.Editor, applied: string) -> ui.Editor_Layout {
	view, view_error := ui.editor_view_take(p)
	testing.expect_value(t, view_error, nil)
	next: ui.Editor
	strip_page(t, &next, applied)
	ui.editor_view_restore(&next, &view)
	ui.editor_view_destroy(&view)
	next.fit_layout = p.fit_layout
	ui.editor_destroy(p)
	p^ = next
	l := page(p)
	testing.expect(t, ui.editor_select_key(p, "theme.name"))
	return l
}

@(test)
theme_strip_applying_opens_the_chosen_card_under_the_pointer :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	strip_page(t, &p, "amber")
	l := page(&p)
	testing.expect(t, ui.editor_select_key(&p, "theme.name"))
	head := p.selected
	chosen := ui.editor_strip_card_rect(&p, l, head, 3)
	x, y := center(chosen)
	testing.expect_value(t, ui.editor_pointer(&p, l, x, y), platform.Cursor_Shape.Hand)
	wide_x, wide_y := center(ui.editor_strip_card_rect(&p, l, head, 0))
	testing.expect_value(t, ui.editor_pointer(&p, l, wide_x - 60, wide_y), platform.Cursor_Shape.Arrow)
	testing.expect_value(t, ui.editor_press(&p, l, nil, x, y, false), ui.Editor_Outcome.Save)
	testing.expect_value(t, ui.field_string(&p.value), "dune")

	// The chosen card opens leftward into the space the closing card gives up, its right edge and the
	// strip's scroll still, so it never leaves the pointer; both widths move on one curve.
	l = strip_rebuild(t, &p, "dune")
	right := chosen.x + chosen.width
	start := time.tick_now()
	moved := false
	for frame in 0 ..< 20 {
		ui.editor_animate(&p, true, test_frame(time.tick_add(start, time.Duration(frame) * TEST_FRAME_PERIOD)))
		r := ui.editor_strip_card_rect(&p, l, head, 3)
		testing.expect(t, abs(r.x + r.width - right) < 0.01)
		testing.expect(t, r.x <= x && x < r.x + r.width)
		opening, closing := p.strip.cards[3].open.value, p.strip.cards[0].open.value
		testing.expect(t, abs(opening + closing - 1) < 0.0001)
		moved ||= opening > 0 && opening < 1
		testing.expect_value(t, p.strip.scroll.value, f32(0))
	}
	testing.expect(t, moved)
	testing.expect(t, !ui.editor_animating(&p))
	testing.expect_value(t, p.strip.cards[3].open.value, f32(1))
	testing.expect_value(t, p.strip.cards[0].open.value, f32(0))

	// A card before the applied one keeps its left edge and opens to the right.
	before := ui.editor_strip_card_rect(&p, l, head, 1)
	_ = ui.editor_press(&p, l, nil, before.x + 10, before.y + 10, false)
	l = strip_rebuild(t, &p, "basalt")
	ui.editor_animate(&p, true, test_frame(time.tick_now()))
	testing.expect(t, ui.editor_animating(&p))
	testing.expect_value(t, ui.editor_strip_card_rect(&p, l, head, 1).x, before.x)

	// With animations off a change lands at once and nothing goes on moving.
	_ = ui.editor_press(&p, l, nil, before.x + 10, before.y + 10, false)
	ui.editor_key(&p, key({key = .End}))
	testing.expect_value(t, ui.editor_key(&p, key({key = .Enter})), ui.Editor_Outcome.Save)
	l = strip_rebuild(t, &p, "mine")
	testing.expect(t, ui.editor_animate(&p, false, test_frame(time.tick_now())))
	testing.expect(t, !ui.editor_animating(&p))
	testing.expect_value(t, p.strip.cards[len(strip_ids) - 1].open.value, f32(1))
	testing.expect_value(t, p.strip.cards[1].open.value, f32(0))
	last := ui.editor_strip_card_rect(&p, l, head, len(strip_ids) - 1)
	testing.expect(t, last.x + last.width <= l.list.x + l.list.width)
}

@(test)
theme_strip_scrolls_sideways_to_the_keyboard_card_and_under_the_wheel :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	strip_page(t, &p, "amber")
	l := ui.editor_layout({0, 40, 1200, 520}, 1)
	ui.editor_fit(&p, l)
	testing.expect(t, ui.editor_select_key(&p, "theme.name"))
	head := p.selected
	ui.editor_focus_row(&p)
	testing.expect_value(t, p.strip.scroll.value, f32(0))

	// End moves the keyboard to the last card, and the strip eases until it shows whole.
	ui.editor_key(&p, key({key = .End}))
	testing.expect(t, ui.editor_animating(&p))
	strip_settle(&p)
	testing.expect(t, !ui.editor_animating(&p))
	last := ui.editor_strip_card_rect(&p, l, head, len(strip_ids) - 1)
	testing.expect(t, p.strip.scroll.value > 0)
	testing.expect(t, last.x + last.width <= l.list.x + l.list.width)

	// The wheel over the strip scrolls it back, and never moves the page.
	block := ui.editor_strip_rect(&p, l, head)
	x, y := block.x + block.width / 2, block.y + block.height / 2
	scrolled := p.strip.scroll.value
	ui.editor_wheel(&p, l, x, y, 3)
	strip_settle(&p)
	testing.expect(t, p.strip.scroll.value < scrolled)
	testing.expect_value(t, p.scroll, 0)
	for _ in 0 ..< 20 {ui.editor_wheel(&p, l, x, y, 3)}
	strip_settle(&p)
	testing.expect_value(t, p.strip.scroll.value, f32(0))
	ui.editor_wheel(&p, l, x, y, -3)
	strip_settle(&p)
	testing.expect(t, p.strip.scroll.value > 0)

	// Hover follows the card under the pointer and leaves with it.
	card := ui.editor_strip_card_rect(&p, l, head, 5)
	cx, cy := center(card)
	testing.expect(t, ui.editor_hover(&p, l, cx, cy))
	testing.expect_value(t, p.strip.hover, 5)
	testing.expect(t, ui.editor_hover_clear(&p))
	testing.expect_value(t, p.strip.hover, -1)

	// A narrower page brings the applied card back into view at once, without motion.
	narrow := ui.editor_layout({0, 40, 900, 520}, 1)
	ui.editor_fit(&p, narrow)
	testing.expect(t, !ui.editor_animating(&p))
	applied := ui.editor_strip_card_rect(&p, narrow, head, 0)
	testing.expect(t, applied.x >= narrow.list.x)

	// Past the strip's last card, or over the row's title, the wheel still leaves the page put.
	ui.editor_fit(&p, l)
	testing.expect(t, len(p.items) > l.rows)
	for _ in 0 ..< 20 {ui.editor_wheel(&p, l, x, y, -3)}
	ui.editor_wheel(&p, l, x, block.y + 4, -3)
	strip_settle(&p)
	testing.expect_value(t, p.scroll, 0)
	testing.expect(t, p.strip.scroll.value >= scrolled)
}
