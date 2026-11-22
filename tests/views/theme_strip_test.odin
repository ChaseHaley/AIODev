package views_test

import "core:testing"
import "core:time"
import "cosmos:platform"
import "aio:settings"
import "aio:views"
import "cosmos:ui"

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
strip_page :: proc(t: ^testing.T, p: ^views.Editor, applied: string) {
	theme_row := views.Editor_Row {
		key = "theme.name", title = "Theme", description = "Theme file or custom theme.", value = applied,
		default_value = "amber", kind = .Choice,
	}
	testing.expect_value(t, views.editor_add(p, theme_row, "Theme"), nil)
	editor_fixture(t, p)
	theme := settings.theme_default()
	sources: [len(strip_ids)]views.Theme_Card_Source
	for &source, i in sources {
		source = {id = strip_ids[i], name = strip_names[i], detail = "Theme file", theme = theme}
		source.custom = i == len(strip_ids) - 1
	}
	testing.expect_value(t, views.editor_theme_strip_load(p, "theme.name", sources[:], applied), nil)
	views.editor_filter(p)
}

@(private)
strip_settle :: proc(p: ^views.Editor, enabled := true) {
	start := time.tick_now()
	for frame in 0 ..< 30 {
		views.editor_animate(p, enabled, test_frame(time.tick_add(start, time.Duration(frame) * TEST_FRAME_PERIOD)))
	}
}

@(test)
theme_strip_owns_three_lines_and_moves_as_one_row :: proc(t: ^testing.T) {
	p: views.Editor
	defer views.editor_destroy(&p)
	strip_page(t, &p, "amber")
	l := page(&p)
	testing.expect(t, views.editor_select_key(&p, "theme.name"))
	head := p.selected
	testing.expect_value(t, p.rows[p.items[head].row].kind, views.Row_Kind.Theme_Strip)
	testing.expect_value(t, p.items[head + 1].part, 1)
	testing.expect_value(t, p.items[head + 2].part, 2)
	testing.expect_value(t, p.items[head + 3].row, -1)

	// The arrows pass over the strip's other lines in both directions.
	views.editor_key(&p, key({key = .Arrow_Down}))
	testing.expect_value(t, views.editor_row(&p).key, "pane.gap")
	views.editor_key(&p, key({key = .Arrow_Up}))
	testing.expect_value(t, p.selected, head)

	// A press on the strip's last line selects the row, not a line of its own.
	views.editor_key(&p, key({key = .Arrow_Down}))
	block := views.editor_strip_rect(&p, l, head)
	testing.expect_value(t, block.height, 3 * l.row_height)
	_ = views.editor_press(&p, l, nil, block.x + 4, block.y + block.height - 2, false)
	testing.expect_value(t, p.selected, head)

	// Selecting the row from below on a short page scrolls all three of its lines into view.
	short := views.editor_layout({0, 40, 1200, 520}, 1)
	views.editor_fit(&p, short)
	testing.expect(t, views.editor_select_key(&p, "scrollback.lines"))
	testing.expect(t, views.editor_select_key(&p, "theme.name"))
	testing.expect(t, p.scroll <= p.selected && p.selected + 3 <= p.scroll + p.visible_rows)
	p.scroll = p.selected + 2
	views.editor_key(&p, key({key = .Arrow_Down}))
	views.editor_key(&p, key({key = .Arrow_Up}))
	testing.expect_value(t, p.selected, head)
	testing.expect_value(t, p.scroll, head)

	// Any theme's name finds the row.
	ui.field_set(&p.filter, "juniper")
	views.editor_filter(&p)
	testing.expect_value(t, views.editor_row(&p).key, "theme.name")
	testing.expect_value(t, len(p.items), 4)
}

@(test)
theme_strip_keyboard_walks_cards_applies_and_reaches_customize :: proc(t: ^testing.T) {
	p: views.Editor
	defer views.editor_destroy(&p)
	strip_page(t, &p, "cedar")
	_ = page(&p)
	testing.expect(t, views.editor_select_key(&p, "theme.name"))
	views.editor_browse(&p)

	// Tab lands on the applied card, as on a checked radio button.
	testing.expect_value(t, views.editor_key(&p, key({key = .Tab})), views.Editor_Outcome.Changed)
	testing.expect_value(t, views.editor_focus(&p), views.Editor_Focus.Control)
	testing.expect_value(t, p.strip.focus, 2)
	testing.expect_value(t, views.editor_key(&p, key({key = .Arrow_Right})), views.Editor_Outcome.Changed)
	testing.expect_value(t, p.strip.focus, 3)
	testing.expect_value(t, p.strip.applied, 2)
	testing.expect_value(t, views.editor_key(&p, key({key = .Enter})), views.Editor_Outcome.Save)
	testing.expect_value(t, ui.field_string(&p.value), "dune")
	views.editor_key(&p, key({key = .End}))
	testing.expect_value(t, p.strip.focus, len(strip_ids) - 1)
	views.editor_key(&p, key({key = .Home}))
	testing.expect_value(t, p.strip.focus, 0)
	views.editor_key(&p, key({key = .Arrow_Left}))
	testing.expect_value(t, p.strip.focus, 0)
	testing.expect_value(t, views.editor_key(&p, key({key = .Space})), views.Editor_Outcome.Save)
	testing.expect_value(t, ui.field_string(&p.value), "amber")

	// Tab reaches Customize, then leaves the strip; Shift+Tab comes back to Customize first.
	views.editor_key(&p, key({key = .Tab}))
	testing.expect(t, p.strip.customize_focus)
	testing.expect_value(t, views.editor_key(&p, key({key = .Enter})), views.Editor_Outcome.Theme_Customize)
	views.editor_key(&p, key({key = .Tab, modifiers = {.Shift}}))
	testing.expect(t, !p.strip.customize_focus)
	testing.expect_value(t, views.editor_row(&p).key, "theme.name")
	views.editor_key(&p, key({key = .Tab}))
	views.editor_key(&p, key({key = .Tab}))
	testing.expect_value(t, views.editor_row(&p).key, "pane.gap")
	views.editor_key(&p, key({key = .Tab, modifiers = {.Shift}}))
	testing.expect_value(t, views.editor_row(&p).key, "theme.name")
	testing.expect(t, p.strip.customize_focus)
	testing.expect_value(t, views.editor_key(&p, key({key = .Space})), views.Editor_Outcome.Theme_Customize)
}

// Rebuilds `p` as its owner does after a save that made `applied` the active theme: a new page carries
// the strip's state over, then fits the layout.
@(private)
strip_rebuild :: proc(t: ^testing.T, p: ^views.Editor, applied: string) -> views.Editor_Layout {
	view, view_error := views.editor_view_take(p)
	testing.expect_value(t, view_error, nil)
	next: views.Editor
	strip_page(t, &next, applied)
	views.editor_view_restore(&next, &view)
	views.editor_view_destroy(&view)
	next.fit_layout = p.fit_layout
	views.editor_destroy(p)
	p^ = next
	l := page(p)
	testing.expect(t, views.editor_select_key(p, "theme.name"))
	return l
}

@(test)
theme_strip_applying_opens_the_chosen_card_under_the_pointer :: proc(t: ^testing.T) {
	p: views.Editor
	defer views.editor_destroy(&p)
	strip_page(t, &p, "amber")
	l := page(&p)
	testing.expect(t, views.editor_select_key(&p, "theme.name"))
	head := p.selected
	chosen := views.editor_strip_card_rect(&p, l, head, 3)
	x, y := center(chosen)
	testing.expect_value(t, views.editor_pointer(&p, l, x, y), platform.Cursor_Shape.Hand)
	wide_x, wide_y := center(views.editor_strip_card_rect(&p, l, head, 0))
	testing.expect_value(t, views.editor_pointer(&p, l, wide_x - 60, wide_y), platform.Cursor_Shape.Arrow)
	testing.expect_value(t, views.editor_press(&p, l, nil, x, y, false), views.Editor_Outcome.Save)
	testing.expect_value(t, ui.field_string(&p.value), "dune")

	// The chosen card opens leftward into the space the closing card gives up, its right edge and the
	// strip's scroll still, so it never leaves the pointer; both widths move on one curve.
	l = strip_rebuild(t, &p, "dune")
	right := chosen.x + chosen.width
	start := time.tick_now()
	moved := false
	for frame in 0 ..< 20 {
		views.editor_animate(&p, true, test_frame(time.tick_add(start, time.Duration(frame) * TEST_FRAME_PERIOD)))
		r := views.editor_strip_card_rect(&p, l, head, 3)
		testing.expect(t, abs(r.x + r.width - right) < 0.01)
		testing.expect(t, r.x <= x && x < r.x + r.width)
		opening, closing := p.strip.cards[3].open.value, p.strip.cards[0].open.value
		testing.expect(t, abs(opening + closing - 1) < 0.0001)
		moved ||= opening > 0 && opening < 1
		testing.expect_value(t, p.strip.scroll.value, f32(0))
	}
	testing.expect(t, moved)
	testing.expect(t, !views.editor_animating(&p))
	testing.expect_value(t, p.strip.cards[3].open.value, f32(1))
	testing.expect_value(t, p.strip.cards[0].open.value, f32(0))

	// A card before the applied one keeps its left edge and opens to the right.
	before := views.editor_strip_card_rect(&p, l, head, 1)
	_ = views.editor_press(&p, l, nil, before.x + 10, before.y + 10, false)
	l = strip_rebuild(t, &p, "basalt")
	views.editor_animate(&p, true, test_frame(time.tick_now()))
	testing.expect(t, views.editor_animating(&p))
	testing.expect_value(t, views.editor_strip_card_rect(&p, l, head, 1).x, before.x)

	// With animations off a change lands at once and nothing goes on moving.
	_ = views.editor_press(&p, l, nil, before.x + 10, before.y + 10, false)
	views.editor_key(&p, key({key = .End}))
	testing.expect_value(t, views.editor_key(&p, key({key = .Enter})), views.Editor_Outcome.Save)
	l = strip_rebuild(t, &p, "mine")
	testing.expect(t, views.editor_animate(&p, false, test_frame(time.tick_now())))
	testing.expect(t, !views.editor_animating(&p))
	testing.expect_value(t, p.strip.cards[len(strip_ids) - 1].open.value, f32(1))
	testing.expect_value(t, p.strip.cards[1].open.value, f32(0))
	last := views.editor_strip_card_rect(&p, l, head, len(strip_ids) - 1)
	testing.expect(t, last.x + last.width <= l.list.x + l.list.width)
}

@(test)
theme_strip_scrolls_sideways_to_the_keyboard_card_and_under_the_wheel :: proc(t: ^testing.T) {
	p: views.Editor
	defer views.editor_destroy(&p)
	strip_page(t, &p, "amber")
	l := views.editor_layout({0, 40, 1200, 520}, 1)
	views.editor_fit(&p, l)
	testing.expect(t, views.editor_select_key(&p, "theme.name"))
	head := p.selected
	views.editor_focus_row(&p)
	testing.expect_value(t, p.strip.scroll.value, f32(0))

	// End moves the keyboard to the last card, and the strip eases until it shows whole.
	views.editor_key(&p, key({key = .End}))
	testing.expect(t, views.editor_animating(&p))
	strip_settle(&p)
	testing.expect(t, !views.editor_animating(&p))
	last := views.editor_strip_card_rect(&p, l, head, len(strip_ids) - 1)
	testing.expect(t, p.strip.scroll.value > 0)
	testing.expect(t, last.x + last.width <= l.list.x + l.list.width)

	// The wheel over the strip scrolls it back, and never moves the page.
	block := views.editor_strip_rect(&p, l, head)
	x, y := block.x + block.width / 2, block.y + block.height / 2
	scrolled := p.strip.scroll.value
	views.editor_wheel(&p, l, x, y, 3)
	strip_settle(&p)
	testing.expect(t, p.strip.scroll.value < scrolled)
	testing.expect_value(t, p.scroll, 0)
	for _ in 0 ..< 20 {views.editor_wheel(&p, l, x, y, 3)}
	strip_settle(&p)
	testing.expect_value(t, p.strip.scroll.value, f32(0))
	views.editor_wheel(&p, l, x, y, -3)
	strip_settle(&p)
	testing.expect(t, p.strip.scroll.value > 0)

	// Hover follows the card under the pointer and leaves with it.
	card := views.editor_strip_card_rect(&p, l, head, 5)
	cx, cy := center(card)
	testing.expect(t, views.editor_hover(&p, l, cx, cy))
	testing.expect_value(t, p.strip.hover, 5)
	testing.expect(t, views.editor_hover_clear(&p))
	testing.expect_value(t, p.strip.hover, -1)

	// A narrower page brings the applied card back into view at once, without motion.
	narrow := views.editor_layout({0, 40, 900, 520}, 1)
	views.editor_fit(&p, narrow)
	testing.expect(t, !views.editor_animating(&p))
	applied := views.editor_strip_card_rect(&p, narrow, head, 0)
	testing.expect(t, applied.x >= narrow.list.x)

	// Past the strip's last card, or over the row's title, the wheel still leaves the page put.
	views.editor_fit(&p, l)
	testing.expect(t, len(p.items) > l.rows)
	for _ in 0 ..< 20 {views.editor_wheel(&p, l, x, y, -3)}
	views.editor_wheel(&p, l, x, block.y + 4, -3)
	strip_settle(&p)
	testing.expect_value(t, p.scroll, 0)
	testing.expect(t, p.strip.scroll.value >= scrolled)
}

@(test)
theme_strip_scrollbar_grows_under_the_pointer_and_drags_like_every_other :: proc(t: ^testing.T) {
	p: views.Editor
	defer views.editor_destroy(&p)
	strip_page(t, &p, "amber")
	l := views.editor_layout({0, 40, 1200, 520}, 1)
	views.editor_fit(&p, l)
	testing.expect(t, views.editor_select_key(&p, "theme.name"))
	head := p.selected
	rest, visible := views.editor_strip_scrollbar(&p, l, head)
	if !testing.expect(t, visible) {return}
	testing.expect(t, rest.horizontal)
	block := views.editor_strip_rect(&p, l, head)
	testing.expect(t, rest.track.y + rest.track.height <= block.y + block.height)

	// The thin thumb widens once the pointer enters the track, and narrows when it leaves.
	x, y := center(rest.thumb)
	testing.expect(t, views.editor_hover(&p, l, x, rest.track.y + 1))
	hovered, _ := views.editor_strip_scrollbar(&p, l, head)
	testing.expect(t, hovered.thumb.height > rest.thumb.height)
	testing.expect_value(t, p.strip.hover, -1)

	// A press on the thumb holds it; the strip follows the pointer at once, clamped at the end,
	// and the page never scrolls.
	testing.expect_value(t, views.editor_press(&p, l, nil, x, y, false), views.Editor_Outcome.Changed)
	testing.expect(t, views.editor_scrollbar_dragging(&p))
	testing.expect(t, views.editor_drag(&p, l, nil, x + 100, y + 200))
	testing.expect(t, p.strip.scroll.value > 0)
	testing.expect(t, !views.editor_animating(&p))
	testing.expect(t, views.editor_drag(&p, l, nil, x + 5000, y))
	end := p.strip.scroll.value
	last := views.editor_strip_card_rect(&p, l, head, len(strip_ids) - 1)
	testing.expect(t, abs(last.x + last.width - (block.x + block.width)) < 40)
	testing.expect_value(t, p.scroll, 0)
	held, _ := views.editor_strip_scrollbar(&p, l, head)
	testing.expect(t, held.thumb.x + held.thumb.width <= held.track.x + held.track.width + 0.01)
	testing.expect_value(t, views.editor_release(&p), views.Editor_Outcome.Changed)
	testing.expect(t, !views.editor_scrollbar_dragging(&p))
	testing.expect_value(t, p.strip.scroll.value, end)

	// A press on the track before the thumb pages back toward it, easing as the wheel does.
	bar, _ := views.editor_strip_scrollbar(&p, l, head)
	_ = views.editor_press(&p, l, nil, bar.track.x + 2, bar.track.y + bar.track.height / 2, false)
	testing.expect(t, !views.editor_scrollbar_dragging(&p))
	strip_settle(&p)
	testing.expect(t, p.strip.scroll.value < end)

	// Leaving the page drops the hover, so the thumb narrows again.
	testing.expect(t, views.editor_hover_clear(&p))
	testing.expect(t, !p.strip.bar_hover)
}
