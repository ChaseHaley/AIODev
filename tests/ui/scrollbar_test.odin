package ui_test

import "core:fmt"
import "core:time"
import "core:testing"
import "aio:commands"
import "cosmos:render"
import "aio:settings"
import "aio:ui"

@(test)
scrollbar_hides_when_content_fits_and_expands_under_pointer :: proc(t: ^testing.T) {
	area := render.Rect{0, 0, 100, 200}
	_, fits := ui.scrollbar_layout(area, {total = 10, visible = 10}, .Collapsed, 1)
	testing.expect(t, !fits)
	thin, visible := ui.scrollbar_layout(area, {total = 100, visible = 10, offset = 0}, .Collapsed, 1)
	testing.expect(t, visible)
	testing.expect_value(t, thin.track, render.Rect{90, 0, 10, 200})
	testing.expect_value(t, thin.thumb.y, f32(0))
	testing.expect(t, thin.thumb.height >= 24)
	wide, _ := ui.scrollbar_layout(area, {total = 100, visible = 10, offset = 90}, .Hovered, 1)
	testing.expect(t, wide.thumb.width > thin.thumb.width)
	testing.expect_value(t, wide.thumb.x + wide.thumb.width, thin.thumb.x + thin.thumb.width)
	testing.expect_value(t, wide.thumb.y + wide.thumb.height, f32(200))
	testing.expect_value(t, ui.scrollbar_state(false, {}), ui.Scrollbar_State.Collapsed)
	testing.expect_value(t, ui.scrollbar_state(true, {}), ui.Scrollbar_State.Hovered)
	testing.expect_value(t, ui.scrollbar_state(false, {active = true}), ui.Scrollbar_State.Active)
}

@(test)
scrollbar_track_pages_and_thumb_drags_clamped :: proc(t: ^testing.T) {
	bar, _ := ui.scrollbar_layout({0, 0, 100, 200}, {total = 100, visible = 10, offset = 40}, .Collapsed, 1)
	drag: ui.Scroll_Drag
	testing.expect_value(t, ui.scrollbar_press(&drag, bar, bar.thumb.y - 1), 30)
	testing.expect_value(t, ui.scrollbar_press(&drag, bar, bar.thumb.y + bar.thumb.height), 50)
	testing.expect(t, !drag.active)
	testing.expect_value(t, ui.scrollbar_press(&drag, bar, bar.thumb.y + 5), 40)
	testing.expect(t, drag.active && drag.grab == 5)
	testing.expect_value(t, ui.scrollbar_drag(drag, bar, -500), 0)
	testing.expect_value(t, ui.scrollbar_drag(drag, bar, 5000), 90)
	testing.expect_value(t, ui.scrollbar_drag(drag, bar, bar.thumb.y + 5), 40)
}

@(test)
scrollbar_page_pages_toward_the_pointer_and_stops_at_the_thumb :: proc(t: ^testing.T) {
	// Windows' own delays: the first repeat after 200 ms, then one every 50 ms.
	testing.expect_value(t, ui.SCROLLBAR_REPEAT_DELAY, 200 * time.Millisecond)
	testing.expect_value(t, ui.SCROLLBAR_REPEAT_INTERVAL, 50 * time.Millisecond)

	bar, _ := ui.scrollbar_layout({0, 0, 100, 200}, {total = 100, visible = 10, offset = 40}, .Collapsed, 1)
	x := bar.track.x + 2
	offset, result := ui.scrollbar_page(bar, x, bar.thumb.y - 1, .Before)
	testing.expect_value(t, offset, 30)
	testing.expect_value(t, result, ui.Scroll_Page.Paged)
	offset, result = ui.scrollbar_page(bar, x, bar.thumb.y + bar.thumb.height, .After)
	testing.expect_value(t, offset, 50)
	testing.expect_value(t, result, ui.Scroll_Page.Paged)
	// The thumb under the pointer: the view has met it, and nothing is held.
	offset, result = ui.scrollbar_page(bar, x, bar.thumb.y + 2, .Before)
	testing.expect_value(t, offset, 40)
	testing.expect_value(t, result, ui.Scroll_Page.On_Thumb)
	// A press that began below the thumb does not reverse when the pointer crosses above it: it pauses, as a
	// native scrollbar does, and pages again once the pointer is back below.
	offset, result = ui.scrollbar_page(bar, x, bar.thumb.y - 1, .After)
	testing.expect_value(t, offset, 40)
	testing.expect_value(t, result, ui.Scroll_Page.Off_Track)
	offset, result = ui.scrollbar_page(bar, x, bar.thumb.y + bar.thumb.height, .Before)
	testing.expect_value(t, result, ui.Scroll_Page.Off_Track)
	testing.expect_value(t, ui.scrollbar_side(bar, bar.thumb.y - 1), ui.Scroll_Side.Before)
	testing.expect_value(t, ui.scrollbar_side(bar, bar.thumb.y + 2), ui.Scroll_Side.None)
	// Off the track the page pauses, above and beside it alike.
	offset, result = ui.scrollbar_page(bar, bar.track.x - 1, bar.thumb.y - 1, .Before)
	testing.expect_value(t, offset, 40)
	testing.expect_value(t, result, ui.Scroll_Page.Off_Track)
	_, result = ui.scrollbar_page(bar, x, -1, .After)
	testing.expect_value(t, result, ui.Scroll_Page.Off_Track)
	// A view that cannot go further toward the pointer reports it rather than a page.
	stale := bar
	stale.extent.offset = 0
	offset, result = ui.scrollbar_page(stale, x, stale.thumb.y - 1, .Before)
	testing.expect_value(t, offset, 0)
	testing.expect_value(t, result, ui.Scroll_Page.Stuck)

	// Repeating toward a fixed pointer pages every time and stops with the thumb under it, from either
	// side, in the fewest whole pages; moving the pointer retargets it.
	area := render.Rect{0, 0, 100, 200}
	pointer := f32(120)
	view := 0
	for steps in 0 ..< 100 {
		b, _ := ui.scrollbar_layout(area, {total = 100, visible = 10, offset = view}, .Collapsed, 1)
		next, page := ui.scrollbar_page(b, x, pointer, .After)
		if page != .Paged {
			testing.expect_value(t, page, ui.Scroll_Page.On_Thumb)
			testing.expect(t, pointer >= b.thumb.y && pointer < b.thumb.y + b.thumb.height)
			testing.expect(t, steps > 1)
			break
		}
		testing.expect(t, next > view)
		view = next
		testing.expect(t, steps < 99)
	}
	pointer = 10
	before := view
	for _ in 0 ..< 100 {
		b, _ := ui.scrollbar_layout(area, {total = 100, visible = 10, offset = view}, .Collapsed, 1)
		next, page := ui.scrollbar_page(b, x, pointer, .Before)
		if page != .Paged {break}
		testing.expect(t, next < view)
		view = next
	}
	testing.expect(t, view < before)

	// A horizontal bar pages along x.
	wide, _ := ui.scrollbar_layout_horizontal({0, 0, 200, 100}, {total = 100, visible = 10, offset = 40}, .Collapsed, 1)
	y := wide.track.y + 2
	offset, result = ui.scrollbar_page(wide, wide.thumb.x - 1, y, .Before)
	testing.expect_value(t, offset, 30)
	testing.expect_value(t, result, ui.Scroll_Page.Paged)
	offset, result = ui.scrollbar_page(wide, wide.thumb.x + wide.thumb.width, y, .After)
	testing.expect_value(t, offset, 50)
	testing.expect_value(t, result, ui.Scroll_Page.Paged)
	_, result = ui.scrollbar_page(wide, wide.thumb.x + 2, y, .Before)
	testing.expect_value(t, result, ui.Scroll_Page.On_Thumb)
}

@(test)
palette_scrollbar_pages_drags_and_keeps_rows_clear :: proc(t: ^testing.T) {
	registry := registry_create(t)
	defer commands.destroy(&registry)
	rows: [len(settings.SCHEMA)]ui.Palette_Setting
	for entry, i in settings.SCHEMA {
		rows[i] = {key = entry.key, title = entry.title, group = settings.group_title(entry.key)}
	}
	p: ui.Palette
	if !testing.expect_value(t, ui.palette_init(&p, rows[:]), nil) {return}
	defer ui.palette_destroy(&p)
	ui.palette_open(&p, &registry)
	ui.palette_text(&p, &registry, "setting")
	l := ui.palette_layout(&p, 1000, 800, 1)
	if !testing.expect(t, l.bar_visible && len(p.results) > p.visible_rows) {return}
	testing.expect(t, l.list.x + l.list.width <= l.bar.track.x)
	testing.expect(t, l.bar.track.x + l.bar.track.width <= l.panel.x + l.panel.width)
	x := l.bar.track.x + 2

	testing.expect_value(t, ui.palette_mouse_move(&p, l, x, l.bar.track.y + 1), ui.Outcome.Changed)
	testing.expect(t, p.scroll_hover)
	outcome, _ := ui.palette_mouse_press(&p, &registry, l, x, l.bar.track.y + l.bar.track.height - 1)
	testing.expect_value(t, outcome, ui.Outcome.Changed)
	testing.expect_value(t, p.scroll, p.visible_rows)
	testing.expect(t, p.selected >= p.scroll && p.selected < p.scroll + p.visible_rows)

	l = ui.palette_layout(&p, 1000, 800, 1)
	_, _ = ui.palette_mouse_press(&p, &registry, l, x, l.bar.thumb.y + 1)
	_, holding := p.drag.(ui.Scrollbar_Drag)
	testing.expect(t, holding)
	testing.expect_value(t, ui.palette_scrollbar_drag(&p, l, x, 10000), ui.Outcome.Changed)
	testing.expect_value(t, p.scroll, len(p.results) - p.visible_rows)
	l = ui.palette_layout(&p, 1000, 800, 1)
	testing.expect_value(t, p.scroll, len(p.results) - p.visible_rows)
	// Released away from the track, the bar collapses without another pointer move.
	_ = ui.palette_scrollbar_drag(&p, l, x - 500, -10000)
	testing.expect_value(t, p.scroll, 0)
	testing.expect_value(t, ui.palette_pointer_release(&p), ui.Outcome.Changed)
	testing.expect(t, p.drag == nil)
	testing.expect_value(t, ui.palette_scrollbar_state(&p), ui.Scrollbar_State.Collapsed)

	ui.palette_text(&p, &registry, "zzzzzzzz-nothing")
	l = ui.palette_layout(&p, 1000, 800, 1)
	testing.expect(t, !l.bar_visible)
}

@(test)
choice_dropdown_scrollbar_pages_drags_and_keeps_options_clear :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	choices: [40]string
	for &choice, i in choices {choice = fmt.tprintf("Font %02d", i)}
	testing.expect_value(t, ui.editor_add(&p, {
		key = "font.family", title = "Shell Font", kind = .Choice, searchable = true,
		font_filter = true, choice_min_width = 360,
		value = choices[0], choices = choices[:],
	}, "Font"), nil)
	ui.editor_filter(&p)
	testing.expect(t, ui.editor_select_key(&p, "font.family"))
	l := page(&p)
	ui.editor_key(&p, key({key = .Enter}))
	popup := ui.editor_popup_rect(&p, l)
	// The track is the popup's right edge, so the area just inside it is the bar.
	x := popup.x + popup.width - 4
	bottom := popup.y + popup.height - 8

	testing.expect(t, ui.editor_hover(&p, l, x, bottom))
	testing.expect(t, p.dropdown.bar_hover)
	testing.expect(t, ui.editor_hover(&p, l, x - 20, bottom))
	testing.expect(t, !p.dropdown.bar_hover)

	testing.expect_value(t, ui.editor_press(&p, l, nil, x, bottom, false), ui.Editor_Outcome.Changed)
	testing.expect(t, p.dropdown.list.scroll > 0)
	testing.expect(t, p.dropdown.list.index >= p.dropdown.list.scroll)
	testing.expect(t, !ui.editor_dragging(&p))

	top := p.dropdown.list.scroll
	testing.expect_value(t, ui.editor_press(&p, l, nil, x, popup.y + 68 + 6, false), ui.Editor_Outcome.Changed)
	testing.expect(t, p.dropdown.list.scroll < top)

	// At the top, the thumb starts at the track's top, so a press there grabs it.
	for p.dropdown.list.scroll > 0 {_ = ui.editor_press(&p, l, nil, x, popup.y + 68 + 6, false)}
	testing.expect_value(t, ui.editor_press(&p, l, nil, x, popup.y + 68 + 6, false), ui.Editor_Outcome.Changed)
	testing.expect(t, ui.editor_scrollbar_dragging(&p))
	testing.expect(t, ui.editor_drag(&p, l, nil, x + 500, 10000))
	testing.expect_value(t, ui.editor_release(&p), ui.Editor_Outcome.Changed)
	testing.expect(t, !ui.editor_dragging(&p))
	// A drag past the window's edge reaches the end: the wheel can scroll no further.
	end := p.dropdown.list.scroll
	ui.editor_wheel(&p, l, popup.x + 10, popup.y + 80, -100)
	testing.expect_value(t, p.dropdown.list.scroll, end)
	testing.expect(t, end > top)
	testing.expect_value(t, ui.field_string(&p.value), "Font 00")
}
