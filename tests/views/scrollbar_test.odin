package views_test

import "core:fmt"
import "core:testing"
import "aio:commands"
import "aio:settings"
import "aio:views"
import "cosmos:ui"

@(test)
palette_scrollbar_pages_drags_and_keeps_rows_clear :: proc(t: ^testing.T) {
	registry := registry_create(t)
	defer commands.destroy(&registry)
	rows: [len(settings.SCHEMA)]views.Palette_Setting
	for entry, i in settings.SCHEMA {
		rows[i] = {key = entry.key, title = entry.title, group = settings.group_title(entry.key)}
	}
	p: views.Palette
	if !testing.expect_value(t, views.palette_init(&p, rows[:]), nil) {return}
	defer views.palette_destroy(&p)
	views.palette_open(&p, &registry)
	views.palette_text(&p, &registry, "setting")
	l := views.palette_layout(&p, 1000, 800, 1)
	if !testing.expect(t, l.bar_visible && len(p.results) > p.visible_rows) {return}
	testing.expect(t, l.list.x + l.list.width <= l.bar.track.x)
	testing.expect(t, l.bar.track.x + l.bar.track.width <= l.panel.x + l.panel.width)
	x := l.bar.track.x + 2

	testing.expect_value(t, views.palette_mouse_move(&p, l, x, l.bar.track.y + 1), views.Outcome.Changed)
	testing.expect(t, p.scroll_hover)
	outcome, _ := views.palette_mouse_press(&p, &registry, l, x, l.bar.track.y + l.bar.track.height - 1)
	testing.expect_value(t, outcome, views.Outcome.Changed)
	testing.expect_value(t, p.scroll, p.visible_rows)
	testing.expect(t, p.selected >= p.scroll && p.selected < p.scroll + p.visible_rows)

	l = views.palette_layout(&p, 1000, 800, 1)
	_, _ = views.palette_mouse_press(&p, &registry, l, x, l.bar.thumb.y + 1)
	_, holding := p.drag.(views.Scrollbar_Drag)
	testing.expect(t, holding)
	testing.expect_value(t, views.palette_scrollbar_drag(&p, l, x, 10000), views.Outcome.Changed)
	testing.expect_value(t, p.scroll, len(p.results) - p.visible_rows)
	l = views.palette_layout(&p, 1000, 800, 1)
	testing.expect_value(t, p.scroll, len(p.results) - p.visible_rows)
	// Released away from the track, the bar collapses without another pointer move.
	_ = views.palette_scrollbar_drag(&p, l, x - 500, -10000)
	testing.expect_value(t, p.scroll, 0)
	testing.expect_value(t, views.palette_pointer_release(&p), views.Outcome.Changed)
	testing.expect(t, p.drag == nil)
	testing.expect_value(t, views.palette_scrollbar_state(&p), ui.Scrollbar_State.Collapsed)

	views.palette_text(&p, &registry, "zzzzzzzz-nothing")
	l = views.palette_layout(&p, 1000, 800, 1)
	testing.expect(t, !l.bar_visible)
}

@(test)
choice_dropdown_scrollbar_pages_drags_and_keeps_options_clear :: proc(t: ^testing.T) {
	p: views.Editor
	defer views.editor_destroy(&p)
	choices: [40]string
	for &choice, i in choices {choice = fmt.tprintf("Font %02d", i)}
	testing.expect_value(t, views.editor_add(&p, {
		key = "font.family", title = "Shell Font", kind = .Choice, searchable = true,
		font_filter = true, choice_min_width = 360,
		value = choices[0], choices = choices[:],
	}, "Font"), nil)
	views.editor_filter(&p)
	testing.expect(t, views.editor_select_key(&p, "font.family"))
	l := page(&p)
	views.editor_key(&p, key({key = .Enter}))
	popup := views.editor_popup_rect(&p, l)
	// The track is the popup's right edge, so the area just inside it is the bar.
	x := popup.x + popup.width - 4
	bottom := popup.y + popup.height - 8

	testing.expect(t, views.editor_hover(&p, l, x, bottom))
	testing.expect(t, p.dropdown.bar_hover)
	testing.expect(t, views.editor_hover(&p, l, x - 20, bottom))
	testing.expect(t, !p.dropdown.bar_hover)

	testing.expect_value(t, views.editor_press(&p, l, nil, x, bottom, false), views.Editor_Outcome.Changed)
	testing.expect(t, p.dropdown.list.scroll > 0)
	testing.expect(t, p.dropdown.list.index >= p.dropdown.list.scroll)
	testing.expect(t, !views.editor_dragging(&p))

	top := p.dropdown.list.scroll
	testing.expect_value(t, views.editor_press(&p, l, nil, x, popup.y + 68 + 6, false), views.Editor_Outcome.Changed)
	testing.expect(t, p.dropdown.list.scroll < top)

	// At the top, the thumb starts at the track's top, so a press there grabs it.
	for p.dropdown.list.scroll > 0 {_ = views.editor_press(&p, l, nil, x, popup.y + 68 + 6, false)}
	testing.expect_value(t, views.editor_press(&p, l, nil, x, popup.y + 68 + 6, false), views.Editor_Outcome.Changed)
	testing.expect(t, views.editor_scrollbar_dragging(&p))
	testing.expect(t, views.editor_drag(&p, l, nil, x + 500, 10000))
	testing.expect_value(t, views.editor_release(&p), views.Editor_Outcome.Changed)
	testing.expect(t, !views.editor_dragging(&p))
	// A drag past the window's edge reaches the end: the wheel can scroll no further.
	end := p.dropdown.list.scroll
	views.editor_wheel(&p, l, popup.x + 10, popup.y + 80, -100)
	testing.expect_value(t, p.dropdown.list.scroll, end)
	testing.expect(t, end > top)
	testing.expect_value(t, ui.field_string(&p.value), "Font 00")
}
