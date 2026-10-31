package ui_test

import "core:testing"
import "aio:font"
import "aio:glyphs"
import "aio:render"
import "aio:term_view"
import "aio:ui"

@(test)
find_layout_stacks_before_inline_query_falls_below_minimum :: proc(t: ^testing.T) {
	for scale in ([?]f32{1, 1.25, 1.5, 2, 3}) {
		for width in ([?]f32{250, 257, 258, 259}) {
			l := ui.find_layout(width*scale, scale, 50*scale)
			if width < 258 {
				testing.expect(t, l.query.y < l.status.y)
			} else {
				testing.expect_value(t, l.query.y, l.status.y)
			}
			testing.expect(t, l.query.width >= 80*scale)
		}
	}
}

@(test)
find_layout_reserves_count_and_usable_navigation_at_each_scale :: proc(t: ^testing.T) {
	for scale in ([?]f32{1, 1.25, 1.5, 2, 3}) {
		for width in ([?]f32{240, 300, 380, 460, 1000}) {
			for status_width in ([?]f32{0, 50, 140, 190}) {
				l := ui.find_layout(width*scale, scale, status_width*scale)
				testing.expect(t, l.panel.y >= 40*scale)
				testing.expect(t, l.status.width >= status_width*scale)
				for r in ([4]render.Rect{l.query, l.status, l.older, l.newer}) {
					testing.expect(t, r.x >= l.panel.x && r.y >= l.panel.y)
					testing.expect(t, r.x+r.width <= l.panel.x+l.panel.width)
					testing.expect(t, r.y+r.height <= l.panel.y+l.panel.height)
				}
				testing.expect_value(t, l.older.width, 32*scale)
				testing.expect_value(t, l.newer.width, 32*scale)
				testing.expect(t, l.older.x+l.older.width <= l.newer.x)
				testing.expect(t, l.query.y != l.status.y || l.query.x+l.query.width <= l.status.x)
				testing.expect(t, l.status.y != l.older.y || l.status.x+l.status.width <= l.older.x)
			}
		}
	}
	for width in ([?]f32{0, 1, 10, 24, 50, 100}) {
		l := ui.find_layout(width, 2, 190)
		testing.expect(t, l.panel.x >= 0 && l.panel.x+l.panel.width <= width)
		testing.expect(t, l.query.width >= 0 && l.status.width >= 0 && l.older.width >= 0)
	}
}

@(test)
find_draw_keeps_full_count_and_arrow_ink_in_narrow_scaled_themes :: proc(t: ^testing.T) {
	fonts, err := font.system_create()
	if !testing.expect_value(t, err, font.Error.None) { return }
	defer font.system_destroy(fonts)
	device, device_error := render.device_create()
	if !testing.expect_value(t, device_error, render.Error.None) { return }
	defer render.device_destroy(device)
	cache: glyphs.Cache
	glyphs.init(&cache, fonts, device)
	defer glyphs.destroy(&cache)
	text: ui.Text
	if !testing.expect(t, ui.text_init(&text, fonts, &cache, 14)) { return }
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	f: ui.Find_Bar
	ui.find_init(&f)
	defer ui.find_destroy(&f)
	ui.find_open(&f)
	ui.find_text(&f, "long query with a visible caret")
	for file in SHIPPED_THEMES {
		{
			resolved := shipped_theme_file(file) or_continue
			theme := ui.theme_from(resolved)
			testing.expect(t, term_view.contrast_ratio(theme.text, theme.surface) >= 4.5)
			for scale in ([?]f32{1, 1.5, 2}) {
				ui.text_set_size(&text, 14*scale)
				for width in ([?]f32{240, 300, 1000}) {
					for status in ([?]string{"0 of 0", "123456 of 987654", "0 of 0 · No matches", "0 of 31 · Searching…"}) {
						render.draw_list_reset(&list)
						input := ui.text_styled(&text, .Input)
						l := ui.find_layout(width*scale, scale, ui.text_width(&input, status))
						testing.expect_value(t, ui.find_draw(&f, &list, &text, theme, status, true,
							width*scale, 400*scale, scale), glyphs.Result.Ok)
						// Count glyphs are emitted first and must include every visible character without an ellipsis.
						visible := 0
						for r in status { if r != ' ' { visible += 1 } }
						if !testing.expect(t, len(list.glyphs) >= visible) { continue }
						for g in list.glyphs[:visible] {
							testing.expect_value(t, g.color, theme.text)
							testing.expect(t, g.rect.x >= l.status.x-2*scale &&
								g.rect.x+g.rect.width <= l.status.x+l.status.width+2*scale)
						}
						arrows := 0
						for r in list.rects {
							if r.fill != render.RECT_FILL_SEGMENT { continue }
							testing.expect_value(t, r.color, theme.muted)
							arrows += 1
						}
						testing.expect_value(t, arrows, 6)
						render.draw_list_reset(&list)
						testing.expect_value(t, ui.find_draw(&f, &list, &text, theme, status, false,
							width*scale, 400*scale, scale), glyphs.Result.Ok)
						for r in list.rects {
							if r.fill == render.RECT_FILL_SEGMENT { testing.expect_value(t, r.color, theme.faint) }
						}
					}
				}
			}
		}
	}
}

@(test)
find_pointer_requires_matching_release_and_disables_without_matches :: proc(t: ^testing.T) {
	f: ui.Find_Bar
	ui.find_init(&f)
	defer ui.find_destroy(&f)
	ui.find_open(&f)
	l := ui.find_layout(1000, 1, 100)
	x, y := l.older.x+16, l.older.y+16
	next := l.newer.x+16
	Outcome :: ui.Find_Outcome
	testing.expect(t, ui.find_hover(&f, l, true, x, y))
	testing.expect_value(t, f.hover, Outcome.Older)
	testing.expect(t, !ui.find_hover(&f, l, true, x, y))
	testing.expect_value(t, ui.find_mouse(&f, l, true, .Right, true, x, y), Outcome.None)
	testing.expect_value(t, ui.find_mouse(&f, l, true, .Left, false, x, y), Outcome.Moved)
	testing.expect_value(t, ui.find_mouse(&f, l, true, .Left, true, x, y), Outcome.Moved)
	testing.expect_value(t, ui.find_mouse(&f, l, true, .Left, false, next, y), Outcome.Moved)
	ui.find_mouse(&f, l, true, .Left, true, x, y)
	testing.expect_value(t, ui.find_mouse(&f, l, true, .Left, false, x, y), Outcome.Older)
	ui.find_mouse(&f, l, true, .Left, true, next, y)
	testing.expect_value(t, ui.find_mouse(&f, l, true, .Left, false, next, y), Outcome.Newer)
	ui.find_mouse(&f, l, true, .Left, true, x, y)
	testing.expect_value(t, ui.find_mouse(&f, l, false, .Left, false, x, y), Outcome.Moved)
	ui.find_mouse(&f, l, false, .Left, true, next, y)
	testing.expect_value(t, ui.armed_target(f.armed), Outcome.None)
	testing.expect(t, ui.armed_down(f.armed))
	testing.expect_value(t, ui.find_mouse(&f, l, true, .Left, false, next, y), Outcome.Moved)
	ui.find_mouse(&f, l, true, .Left, true, x, y)
	testing.expect_value(t, ui.find_mouse(&f, l, true, .Left, false, 0, 0), Outcome.Moved)
	ui.find_close(&f)
	testing.expect(t, !ui.armed_down(f.armed))
	testing.expect_value(t, ui.armed_target(f.armed), Outcome.None)
	testing.expect_value(t, f.hover, Outcome.None)
}
