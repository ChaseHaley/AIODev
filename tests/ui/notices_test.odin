package ui_test

import "base:runtime"
import "core:testing"
import "aio:font"
import "aio:glyphs"
import "aio:render"
import "aio:term_view"
import "aio:ui"
import "core:time"

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
	for file in SHIPPED_THEMES {
		{
			resolved := shipped_theme_file(file) or_continue
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
	testing.expect_value(t, len(n.items), 1)
	testing.expect(t, ui.notices_clear(&n, 1))
	testing.expect_value(t, len(n.items), 0)
	testing.expect_value(t, len(n.fading), 1)
	testing.expect(t, ui.notices_animating(&n))
	testing.expect(t, ui.notices_animate(&n, time.tick_add(now, time.Second)))
	testing.expect_value(t, len(n.fading), 0)
	testing.expect(t, !ui.notices_animating(&n))
	testing.expect(t, !ui.notices_animate(&n, time.tick_add(now, 2*time.Second)))
	testing.expect_value(t, len(n.fading), 0)
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
	testing.expect_value(t, len(n.fading), 0)
	testing.expect(t, !ui.notices_animating(&n))
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
				theme := ui.theme_from(shipped_theme(id))
				render.draw_list_reset(&list)
				testing.expect_value(t, ui.notices_draw(&n, &list, &text, theme,
					width*scale, 1000*scale, scale), glyphs.Result.Ok)
				testing.expect(t, len(list.glyphs) > 0)
				testing.expect_value(t, len(list.rects), 30)
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
}
