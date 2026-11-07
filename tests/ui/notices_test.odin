package ui_test

import "base:runtime"
import "core:testing"
import "aio:font"
import "aio:glyphs"
import "aio:render"
import "aio:term_view"
import "aio:ui"
import "core:time"
import fixtures "../fixtures"

@(private)
Notice_Allocations :: struct { backing: runtime.Allocator, calls: int }

@(private)
notice_allocator :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int,
	old_memory: rawptr, old_size: int, location := #caller_location) -> ([]u8, runtime.Allocator_Error) {
	state := cast(^Notice_Allocations)data
	if mode == .Alloc || mode == .Alloc_Non_Zeroed || mode == .Resize || mode == .Resize_Non_Zeroed {
		state.calls += 1
	}
	return state.backing.procedure(state.backing.data, mode, size, alignment, old_memory, old_size, location)
}

@(test)
notice_severities_have_unique_words_symbols_and_readable_theme_colors :: proc(t: ^testing.T) {
	for file in fixtures.SHIPPED_THEMES {
		{
			resolved := fixtures.shipped_theme_file(file) or_continue
			theme := ui.theme_from(resolved)
			for kind in ui.Notice_Kind {
				label, symbol, color := ui.notice_style(kind, theme)
				testing.expect(t, len(label) > 0)
				testing.expectf(t, term_view.contrast_ratio(color, theme.surface) >= 4.5,
					"%v %v label contrast", file.name, kind)
				for other in ui.Notice_Kind {
					if other == kind { continue }
					other_label, other_symbol, other_color := ui.notice_style(other, theme)
					testing.expect(t, label != other_label && symbol != other_symbol && color != other_color)
				}
			}
		}
	}
}

@(test)
notices_hold_a_removed_clone_until_its_close_settles :: proc(t: ^testing.T) {
	n: ui.Notices
	ui.notices_init(&n)
	defer ui.notices_destroy(&n)
	ui.notices_set_animations(&n, true)
	now := time.tick_now()
	ui.notices_put(&n, 1, .Info, "closing", 0)
	ui.notices_animate(&n, now)
	testing.expect_value(t, len(ui.notices_live(&n)), 1)
	testing.expect(t, ui.notices_clear(&n, 1))
	testing.expect_value(t, len(ui.notices_live(&n)), 0)
	if !testing.expect_value(t, len(n.items), 1) {return}
	testing.expect(t, ui.notice_fading(n.items[0]))
	testing.expect(t, !ui.notices_clear(&n, 1), "a fading notice is no longer shown under its key")
	testing.expect(t, ui.notices_animating(&n))
	testing.expect(t, ui.notices_animate(&n, time.tick_add(now, time.Second)))
	testing.expect_value(t, len(n.items), 0)
	testing.expect(t, !ui.notices_animating(&n))
	testing.expect(t, !ui.notices_animate(&n, time.tick_add(now, 2*time.Second)))
	testing.expect_value(t, len(n.items), 0)
}

@(test)
notices_without_animations_free_a_removed_clone_immediately :: proc(t: ^testing.T) {
	n: ui.Notices
	ui.notices_init(&n)
	defer ui.notices_destroy(&n)
	ui.notices_put(&n, 1, .Info, "snapped", 0)
	testing.expect_value(t, len(n.items), 1)
	testing.expect(t, ui.notices_clear(&n, 1))
	testing.expect_value(t, len(n.items), 0)
	testing.expect(t, !ui.notices_animating(&n))
}

@(test)
notices_fade_behind_live_notices_and_turning_animations_off_settles_every_motion :: proc(t: ^testing.T) {
	n: ui.Notices
	ui.notices_init(&n)
	defer ui.notices_destroy(&n)
	ui.notices_set_animations(&n, true)
	ui.notices_put(&n, 0, .Info, "first", time.Hour)
	ui.notices_put(&n, 0, .Info, "second", 0)
	first := n.items[0].id
	testing.expect(t, ui.notices_dismiss(&n, first))
	ui.notices_put(&n, 0, .Info, "third", time.Hour)
	// The fading notice stays at the bottom of the stack while new ones arrive above it.
	if !testing.expect_value(t, len(n.items), 3) {return}
	testing.expect_value(t, n.items[0].text, "second")
	testing.expect_value(t, n.items[1].text, "third")
	testing.expect_value(t, n.items[2].id, first)
	testing.expect_value(t, len(ui.notices_live(&n)), 2)
	testing.expect(t, !ui.notices_dismiss(&n, first))
	deadline, timed := ui.notices_deadline(&n)
	testing.expect(t, timed && deadline == ui.notice_expiry(n.items[1]).?)
	ui.notices_set_animations(&n, false)
	testing.expect_value(t, len(n.items), 2)
	testing.expect(t, !ui.notices_animating(&n))
}

@(test)
notices_fading_notice_drops_its_hover_and_armed_press :: proc(t: ^testing.T) {
	n: ui.Notices
	ui.notices_init(&n)
	defer ui.notices_destroy(&n)
	ui.notices_set_animations(&n, true)
	ui.notices_put(&n, 0, .Info, "timed", time.Millisecond)
	ui.notices_put(&n, 0, .Info, "sticky", 0)
	timed, sticky := n.items[0].id, n.items[1].id
	testing.expect(t, ui.notices_hover(&n, timed))
	ui.notices_press(&n, timed)
	testing.expect(t, ui.notices_expire(&n, time.tick_add(time.tick_now(), time.Second)))
	if !testing.expect_value(t, n.items[1].id, timed) {return}
	testing.expect(t, ui.notice_fading(n.items[1]))
	testing.expect_value(t, n.hover, u64(0))
	testing.expect(t, !ui.armed_is(n.armed, timed), "a press must not stay armed on a fading notice")
	testing.expect(t, !ui.notices_release(&n, timed))
	// Another notice's pointer state survives that fade.
	testing.expect(t, ui.notices_hover(&n, sticky))
	ui.notices_press(&n, sticky)
	testing.expect(t, ui.notices_release(&n, sticky))
	testing.expect_value(t, len(ui.notices_live(&n)), 0)
}

@(test)
notices_render_all_severities_with_bounded_reused_storage_at_multiple_scales :: proc(t: ^testing.T) {
	allocations := Notice_Allocations{backing = context.allocator}
	allocator := runtime.Allocator{notice_allocator, &allocations}
	fonts, font_error := font.system_create(allocator)
	if !testing.expect_value(t, font_error, font.Error.None) { return }
	defer font.system_destroy(fonts)
	device, device_error := render.device_create()
	if !testing.expect_value(t, device_error, render.Error.None) { return }
	defer render.device_destroy(device)
	cache: glyphs.Cache
	glyphs.init(&cache, fonts, device, allocator)
	defer glyphs.destroy(&cache)
	text: ui.Text
	if !testing.expect(t, ui.text_init(&text, fonts, &cache, 16)) { return }
	n: ui.Notices
	ui.notices_init(&n, allocator)
	defer ui.notices_destroy(&n)
	list := render.draw_list_init(allocator)
	defer render.draw_list_destroy(&list)
	for kind in ui.Notice_Kind {
		ui.notices_put(&n, u32(kind)+1, kind, "A useful message with enough text to wrap at narrow widths.", 0)
	}
	for scale in ([?]f32{1, 1.75}) {
		ui.text_set_size(&text, 16*scale)
		for width in ([?]f32{320, 1000}) {
			for id in ([?]string{"studio-dark", "studio-light"}) {
				theme := ui.theme_from(fixtures.shipped_theme(id))
				render.draw_list_reset(&list)
				testing.expect_value(t, ui.notices_draw(&n, &list, &text, theme,
					width*scale, 1000*scale, scale), glyphs.Result.Ok)
				testing.expect(t, len(list.glyphs) > 0)
				testing.expect_value(t, len(list.rects), 46)
				layers, rects, glyph_count, lines := cap(list.layers), cap(list.rects), cap(list.glyphs), cap(n.lines)
				calls := allocations.calls
				for _ in 0..<3 {
					render.draw_list_reset(&list)
					testing.expect_value(t, ui.notices_draw(&n, &list, &text, theme,
						width*scale, 1000*scale, scale), glyphs.Result.Ok)
					testing.expect_value(t, cap(list.layers), layers)
					testing.expect_value(t, cap(list.rects), rects)
					testing.expect_value(t, cap(list.glyphs), glyph_count)
					testing.expect_value(t, cap(n.lines), lines)
					testing.expect_value(t, allocations.calls, calls)
				}
			}
		}
	}
	for kind in ui.Notice_Kind {ui.notices_clear(&n, u32(kind)+1)}
	for scale in ([?]f32{1, 1.5, 2}) {
		ui.text_set_size(&text, 16*scale)
		for width in ([?]f32{160, 320, 1000}) {
			for message in ([?]string{"", "Copied", "A useful message with enough text to wrap at narrow widths. " +
				"This longer notice must remain bounded and keep its four-line limit."}) {
				ui.notices_put(&n, 1, .Success, message, 0)
				render.draw_list_reset(&list)
				theme := ui.theme_from(fixtures.shipped_theme("studio-dark"))
				testing.expect_value(t, ui.notices_draw(&n, &list, &text, theme,
					width*scale, 1000*scale, scale), glyphs.Result.Ok)
				box := list.rects[1].rect
				testing.expect(t, box.width <= min(520, width-32)*scale)
				testing.expect(t, box.x >= 16*scale)
				testing.expect_value(t, box.x+box.width, (width-16)*scale)
				label, _, _ := ui.notice_style(.Success, theme)
				strong := ui.text_styled(&text, .Strong)
				visible_width := ui.text_width(&strong, label)
				for line in n.lines[:min(len(n.lines), 4)] {
					visible_width = max(visible_width, ui.text_width(&text, line))
				}
				testing.expect_value(t, box.width, min(min(520, width-32)*scale, visible_width+84*scale))
				cx := box.x + box.width - 24*scale
				cy := box.y + 24*scale
				hit := ui.notices_hit(&n, &text, width*scale, 1000*scale, scale, cx, cy)
				testing.expect(t, hit.contains && hit.close)
				testing.expect_value(t, hit.id, n.items[0].id)
				testing.expect(t, !ui.notices_hit(&n, &text, width*scale, 1000*scale, scale,
					box.x-1, cy).contains)
				if len(message) < 10 && width == 1000 {testing.expect(t, box.width < 200*scale)}
			}
		}
	}
}

@(test)
notices_dismiss_one_anonymous_notice_and_ignore_stale_identity :: proc(t: ^testing.T) {
	n: ui.Notices
	ui.notices_init(&n)
	defer ui.notices_destroy(&n)
	ui.notices_put(&n, 0, .Info, "first", time.Hour)
	ui.notices_put(&n, 0, .Success, "second", 0)
	first, second := n.items[0].id, n.items[1].id
	testing.expect(t, first != second)
	testing.expect(t, ui.notices_dismiss(&n, first))
	testing.expect_value(t, len(n.items), 1)
	testing.expect_value(t, n.items[0].id, second)
	testing.expect(t, !ui.notices_dismiss(&n, first))
	testing.expect(t, ui.notices_dismiss(&n, second))
	testing.expect_value(t, len(n.items), 0)
	ui.notices_put(&n, 7, .Warning, "old", time.Hour)
	old := n.items[0].id
	ui.notices_put(&n, 7, .Error, "new", time.Hour)
	testing.expect(t, !ui.notices_dismiss(&n, old))
	testing.expect_value(t, len(n.items), 1)
	testing.expect_value(t, n.items[0].text, "new")
}
