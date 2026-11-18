package ui_test

import "aio:caret"
import "aio:font"
import "aio:glyphs"
import "aio:render"
import "aio:ui"
import "core:testing"
import "core:time"

@(private = "file")
CURSOR :: render.Color{1, 0, 0, 1}
@(private = "file")
CURSOR_TEXT :: render.Color{0, 0, 1, 1}
@(private = "file")
INK :: render.Color{1, 1, 1, 1}

@(private = "file")
Fixture :: struct {
	fonts:  ^font.System,
	device: ^render.Device,
	cache:  glyphs.Cache,
	text:   ui.Text,
	carets: ui.Carets,
	list:   render.Draw_List,
	field:  ui.Text_Field,
	theme:  ui.Theme,
}

@(private = "file")
fixture_start :: proc(t: ^testing.T, f: ^Fixture, value: string) -> bool {
	err: font.Error
	f.fonts, err = font.system_create()
	if !testing.expect_value(t, err, font.Error.None) {return false}
	device_error: render.Error
	f.device, device_error = render.device_create(.Warp)
	if !testing.expect_value(t, device_error, render.Error.None) {return false}
	glyphs.init(&f.cache, f.fonts, f.device)
	if !testing.expect(t, ui.text_init(&f.text, f.fonts, &f.cache, 16)) {return false}
	f.text.carets = &f.carets
	f.carets.style = {shape = .Bar, stroke = 1}
	f.list = render.draw_list_init()
	ui.field_set(&f.field, value)
	f.theme = {
		caret = CURSOR, caret_text = CURSOR_TEXT, text = INK, muted = INK,
	}
	return true
}

@(private = "file")
fixture_stop :: proc(f: ^Fixture) {
	delete(f.field.bytes)
	render.draw_list_destroy(&f.list)
	glyphs.destroy(&f.cache)
	render.device_destroy(f.device)
	font.system_destroy(f.fonts)
}

@(private = "file")
clip_of_glyphs :: proc(f: ^Fixture, color: render.Color) -> (clip: render.Rect, found: bool) {
	for layer in f.list.layers {
		for i in layer.glyph_start ..< layer.glyph_start + layer.glyph_count {
			if f.list.glyphs[i].color == color {return layer.clip, true}
		}
	}
	return
}

@(private = "file")
frame :: proc(f: ^Fixture, n: int, effects := caret.Effects{}) {
	at := render.frame_time_at(time.tick_add({}, time.Second + time.Duration(n) * render.FRAME_PERIOD_DEFAULT))
	ui.carets_begin(&f.carets, effects, at)
}

@(private = "file")
draw :: proc(t: ^testing.T, f: ^Fixture, focused := true) {
	render.draw_list_reset(&f.list)
	_ = render.push_layer(&f.list, {0, 0, 800, 100})
	result := ui.field_draw(&f.field, &f.list, &f.text, f.theme, 10, 30, 400, focused, "placeholder", INK)
	testing.expect_value(t, result, render.Build_Status.Ok)
}

@(private = "file")
rects_of :: proc(f: ^Fixture, color: render.Color) -> []render.Rect {
	found := make([dynamic]render.Rect, context.temp_allocator)
	for instance in f.list.rects {
		if instance.color == color {append(&found, instance.rect)}
	}
	return found[:]
}

@(private = "file")
glyphs_of :: proc(f: ^Fixture, color: render.Color) -> int {
	count := 0
	for glyph in f.list.glyphs {
		if glyph.color == color {count += 1}
	}
	return count
}

// Every field's caret follows cursor.style: a bar and an underline are two strokes thick, and a block is
// the cell of the character under it, which draws again in the cursor text colour.
@(test)
carets_follow_the_cursor_style :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_start(t, &f, "abc") {return}
	defer fixture_stop(&f)
	f.field.cursor, f.field.anchor = 1, 1
	cell_width := ui.text_width(&f.text, "b")

	frame(&f, 0)
	draw(t, &f)
	bar := rects_of(&f, CURSOR)
	testing.expect_value(t, len(bar), 1)
	if len(bar) == 1 {
		testing.expect_value(t, bar[0].width, f32(2))
		testing.expect_value(t, bar[0].x, 10 + ui.text_width(&f.text, "a"))
	}
	testing.expect_value(t, glyphs_of(&f, CURSOR_TEXT), 0)

	f.carets.style = {shape = .Underline, stroke = 1}
	frame(&f, 1)
	draw(t, &f)
	line := rects_of(&f, CURSOR)
	testing.expect_value(t, len(line), 1)
	if len(line) == 1 {
		testing.expect_value(t, line[0].height, f32(2))
		testing.expect_value(t, line[0].width, cell_width)
	}

	f.carets.style = {shape = .Block, stroke = 1}
	frame(&f, 2)
	draw(t, &f)
	block := rects_of(&f, CURSOR)
	testing.expect_value(t, len(block), 1)
	if len(block) == 1 {
		testing.expect_value(t, block[0].width, cell_width)
		// The text draws again inside a layer clipped to the block, so only that cell shows it.
		clip, found := clip_of_glyphs(&f, CURSOR_TEXT)
		testing.expect(t, found && clip == block[0], "the cursor text is clipped to the block")
	}
	testing.expect(t, glyphs_of(&f, CURSOR_TEXT) > 0, "the character under a block draws in the cursor text colour")
	testing.expect(t, glyphs_of(&f, INK) > 0, "the rest of the text keeps its own colour")

	// Past the end of the text the block is a space wide and has nothing to draw again.
	f.field.cursor, f.field.anchor = 3, 3
	frame(&f, 3)
	draw(t, &f)
	end := rects_of(&f, CURSOR)
	testing.expect_value(t, len(end), 1)
	if len(end) == 1 {testing.expect_value(t, end[0].width, ui.text_width(&f.text, " "))}
}

// The caret is the window's: a field that takes the keyboard from another surface claims it and leaves
// drawing to the flight, until the flight has landed.
@(test)
a_field_claims_the_caret_and_waits_for_a_flight :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_start(t, &f, "abc") {return}
	defer fixture_stop(&f)
	owner := ui.caret_owner_of(&f.field.caret)
	elsewhere := ui.Caret_Owner(7)
	smooth := caret.Effects{preset = .Smooth, duration = 4 * render.FRAME_PERIOD_DEFAULT, movement = true}

	// Nothing came before it: the caret appears where it is.
	f.carets.flights = true
	frame(&f, 0, smooth)
	draw(t, &f)
	testing.expect(t, f.carets.claim.present && !f.carets.claim.held)
	testing.expect_value(t, f.carets.claim.owner, owner)
	testing.expect_value(t, len(rects_of(&f, CURSOR)), 1)

	// The caret was in another surface after the last good frame: this field claims it and does not draw.
	f.field.caret = {}
	f.carets.tracked = elsewhere
	frame(&f, 1, smooth)
	draw(t, &f)
	testing.expect(t, f.carets.claim.present && f.carets.claim.held)
	testing.expect_value(t, f.carets.claim.paint.color, CURSOR)
	testing.expect_value(t, f.carets.claim.paint.target.height, f.text.line_height)
	testing.expect_value(t, len(rects_of(&f, CURSOR)), 0)

	// While the flight runs, and on the frame it lands, the field keeps waiting.
	f.carets.tracked, f.carets.flying = owner, owner
	frame(&f, 2, smooth)
	draw(t, &f)
	testing.expect(t, f.carets.claim.held)
	testing.expect_value(t, len(rects_of(&f, CURSOR)), 0)

	// Then it draws its own caret in place, with no motion left over from the flight.
	f.carets.flying = 0
	frame(&f, 3, smooth)
	draw(t, &f)
	testing.expect(t, !f.carets.claim.held)
	testing.expect_value(t, len(rects_of(&f, CURSOR)), 1)
	testing.expect(t, !f.carets.moving)

	// An unfocused field claims nothing.
	frame(&f, 4, smooth)
	draw(t, &f, focused = false)
	testing.expect(t, !f.carets.claim.present)

	// Without flights the keyboard never waits.
	f.carets.flights = false
	f.carets.tracked = elsewhere
	frame(&f, 5, smooth)
	draw(t, &f)
	testing.expect(t, !f.carets.claim.held)
}

// A blinking caret hides in the hidden part of the window's phase; one that moves shows at once and asks
// the window to restart the phase, and a steady caret never hides.
@(test)
a_blinking_caret_hides_until_it_moves :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_start(t, &f, "abc") {return}
	defer fixture_stop(&f)
	f.carets.style = {shape = .Bar, stroke = 1, blinks = true}

	frame(&f, 0)
	f.carets.shown = true
	draw(t, &f)
	testing.expect_value(t, len(rects_of(&f, CURSOR)), 1)

	frame(&f, 1)
	f.carets.shown = false
	draw(t, &f)
	testing.expect_value(t, len(rects_of(&f, CURSOR)), 0)
	testing.expect(t, f.carets.claim.present, "a hidden caret still holds the keyboard")
	testing.expect(t, !f.carets.restart)

	// Typing moves the caret: it shows at once, and the window restarts its blink.
	f.field.cursor, f.field.anchor = 0, 0
	frame(&f, 2)
	f.carets.shown = false
	draw(t, &f)
	testing.expect_value(t, len(rects_of(&f, CURSOR)), 1)
	testing.expect(t, f.carets.restart)

	f.carets.style.blinks = false
	frame(&f, 3)
	f.carets.shown = false
	draw(t, &f)
	testing.expect_value(t, len(rects_of(&f, CURSOR)), 1)
}
