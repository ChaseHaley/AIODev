package ui_test

import "aio:colour"
import "base:runtime"
import "core:testing"
import "aio:font"
import "aio:glyphs"
import "aio:render"
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

// Without a severity word, the symbol and colour alone tell severities apart, and the tinted card keeps
// its text, its symbol and its action button readable in every shipped theme.
@(test)
notice_severities_have_unique_symbols_and_readable_tinted_cards :: proc(t: ^testing.T) {
	for file in fixtures.SHIPPED_THEMES {
		{
			resolved := fixtures.shipped_theme_file(file) or_continue
			theme := ui.theme_from(resolved, fixtures.default_interface())
			for kind in ui.Notice_Kind {
				symbol, color := ui.notice_style(kind, theme)
				fill, _ := ui.notice_surface(color, theme)
				testing.expectf(t, colour.contrast_ratio(theme.text, fill) >= 4.5, "%v %v text", file.name, kind)
				testing.expectf(t, colour.contrast_ratio(color, fill) >= 3, "%v %v symbol", file.name, kind)
				testing.expectf(t, colour.contrast_ratio(theme.surface, color) >= 4.5, "%v %v action", file.name, kind)
				for other in ui.Notice_Kind {
					if other == kind { continue }
					other_symbol, other_color := ui.notice_style(other, theme)
					testing.expect(t, symbol != other_symbol && color != other_color)
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
	now := time.tick_now()
	ui.notices_put(&n, 1, .Info, "closing", 0, true, now)
	// Its first frame starts the entry; midway through it, the close has a fade to run.
	ui.notices_animate(&n, true, test_frame(now))
	later := time.tick_add(now, 50*time.Millisecond)
	ui.notices_animate(&n, true, test_frame(later))
	testing.expect_value(t, len(ui.notices_live(&n)), 1)
	testing.expect(t, ui.notices_clear(&n, 1, true))
	testing.expect_value(t, len(ui.notices_live(&n)), 0)
	if !testing.expect_value(t, len(n.items), 1) {return}
	testing.expect(t, ui.notice_fading(n.items[0]))
	testing.expect(t, !ui.notices_clear(&n, 1, true), "a fading notice is no longer shown under its key")
	testing.expect(t, ui.notices_animating(&n))
	// The fade starts with the next frame and holds the clone until it settles.
	testing.expect(t, ui.notices_animate(&n, true, test_frame(time.tick_add(later, TEST_FRAME_PERIOD))))
	testing.expect_value(t, len(n.items), 1)
	testing.expect(t, ui.notices_animate(&n, true, test_frame(time.tick_add(now, time.Second))))
	testing.expect_value(t, len(n.items), 0)
	testing.expect(t, !ui.notices_animating(&n))
	testing.expect(t, !ui.notices_animate(&n, true, test_frame(time.tick_add(now, 2*time.Second))))
	testing.expect_value(t, len(n.items), 0)
}

@(test)
notices_without_animations_free_a_removed_clone_immediately :: proc(t: ^testing.T) {
	n: ui.Notices
	ui.notices_init(&n)
	defer ui.notices_destroy(&n)
	now := time.tick_now()
	ui.notices_put(&n, 1, .Info, "snapped", 0, false, now)
	testing.expect_value(t, len(n.items), 1)
	testing.expect(t, ui.notices_clear(&n, 1, false))
	testing.expect_value(t, len(n.items), 0)
	testing.expect(t, !ui.notices_animating(&n))
}

@(test)
notices_fade_behind_live_notices_and_turning_animations_off_settles_every_motion :: proc(t: ^testing.T) {
	n: ui.Notices
	ui.notices_init(&n)
	defer ui.notices_destroy(&n)
	now := time.tick_now()
	later := time.tick_add(now, 50*time.Millisecond)
	ui.notices_put(&n, 0, .Info, "first", time.Hour, true, now)
	ui.notices_put(&n, 0, .Info, "second", 0, true, now)
	// Drawn once, so the dismissed notice has a fade to run.
	ui.notices_animate(&n, true, test_frame(now))
	first := n.items[0].id
	testing.expect(t, ui.notices_dismiss(&n, first, true))
	ui.notices_put(&n, 0, .Info, "third", time.Hour, true, later)
	// The fading notice stays at the bottom of the stack while new ones arrive above it.
	if !testing.expect_value(t, len(n.items), 3) {return}
	testing.expect_value(t, n.items[0].text, "second")
	testing.expect_value(t, n.items[1].text, "third")
	testing.expect_value(t, n.items[2].id, first)
	testing.expect_value(t, len(ui.notices_live(&n)), 2)
	testing.expect(t, !ui.notices_dismiss(&n, first, true))
	deadline, timed := ui.notices_deadline(&n)
	testing.expect(t, timed && deadline == ui.notice_expiry(n.items[1]).?)
	ui.notices_animate(&n, false, test_frame(now))
	testing.expect_value(t, len(n.items), 2)
	testing.expect(t, !ui.notices_animating(&n))
}

@(test)
notices_fading_notice_drops_its_hover_and_armed_press :: proc(t: ^testing.T) {
	n: ui.Notices
	ui.notices_init(&n)
	defer ui.notices_destroy(&n)
	now := time.tick_now()
	ui.notices_put(&n, 0, .Info, "timed", time.Millisecond, true, now)
	ui.notices_put(&n, 0, .Info, "sticky", 0, true, now)
	// Drawn once, so each close has a fade to run.
	ui.notices_animate(&n, true, test_frame(now))
	timed := ui.Notice_Button{n.items[0].id, false}
	sticky := ui.Notice_Button{n.items[1].id, false}
	testing.expect(t, ui.notices_hover(&n, timed))
	ui.notices_press(&n, timed)
	testing.expect(t, ui.notices_expire(&n, true, time.tick_add(now, time.Second)))
	if !testing.expect_value(t, n.items[1].id, timed.id) {return}
	testing.expect(t, ui.notice_fading(n.items[1]))
	testing.expect_value(t, n.hover, ui.Notice_Button{})
	testing.expect(t, !ui.armed_is(n.armed, timed), "a press must not stay armed on a fading notice")
	dismissed, _ := ui.notices_release(&n, timed, true)
	testing.expect(t, !dismissed)
	// Another notice's pointer state survives that fade.
	testing.expect(t, ui.notices_hover(&n, sticky))
	ui.notices_press(&n, sticky)
	dismissed, _ = ui.notices_release(&n, sticky, true)
	testing.expect(t, dismissed)
	testing.expect_value(t, len(ui.notices_live(&n)), 0)
}

// An action button reports its notice's key once a press and release both land on it, and the notice
// leaves; the close button only dismisses.
@(test)
notices_action_button_reports_its_key_and_dismisses :: proc(t: ^testing.T) {
	n: ui.Notices
	ui.notices_init(&n)
	defer ui.notices_destroy(&n)
	now := time.tick_now()
	ui.notices_put(&n, 7, .Success, "Saved", time.Hour, false, now, "Undo", "Ctrl+Z")
	ui.notices_put(&n, 9, .Success, "Saved", time.Hour, false, now, "Undo", "Ctrl+Z")
	first, second := n.items[0].id, n.items[1].id
	testing.expect(t, ui.notices_showing(&n, 7))
	ui.notices_press(&n, {first, true})
	dismissed, acted := ui.notices_release(&n, {first, false}, false)
	testing.expect(t, !dismissed && acted == 0, "a release on another button fires nothing")
	ui.notices_press(&n, {first, true})
	dismissed, acted = ui.notices_release(&n, {first, true}, false)
	testing.expect(t, dismissed)
	testing.expect_value(t, acted, u32(7))
	testing.expect(t, !ui.notices_showing(&n, 7))
	ui.notices_press(&n, {second, false})
	dismissed, acted = ui.notices_release(&n, {second, false}, false)
	testing.expect(t, dismissed)
	testing.expect_value(t, acted, u32(0))
}

@(test)
notices_render_all_severities_with_bounded_reused_storage_at_multiple_scales :: proc(t: ^testing.T) {
	allocations := Notice_Allocations{backing = context.allocator}
	allocator := runtime.Allocator{notice_allocator, &allocations}
	fonts, font_error := font.system_create(allocator)
	if !testing.expect_value(t, font_error, font.Error.None) { return }
	defer font.system_destroy(fonts)
	device, device_error := render.device_create(.Warp)
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
		message :: "A useful message with enough text to wrap at narrow widths."
		ui.notices_put(&n, u32(kind)+1, kind, message, 0, false, time.tick_now())
	}
	for scale in ([?]f32{1, 1.75}) {
		ui.text_set_size(&text, 16*scale)
		for width in ([?]f32{320, 1000}) {
			for id in ([?]string{"studio-dark", "studio-light"}) {
				theme := ui.theme_from(fixtures.shipped_theme(id), fixtures.default_interface())
				render.draw_list_reset(&list)
				testing.expect_value(t, ui.notices_draw(&n, &list, &text, theme,
					width*scale, 1000*scale, scale, time.tick_now(), true), render.Build_Status.Ok)
				testing.expect(t, len(list.glyphs) > 0)
				layers, rects, glyph_count, lines := cap(list.layers), cap(list.rects), cap(list.glyphs), cap(n.lines)
				calls := allocations.calls
				for _ in 0..<3 {
					render.draw_list_reset(&list)
					testing.expect_value(t, ui.notices_draw(&n, &list, &text, theme,
						width*scale, 1000*scale, scale, time.tick_now(), true), render.Build_Status.Ok)
					testing.expect_value(t, cap(list.layers), layers)
					testing.expect_value(t, cap(list.rects), rects)
					testing.expect_value(t, cap(list.glyphs), glyph_count)
					testing.expect_value(t, cap(n.lines), lines)
					testing.expect_value(t, allocations.calls, calls)
				}
			}
		}
	}
	for kind in ui.Notice_Kind {ui.notices_clear(&n, u32(kind)+1, false)}
	for scale in ([?]f32{1, 1.5, 2}) {
		ui.text_set_size(&text, 16*scale)
		for width in ([?]f32{160, 320, 1000}) {
			for message in ([?]string{"", "Copied", "A useful message with enough text to wrap at narrow widths. " +
				"This longer notice must remain bounded and keep its four-line limit."}) {
				ui.notices_put(&n, 1, .Success, message, 0, false, time.tick_now())
				render.draw_list_reset(&list)
				theme := ui.theme_from(fixtures.shipped_theme("studio-dark"), fixtures.default_interface())
				testing.expect_value(t, ui.notices_draw(&n, &list, &text, theme,
					width*scale, 1000*scale, scale, time.tick_now(), true), render.Build_Status.Ok)
				// Every card has the same width, whatever its text, so wrapping never changes.
				box := list.rects[1].rect
				testing.expect_value(t, box.width, min(440, width-32)*scale)
				testing.expect_value(t, box.x+box.width, (width-16)*scale)
				// The text stops at four lines.
				testing.expect(t, box.height <= (2*12+28)*scale + 4*text.line_height)
				cx := box.x + box.width - 20*scale
				cy := box.y + 26*scale
				hit := ui.notices_hit(&n, &text, width*scale, 1000*scale, scale, cx, cy)
				testing.expect(t, hit.contains && hit.close)
				testing.expect_value(t, hit.id, n.items[0].id)
				testing.expect(t, !ui.notices_hit(&n, &text, width*scale, 1000*scale, scale,
					box.x-1, cy).contains)
			}
		}
	}
}

@(test)
notices_dismiss_one_anonymous_notice_and_ignore_stale_identity :: proc(t: ^testing.T) {
	n: ui.Notices
	ui.notices_init(&n)
	defer ui.notices_destroy(&n)
	now := time.tick_now()
	ui.notices_put(&n, 0, .Info, "first", time.Hour, false, now)
	ui.notices_put(&n, 0, .Success, "second", 0, false, now)
	first, second := n.items[0].id, n.items[1].id
	testing.expect(t, first != second)
	testing.expect(t, ui.notices_dismiss(&n, first, false))
	testing.expect_value(t, len(n.items), 1)
	testing.expect_value(t, n.items[0].id, second)
	testing.expect(t, !ui.notices_dismiss(&n, first, false))
	testing.expect(t, ui.notices_dismiss(&n, second, false))
	testing.expect_value(t, len(n.items), 0)
	ui.notices_put(&n, 7, .Warning, "old", time.Hour, false, now)
	old := n.items[0].id
	ui.notices_put(&n, 7, .Error, "new", time.Hour, false, now)
	testing.expect(t, !ui.notices_dismiss(&n, old, false))
	testing.expect_value(t, len(n.items), 1)
	testing.expect_value(t, n.items[0].text, "new")
}

// The pointer over the deck stops every countdown; leaving resumes each with the time it had left, and a
// notice that arrived meanwhile runs its full time from then.
@(test)
notices_pause_while_the_pointer_is_over_the_deck_and_resume_the_time_left :: proc(t: ^testing.T) {
	n: ui.Notices
	ui.notices_init(&n)
	defer ui.notices_destroy(&n)
	now := time.tick_now()
	ui.notices_put(&n, 0, .Info, "first", 6*time.Second, false, now)
	testing.expect(t, !ui.notices_pointer_over(&n, false, now, false))
	over := time.tick_add(now, 2*time.Second)
	testing.expect(t, ui.notices_pointer_over(&n, true, over, false))
	testing.expect(t, !ui.notices_pointer_over(&n, true, over, false))
	_, timed := ui.notices_deadline(&n)
	testing.expect(t, !timed, "nothing is due while paused")
	testing.expect(t, !ui.notices_expire(&n, false, time.tick_add(now, time.Hour)))
	ui.notices_put(&n, 0, .Warning, "second", 12*time.Second, false, time.tick_add(over, 5*time.Second))
	left := time.tick_add(over, 10*time.Second)
	testing.expect(t, ui.notices_pointer_over(&n, false, left, false))
	live := ui.notices_live(&n)
	if !testing.expect_value(t, len(live), 2) {return}
	testing.expect_value(t, ui.notice_expiry(live[0]).?, time.tick_add(left, 4*time.Second))
	testing.expect_value(t, ui.notice_expiry(live[1]).?, time.tick_add(left, 12*time.Second))
	testing.expect(t, ui.notices_expire(&n, false, time.tick_add(left, 4*time.Second)))
	testing.expect_value(t, len(ui.notices_live(&n)), 1)
	// The deck emptying under the pointer ends the pause, so the next notice counts down.
	testing.expect(t, ui.notices_pointer_over(&n, true, left, false))
	ui.notices_dismiss(&n, ui.notices_live(&n)[0].id, false)
	ui.notices_put(&n, 0, .Info, "third", time.Second, false, left)
	testing.expect(t, ui.notices_expire(&n, false, time.tick_add(left, time.Second)))
}

@(private)
notice_text_open :: proc(t: ^testing.T, fonts: ^^font.System, device: ^^render.Device, cache: ^glyphs.Cache,
	text: ^ui.Text) -> bool {
	font_error: font.Error
	fonts^, font_error = font.system_create()
	if !testing.expect_value(t, font_error, font.Error.None) {return false}
	device_error: render.Error
	device^, device_error = render.device_create(.Warp)
	if !testing.expect_value(t, device_error, render.Error.None) {return false}
	glyphs.init(cache, fonts^, device^)
	return testing.expect(t, ui.text_init(text, fonts^, cache, 16))
}

// Closed, the cards behind the front one take its height and step up NOTICE_STEP each, two at most, so
// nothing shows below it; open, every card has its own height. The front card is the same height either
// way, and a card leaving the middle gives up its step at once.
@(test)
notices_closed_deck_steps_cards_at_the_front_height_and_closes_a_leaving_step :: proc(t: ^testing.T) {
	fonts: ^font.System
	device: ^render.Device
	cache: glyphs.Cache
	text: ui.Text
	defer {
		glyphs.destroy(&cache)
		if device != nil {render.device_destroy(device)}
		if fonts != nil {font.system_destroy(fonts)}
	}
	if !notice_text_open(t, &fonts, &device, &cache, &text) {return}
	n: ui.Notices
	ui.notices_init(&n)
	defer ui.notices_destroy(&n)
	now := time.tick_now()
	long :: "A useful message with enough text to wrap onto a second and maybe a third line of the card."
	ui.notices_put(&n, 0, .Info, "oldest", time.Hour, false, now)
	ui.notices_put(&n, 0, .Warning, long, time.Hour, false, now)
	ui.notices_put(&n, 0, .Error, long, time.Hour, false, now)
	ui.notices_put(&n, 0, .Success, "Saved", time.Hour, false, now, "Undo", "Ctrl+Z")
	_ = ui.notices_hit(&n, &text, 1000, 800, 1, 0, 0)
	cards := ui.notices_live(&n)
	front := cards[3].card.box
	testing.expect_value(t, front.y + front.height, f32(800 - 16))
	for depth in 1..=3 {
		card := cards[3 - depth].card
		testing.expect_value(t, card.box.height, front.height)
		testing.expect_value(t, card.box.y, front.y - f32(min(depth, 2) * 7))
		testing.expect(t, card.content == 0)
	}
	testing.expect(t, cards[0].card.panel == 0, "only two cards peek out")
	closed_front := front.height
	ui.notices_pointer_over(&n, true, now, false)
	_ = ui.notices_hit(&n, &text, 1000, 800, 1, 0, 0)
	testing.expect_value(t, cards[3].card.box.height, closed_front)
	for i in 0..<3 {
		upper, lower := cards[i].card.box, cards[i + 1].card.box
		testing.expect_value(t, upper.y + upper.height + 8, lower.y)
		testing.expect(t, cards[i].card.content == 1 && upper.width == lower.width)
	}
	testing.expect(t, cards[1].card.box.height > closed_front, "an open card has its own height")
	ui.notices_pointer_over(&n, false, now, false)
	ui.notices_dismiss(&n, cards[2].id, false)
	_ = ui.notices_hit(&n, &text, 1000, 800, 1, 0, 0)
	cards = ui.notices_live(&n)
	if !testing.expect_value(t, len(cards), 3) {return}
	testing.expect_value(t, cards[1].card.box.y, cards[2].card.box.y - 7)
	testing.expect_value(t, cards[0].card.box.y, cards[2].card.box.y - 14)
	testing.expect(t, cards[0].card.panel == 1, "the oldest card moves up into the freed step")
}

// In an open deck, the cards above one that leaves slide down into its room rather than jumping.
@(test)
notices_open_deck_eases_cards_into_a_leaving_cards_room :: proc(t: ^testing.T) {
	fonts: ^font.System
	device: ^render.Device
	cache: glyphs.Cache
	text: ui.Text
	defer {
		glyphs.destroy(&cache)
		if device != nil {render.device_destroy(device)}
		if fonts != nil {font.system_destroy(fonts)}
	}
	if !notice_text_open(t, &fonts, &device, &cache, &text) {return}
	n: ui.Notices
	ui.notices_init(&n)
	defer ui.notices_destroy(&n)
	now := time.tick_now()
	ui.notices_put(&n, 0, .Info, "oldest", time.Hour, false, now)
	ui.notices_put(&n, 0, .Warning, "middle", time.Hour, false, now)
	ui.notices_put(&n, 0, .Success, "newest", time.Hour, false, now)
	ui.notices_pointer_over(&n, true, now, false)
	_ = ui.notices_hit(&n, &text, 1000, 800, 1, 0, 0)
	oldest := ui.notices_live(&n)[0].card.box.y
	middle := ui.notices_live(&n)[1].card.box
	testing.expect(t, ui.notices_dismiss(&n, ui.notices_live(&n)[1].id, true))
	_ = ui.notices_hit(&n, &text, 1000, 800, 1, 0, 0)
	testing.expect_value(t, ui.notices_live(&n)[0].card.box.y, oldest)
	testing.expect(t, ui.notices_animating(&n))
	ui.notices_animate(&n, true, test_frame(now))
	ui.notices_animate(&n, true, test_frame(time.tick_add(now, 90*time.Millisecond)))
	_ = ui.notices_hit(&n, &text, 1000, 800, 1, 0, 0)
	halfway := ui.notices_live(&n)[0].card.box.y
	testing.expect(t, halfway > oldest && halfway < oldest + middle.height + 8, "the card is on its way")
	ui.notices_animate(&n, true, test_frame(time.tick_add(now, time.Second)))
	_ = ui.notices_hit(&n, &text, 1000, 800, 1, 0, 0)
	testing.expect_value(t, ui.notices_live(&n)[0].card.box.y, oldest + middle.height + 8)
}
