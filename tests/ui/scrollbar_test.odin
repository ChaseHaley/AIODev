package ui_test

import "core:testing"
import "aio:commands"
import "aio:render"
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
	testing.expect(t, ui.palette_scrollbar_dragging(&p))
	testing.expect_value(t, ui.palette_scrollbar_drag(&p, l, 10000), ui.Outcome.Changed)
	testing.expect_value(t, p.scroll, len(p.results) - p.visible_rows)
	l = ui.palette_layout(&p, 1000, 800, 1)
	testing.expect_value(t, p.scroll, len(p.results) - p.visible_rows)
	_ = ui.palette_scrollbar_drag(&p, l, -10000)
	testing.expect_value(t, p.scroll, 0)
	testing.expect_value(t, ui.palette_pointer_release(&p), ui.Outcome.Changed)
	testing.expect(t, !ui.palette_scrollbar_dragging(&p))

	ui.palette_text(&p, &registry, "zzzzzzzz-nothing")
	l = ui.palette_layout(&p, 1000, 800, 1)
	testing.expect(t, !l.bar_visible)
}
