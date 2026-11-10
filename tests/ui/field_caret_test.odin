package ui_test

import "aio:caret"
import "aio:font"
import "aio:glyphs"
import "aio:render"
import "aio:ui"
import "core:testing"
import "core:time"

@(private = "file")
CARET_ACCENT :: render.Color{0.25, 0.5, 1, 1}

// The caret's head: the opaque accent rect a focused field draws last.
@(private = "file")
caret_head :: proc(list: ^render.Draw_List) -> (render.Rect, bool) {
	#reverse for instance in list.rects {
		if instance.color == CARET_ACCENT {return instance.rect, true}
	}
	return {}, false
}

@(private = "file")
caret_draw :: proc(
	t: ^testing.T, field: ^ui.Text_Field, list: ^render.Draw_List, text: ^ui.Text, focused := true,
) -> render.Rect {
	render.draw_list_reset(list)
	_ = render.push_layer(list, {0, 0, 800, 100})
	testing.expect_value(t, ui.field_draw(field, list, text, {accent = CARET_ACCENT}, 10, 30, 400, focused,
		"", {1, 1, 1, 1}, 2), render.Build_Status.Ok)
	head, _ := caret_head(list)
	return head
}

// A caret glides between the places consecutive builds of its window draw it, with the terminal's
// cursor settings, and appears in place after any build that did not show it or without animation.
@(test)
field_caret_moves_like_the_terminal_cursor :: proc(t: ^testing.T) {
	fonts, err := font.system_create()
	if !testing.expect_value(t, err, font.Error.None) {return}
	defer font.system_destroy(fonts)
	device, device_error := render.device_create(.Warp)
	if !testing.expect_value(t, device_error, render.Error.None) {return}
	defer render.device_destroy(device)
	cache: glyphs.Cache
	glyphs.init(&cache, fonts, device)
	defer glyphs.destroy(&cache)
	text: ui.Text
	if !testing.expect(t, ui.text_init(&text, fonts, &cache, 16)) {return}
	carets: ui.Carets
	text.carets = &carets
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	field: ui.Text_Field
	defer delete(field.bytes)
	ui.field_set(&field, "a longer query")

	period := render.FRAME_PERIOD_DEFAULT
	smooth := caret.Effects{preset = .Smooth, duration = 4 * period, movement = true}
	start := time.tick_add({}, time.Second)
	at :: proc(start: time.Tick, n: int) -> render.Frame_Time {
		return render.frame_time_at(time.tick_add(start, time.Duration(n) * render.FRAME_PERIOD_DEFAULT))
	}
	ui.carets_begin(&carets, smooth, at(start, 0))
	end := caret_draw(t, &field, &list, &text)
	testing.expect(t, !carets.moving, "a caret's first appearance must not move")

	field.cursor, field.anchor = 0, 0
	ui.carets_begin(&carets, smooth, at(start, 1))
	gliding := caret_draw(t, &field, &list, &text)
	testing.expect(t, carets.moving)
	testing.expectf(t, gliding.x > 10 && gliding.x < end.x, "head at %v between 10 and %v", gliding.x, end.x)
	// A retried build of the same frame draws the same pose and keeps it moving.
	testing.expect_value(t, caret_draw(t, &field, &list, &text), gliding)
	testing.expect(t, carets.moving)
	for n in 2 ..< 4 {
		ui.carets_begin(&carets, smooth, at(start, n))
		_ = caret_draw(t, &field, &list, &text)
		testing.expect(t, carets.moving)
	}
	ui.carets_begin(&carets, smooth, at(start, 4))
	home := caret_draw(t, &field, &list, &text)
	testing.expect(t, !carets.moving)
	testing.expect_value(t, home.x, f32(10))

	// A build that did not show the caret ends its motion: the next one draws it where it is.
	ui.carets_begin(&carets, smooth, at(start, 5))
	field.cursor, field.anchor = len(field.bytes), len(field.bytes)
	ui.carets_begin(&carets, smooth, at(start, 6))
	testing.expect_value(t, caret_draw(t, &field, &list, &text), end)
	testing.expect(t, !carets.moving)
	// So does an unfocused build.
	ui.carets_begin(&carets, smooth, at(start, 7))
	_ = caret_draw(t, &field, &list, &text, focused = false)
	field.cursor, field.anchor = 0, 0
	ui.carets_begin(&carets, smooth, at(start, 8))
	testing.expect_value(t, caret_draw(t, &field, &list, &text).x, f32(10))
	testing.expect(t, !carets.moving)

	// Off, and Smooth without movement, draw the caret in place.
	off := caret.Effects{duration = 4 * period, movement = true}
	still := caret.Effects{preset = .Smooth, duration = 4 * period}
	for effects in ([2]caret.Effects{off, still}) {
		field.cursor, field.anchor = len(field.bytes), len(field.bytes)
		ui.carets_begin(&carets, effects, at(start, 9))
		testing.expect_value(t, caret_draw(t, &field, &list, &text), end)
		field.cursor, field.anchor = 0, 0
		ui.carets_begin(&carets, effects, at(start, 10))
		testing.expect_value(t, caret_draw(t, &field, &list, &text).x, f32(10))
		testing.expect(t, !carets.moving)
	}
}

// A smear stretches between where the caret was and where it goes, while its head lands at once.
@(test)
field_caret_smears_between_its_places :: proc(t: ^testing.T) {
	fonts, err := font.system_create()
	if !testing.expect_value(t, err, font.Error.None) {return}
	defer font.system_destroy(fonts)
	device, device_error := render.device_create(.Warp)
	if !testing.expect_value(t, device_error, render.Error.None) {return}
	defer render.device_destroy(device)
	cache: glyphs.Cache
	glyphs.init(&cache, fonts, device)
	defer glyphs.destroy(&cache)
	text: ui.Text
	if !testing.expect(t, ui.text_init(&text, fonts, &cache, 16)) {return}
	carets: ui.Carets
	text.carets = &carets
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	field: ui.Text_Field
	defer delete(field.bytes)
	ui.field_set(&field, "a longer query")

	smear := caret.Effects{preset = .Smear, duration = 4 * render.FRAME_PERIOD_DEFAULT, strength = 1}
	start := time.tick_add({}, time.Second)
	ui.carets_begin(&carets, smear, render.frame_time_at(start))
	end := caret_draw(t, &field, &list, &text)
	field.cursor, field.anchor = 0, 0
	ui.carets_begin(&carets, smear, render.frame_time_at(time.tick_add(start, render.FRAME_PERIOD_DEFAULT)))
	head := caret_draw(t, &field, &list, &text)
	testing.expect(t, carets.moving)
	testing.expect_value(t, head.x, f32(10))
	reach := f32(0)
	for instance in list.rects {
		if instance.color.rgb != CARET_ACCENT.rgb || instance.color.a >= 1 {continue}
		testing.expect(t, instance.color.a > 0)
		reach = max(reach, instance.rect.x + instance.rect.width)
	}
	testing.expectf(t, reach > head.x + head.width && reach <= end.x + end.width, "smear reaches %v", reach)
}
