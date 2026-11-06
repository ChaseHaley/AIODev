package ui_test

import "core:mem"
import "core:testing"
import "aio:font"
import "aio:glyphs"
import "aio:input"
import "aio:platform"
import "aio:render"
import "aio:term_view"
import "aio:ui"
import fixtures "../fixtures"

@(test)
find_layout_stacks_before_inline_query_falls_below_minimum :: proc(t: ^testing.T) {
	for scale in ([?]f32{1, 1.25, 1.5, 2, 3}) {
		for width in ([?]f32{352, 353, 354, 355}) {
			l := ui.find_layout(width*scale, scale, 50*scale)
			if width < 354 {
				testing.expect(t, l.query.y < l.status.y)
			} else {
				testing.expect_value(t, l.query.y, l.status.y)
			}
			testing.expect(t, l.query.width >= 80*scale - 0.01)
			testing.expect_value(t, l.close.y, l.query.y)
			testing.expect_value(t, l.case_toggle.y, l.query.y)
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
				rects := [?]render.Rect{l.query, l.case_toggle, l.regex_toggle, l.status, l.older, l.newer,
					l.close}
				for r in rects {
					testing.expect(t, r.x >= l.panel.x && r.y >= l.panel.y)
					testing.expect(t, r.x+r.width <= l.panel.x+l.panel.width)
					testing.expect(t, r.y+r.height <= l.panel.y+l.panel.height)
				}
				for r in ([?]render.Rect{l.older, l.newer, l.close}) { testing.expect_value(t, r.width, 32*scale) }
				testing.expect(t, l.older.x+l.older.width <= l.newer.x)
				testing.expect(t, l.query.x+l.query.width <= l.case_toggle.x)
				testing.expect(t, l.case_toggle.x+l.case_toggle.width <= l.regex_toggle.x)
				testing.expect(t, l.regex_toggle.x+l.regex_toggle.width <= l.close.x)
				testing.expect(t, l.query.y != l.status.y || l.regex_toggle.x+l.regex_toggle.width <= l.status.x)
				testing.expect(t, l.status.y != l.older.y || l.status.x+l.status.width <= l.older.x)
				testing.expect(t, l.newer.y != l.close.y || l.newer.x+l.newer.width <= l.close.x)
			}
		}
	}
	for width in ([?]f32{0, 1, 10, 24, 50, 100}) {
		l := ui.find_layout(width, 2, 190)
		testing.expect(t, l.panel.x >= 0 && l.panel.x+l.panel.width <= width)
		testing.expect(t, l.query.width >= 0 && l.status.width >= 0 && l.older.width >= 0)
		testing.expect(t, l.close.width >= 0 && l.case_toggle.width >= 0)
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
	for file in fixtures.SHIPPED_THEMES {
		{
			resolved := fixtures.shipped_theme_file(file) or_continue
			theme := ui.theme_from(resolved)
			testing.expect(t, term_view.contrast_ratio(theme.text, theme.surface) >= 4.5)
			for scale in ([?]f32{1, 1.5, 2}) {
				ui.text_set_size(&text, 14*scale)
				for width in ([?]f32{240, 300, 1000}) {
					for status in ([?]string{"0 of 0", "123456 of 987654", "0 of 31 · Searching…"}) {
						render.draw_list_reset(&list)
						count := ui.text_styled(&text, .Detail)
						l := ui.find_layout(width*scale, scale, ui.text_width(&count, status))
						testing.expect_value(t, ui.find_draw(&f, &list, &text, theme, status, true,
							width*scale, 400*scale, scale), glyphs.Result.Ok)
						// Count glyphs are emitted first and must include every visible character without an ellipsis.
						visible := 0
						for r in status { if r != ' ' { visible += 1 } }
						if !testing.expect(t, len(list.glyphs) >= visible) { continue }
						for g in list.glyphs[:visible] {
							testing.expect_value(t, g.color, theme.muted)
							testing.expect(t, g.rect.x >= l.status.x-2*scale &&
								g.rect.x+g.rect.width <= l.status.x+l.status.width+2*scale)
						}
						// Two arrows of three strokes each, then the close cross.
						strokes := 0
						for r in list.rects {
							if r.fill != render.RECT_FILL_SEGMENT { continue }
							testing.expect_value(t, r.color, theme.muted)
							strokes += 1
						}
						testing.expect_value(t, strokes, 8)
						render.draw_list_reset(&list)
						testing.expect_value(t, ui.find_draw(&f, &list, &text, theme, status, false,
							width*scale, 400*scale, scale), glyphs.Result.Ok)
						// Without matches the arrows, drawn first, fade; close still works.
						stroke := 0
						for r in list.rects {
							if r.fill != render.RECT_FILL_SEGMENT { continue }
							testing.expect_value(t, r.color, stroke < 6 ? theme.faint : theme.muted)
							stroke += 1
						}
						testing.expect_value(t, stroke, 8)
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

@(test)
find_toggles_close_and_focus_respond_without_matches :: proc(t: ^testing.T) {
	f: ui.Find_Bar
	ui.find_init(&f)
	defer ui.find_destroy(&f)
	ui.find_open(&f)
	Outcome :: ui.Find_Outcome
	l := ui.find_layout(1000, 1, 100)
	click :: proc(f: ^ui.Find_Bar, l: ui.Find_Layout, r: render.Rect) -> ui.Find_Outcome {
		x, y := r.x+r.width/2, r.y+r.height/2
		ui.find_mouse(f, l, false, .Left, true, x, y)
		return ui.find_mouse(f, l, false, .Left, false, x, y)
	}
	testing.expect_value(t, click(&f, l, l.case_toggle), Outcome.Changed)
	testing.expect(t, f.case_sensitive && !f.regex)
	testing.expect_value(t, click(&f, l, l.regex_toggle), Outcome.Changed)
	testing.expect(t, f.case_sensitive && f.regex)
	testing.expect_value(t, click(&f, l, l.older), Outcome.Moved)
	alt :: proc(k: input.Key) -> platform.Key_Event { return {key = k, modifiers = {.Alt}, pressed = true, text = "c"} }
	testing.expect_value(t, ui.find_key(&f, alt(.C)), Outcome.Changed)
	testing.expect_value(t, ui.find_key(&f, alt(.R)), Outcome.Changed)
	testing.expect(t, !f.case_sensitive && !f.regex)
	testing.expect_value(t, ui.field_string(&f.query), "")
	// AltGr arrives as Control+Alt and types its character.
	altgr := platform.Key_Event{key = .C, modifiers = {.Control, .Alt}, pressed = true, text = "\u00a9"}
	testing.expect_value(t, ui.find_key(&f, altgr), Outcome.Changed)
	testing.expect(t, !f.case_sensitive)
	testing.expect_value(t, ui.field_string(&f.query), "\u00a9")

	ui.find_blur(&f)
	testing.expect(t, ui.find_is_open(&f) && !ui.find_has_keyboard(&f))
	ui.find_mouse(&f, l, false, .Left, true, l.query.x+4, l.query.y+4)
	testing.expect(t, ui.find_has_keyboard(&f))
	ui.find_mouse(&f, l, false, .Left, false, l.query.x+4, l.query.y+4)
	testing.expect_value(t, click(&f, l, l.close), Outcome.Closed)
	testing.expect_value(t, ui.find_pointer(l, false, l.close.x+4, l.close.y+4), platform.Cursor_Shape.Hand)
	testing.expect_value(t, ui.find_pointer(l, false, l.older.x+4, l.older.y+4), platform.Cursor_Shape.Arrow)
}

@(test)
find_history_recalls_searches_like_a_prompt :: proc(t: ^testing.T) {
	h: ui.Find_History
	defer ui.find_history_destroy(&h)
	f: ui.Find_Bar
	ui.find_init(&f)
	defer ui.find_destroy(&f)
	Outcome :: ui.Find_Outcome
	up := platform.Key_Event{key = .Arrow_Up, pressed = true}
	down := platform.Key_Event{key = .Arrow_Down, pressed = true}
	enter := platform.Key_Event{key = .Enter, pressed = true}
	ui.find_open(&f, &h)
	ui.find_text(&f, "alpha")
	ui.find_key(&f, enter, &h)
	ui.find_text(&f, "2")
	f.regex = true
	ui.find_close(&f, &h)
	ui.find_open(&f, &h)
	testing.expect_value(t, ui.field_string(&f.query), "")
	ui.find_text(&f, "alpha")
	ui.find_blur(&f, &h)
	testing.expect_value(t, len(h.entries), 2)
	testing.expect_value(t, h.entries[0].query, "alpha2")
	testing.expect_value(t, h.entries[1].query, "alpha")

	ui.find_focus(&f)
	ui.field_set(&f.query, "draft")
	f.regex = false
	testing.expect_value(t, ui.find_key(&f, up, &h), Outcome.Changed)
	testing.expect_value(t, ui.field_string(&f.query), "alpha")
	testing.expect_value(t, ui.find_key(&f, up, &h), Outcome.Changed)
	testing.expect_value(t, ui.field_string(&f.query), "alpha2")
	testing.expect(t, f.regex)
	testing.expect_value(t, ui.find_key(&f, up, &h), Outcome.None)
	testing.expect_value(t, ui.find_key(&f, down, &h), Outcome.Changed)
	testing.expect_value(t, ui.find_key(&f, down, &h), Outcome.Changed)
	testing.expect_value(t, ui.field_string(&f.query), "draft")
	testing.expect(t, !f.regex)
	testing.expect_value(t, ui.find_key(&f, down, &h), Outcome.None)
	// The first step back skips a query equal to the newest entry.
	ui.field_set(&f.query, "alpha")
	ui.find_key(&f, up, &h)
	testing.expect_value(t, ui.field_string(&f.query), "alpha2")
	ui.find_close(&f, &h)
	testing.expect_value(t, h.entries[1].query, "alpha2")

	ui.find_open(&f, &h, restore = true)
	testing.expect_value(t, ui.field_string(&f.query), "alpha2")
	testing.expect_value(t, ui.field_selected_text(&f.query), "")
	ui.find_close(&f, &h)
	ui.find_open(&f, &h, select = true)
	testing.expect_value(t, ui.field_selected_text(&f.query), "alpha2")
	testing.expect_value(t, ui.find_text(&f, "beta"), Outcome.Changed)
	testing.expect_value(t, ui.field_string(&f.query), "beta")
}

// Browsing copies what was typed; whatever ends browsing frees the copy, rather than the next browse.
@(test)
find_history_browsing_frees_its_draft_when_it_ends :: proc(t: ^testing.T) {
	h: ui.Find_History
	defer ui.find_history_destroy(&h)
	f: ui.Find_Bar
	ui.find_init(&f)
	defer ui.find_destroy(&f)
	tracking: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracking, context.allocator)
	defer mem.tracking_allocator_destroy(&tracking)
	up := platform.Key_Event{key = .Arrow_Up, pressed = true}
	down := platform.Key_Event{key = .Arrow_Down, pressed = true}
	enter := platform.Key_Event{key = .Enter, pressed = true}
	ui.find_open(&f, &h)
	ui.find_text(&f, "older")
	ui.find_blur(&f, &h)
	// Each way out leaves the newest entry as the query, so recording it again allocates nothing.
	Way_Out :: enum {Past_Newest, Enter, Typing, Blur, Close}
	for way in Way_Out {
		context.allocator = mem.tracking_allocator(&tracking)
		if !ui.find_is_open(&f) {ui.find_open(&f, &h)}
		ui.find_focus(&f)
		ui.field_set(&f.query, "draft")
		testing.expect_value(t, ui.find_key(&f, up, &h), ui.Find_Outcome.Changed)
		testing.expect_value(t, ui.field_string(&f.query), "older")
		switch way {
		case .Past_Newest:
			ui.find_key(&f, down, &h)
			testing.expect_value(t, ui.field_string(&f.query), "draft")
		case .Enter:
			ui.find_key(&f, enter, &h)
		case .Typing:
			ui.find_text(&f, "!")
		case .Blur:
			ui.find_blur(&f, &h)
		case .Close:
			ui.find_close(&f, &h)
		}
		testing.expectf(t, len(tracking.allocation_map) == 0, "%v kept the draft", way)
		testing.expect_value(t, ui.find_key(&f, down, &h), ui.Find_Outcome.None)
	}
}
