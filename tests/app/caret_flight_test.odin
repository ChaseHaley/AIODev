package app_test

import "cosmos:caret"
import "cosmos:colour"
import "aio:ghostty"
import "cosmos:input"
import "cosmos:platform"
import "cosmos:render"
import "aio:term"
import "aio:ui"
import "core:testing"
import "core:time"
import app "../../src"

// The window has one caret. It flies between surfaces (WORK-497), wears one colour and one shape in all
// of them, blinks with the one window phase and leaves a hidden terminal cursor alone.

@(private = "file")
caret_feed :: proc(t: ^testing.T, s: ^app.App, w: ^app.Window, text: string) {
	entry := app.focused_session(s, w)
	if !testing.expect(t, entry != nil) {return}
	value := text
	testing.expect(t, term.with_terminal(entry.session, proc(terminal: ghostty.Terminal, data: rawptr) -> bool {
		text := (^string)(data)^
		ghostty.terminal_vt_write(terminal, raw_data(text), uint(len(text)))
		return true
	}, &value))
	term.clear_selection(entry.session)
	w.dirty = true
}

// A window with a shell that has the keyboard, the Smooth preset and flights on.
@(private = "file")
caret_start :: proc(t: ^testing.T, f: ^Palette_Fixture, name: string) -> (s: ^app.App, w: ^app.Window, ok: bool) {
	if !palette_fixture_create(t, f, name, second_window = false) {return}
	s, w = &f.state, f.state.windows[0]
	app.handle_event(s, platform.Focus_Event{w.id, true})
	s.animations = true
	s.settings.cursor.animation = .Smooth
	s.settings.cursor.animation_duration = 100
	s.settings.cursor.animation_movement = true
	s.settings.cursor.animation_across_panes = true
	s.settings.cursor.blink = false
	s.settings.cursor.style = .Bar
	w.frame = render.frame_time_at(time.tick_add({}, time.Second))
	caret_feed(t, s, w, "\x1b[2J\x1b[H")
	return s, w, testing.expect(t, app.window_build_frame(s, w))
}

// Builds the frame `ms` milliseconds after the test's start.
@(private = "file")
caret_step :: proc(t: ^testing.T, s: ^app.App, w: ^app.Window, ms: int) -> bool {
	frame := render.frame_time_at(time.tick_add(time.tick_add({}, time.Second), time.Duration(ms) * time.Millisecond))
	app.window_motion_update(s, w, frame)
	w.frame = frame
	return testing.expect(t, app.window_build_frame(s, w))
}

// A flight has started and not yet handed the caret back to its surface.
@(private = "file")
caret_flying :: proc(w: ^app.Window) -> bool {
	#partial switch w.cursor_crossing.phase {
	case .Pending, .Flying, .Final, .Restoring: return true
	}
	return false
}

// The cursor the window last drew for the pane, which the keyboard's pane draws only as the caret.
@(private = "file")
caret_pane_cursor :: proc(w: ^app.Window, pane: int) -> bool {
	for &view in w.views {
		if view.content == w.panes[pane].content {return view.cursor != nil}
	}
	return false
}

// Steps until the caret has landed and its surface draws it again; returns the time reached.
@(private = "file")
caret_land :: proc(t: ^testing.T, s: ^app.App, w: ^app.Window, from: int) -> (ms: int, ok: bool) {
	ms = from
	for caret_flying(w) {
		ms += 8
		if !testing.expect(t, ms < from + 1000, "the flight never landed") {return ms, false}
		if !caret_step(t, s, w, ms) {return ms, false}
	}
	return ms, true
}

@(test)
the_caret_flies_between_a_shell_and_the_palette :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	s, w, ok := caret_start(t, &f, "caret-palette")
	if !ok {return}
	shell := app.terminal_caret_owner(w.panes[0].content)
	query := ui.caret_owner_of(&s.palette.query.caret)
	testing.expect(t, w.carets.claim.present && !w.carets.claim.held)
	testing.expect_value(t, w.carets.claim.owner, shell)
	prompt := w.carets.claim.paint.head
	testing.expect_value(t, w.cursor_crossing.phase, app.Cursor_Crossing_Phase.Tracking)

	app.palette_open(s, w)
	if !caret_step(t, s, w, 16) {return}
	testing.expect_value(t, w.carets.claim.owner, query)
	testing.expect(t, w.carets.claim.held, "the palette leaves drawing to the flight")
	testing.expect_value(t, w.cursor_crossing.phase, app.Cursor_Crossing_Phase.Flying)
	testing.expect(t, app.cursor_motion_animating(w))
	// The pane under the palette draws no cursor, not even a hollow one.
	testing.expect(t, w.views[0].cursor == nil, "the shell's cursor waits while the palette has the keyboard")

	// Between the shell's cursor and the query field, in the one cursor colour.
	if !caret_step(t, s, w, 56) {return}
	head := w.cursor_crossing.transition.motion.head
	target := w.carets.claim.paint.target
	testing.expect(t, head.x > prompt.x && head.x < target.x, "the head is between the prompt and the query")
	testing.expect_value(t, w.carets.claim.paint.color, s.theme.caret)

	ms, landed := caret_land(t, s, w, 56)
	if !landed {return}
	testing.expect_value(t, w.carets.claim.owner, query)
	testing.expect(t, !w.carets.claim.held)
	testing.expect(t, !app.cursor_motion_animating(w))

	// And back: closing the palette flies the caret to the shell's cursor.
	app.palette_close(s, w)
	if !caret_step(t, s, w, ms + 16) {return}
	testing.expect_value(t, w.carets.claim.owner, shell)
	testing.expect(t, w.carets.claim.held)
	testing.expect_value(t, w.cursor_crossing.phase, app.Cursor_Crossing_Phase.Flying)
	back, returned := caret_land(t, s, w, ms + 16)
	if !returned {return}
	_ = back
	testing.expect_value(t, w.carets.claim.owner, shell)
	testing.expect_value(t, w.carets.claim.paint.head, prompt)
	testing.expect(t, w.views[0].cursor != nil, "the shell's cursor is back")
}

@(test)
the_caret_goes_nowhere_without_a_flight :: proc(t: ^testing.T) {
	// Off, the switch and Windows' animation setting each leave the caret where its surface puts it.
	for variant in 0 ..< 3 {
		f: Palette_Fixture
		defer palette_fixture_destroy(t, &f)
		s, w, ok := caret_start(t, &f, "caret-no-flight")
		if !ok {return}
		switch variant {
		case 0: s.settings.cursor.animation = .Off
		case 1: s.settings.cursor.animation_across_panes = false
		case 2: s.animations = false
		}
		app.palette_open(s, w)
		if !caret_step(t, s, w, 16) {return}
		testing.expect_value(t, w.carets.claim.owner, ui.caret_owner_of(&s.palette.query.caret))
		testing.expectf(t, !w.carets.claim.held, "variant %d", variant)
		testing.expectf(t, w.cursor_crossing.phase != .Flying, "variant %d", variant)
	}
}

@(test)
a_hidden_terminal_cursor_holds_no_caret_and_nothing_flies :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	s, w, ok := caret_start(t, &f, "caret-hidden")
	if !ok {return}
	caret_feed(t, s, w, "\x1b[?25l")
	if !caret_step(t, s, w, 16) {return}
	testing.expect(t, !w.carets.claim.present, "DECTCEM hides the caret")

	app.palette_open(s, w)
	if !caret_step(t, s, w, 32) {return}
	testing.expect_value(t, w.carets.claim.owner, ui.caret_owner_of(&s.palette.query.caret))
	testing.expect(t, !w.carets.claim.held && w.cursor_crossing.phase != .Flying, "nothing flies out of a hidden cursor")

	app.palette_close(s, w)
	if !caret_step(t, s, w, 400) {return}
	if !caret_step(t, s, w, 416) {return}
	testing.expect(t, !w.carets.claim.present)
	testing.expect(t, w.cursor_crossing.phase != .Flying, "nothing flies into a hidden cursor")
	// The program shows its cursor again: it appears in place.
	caret_feed(t, s, w, "\x1b[?25h")
	if !caret_step(t, s, w, 432) {return}
	testing.expect_value(t, w.carets.claim.owner, app.terminal_caret_owner(w.panes[0].content))
	testing.expect(t, !w.carets.claim.held)
}

@(test)
the_pane_under_the_palette_or_find_bar_draws_no_hollow_cursor :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	s, w, ok := caret_start(t, &f, "caret-hollow")
	if !ok {return}
	s.settings.cursor.animation = .Off
	app.pane_split(s, w, .Right)
	if !caret_step(t, s, w, 16) {return}
	// Another pane that is not the window's focus keeps its hollow cursor.
	testing.expect(t, caret_pane_cursor(w, 0) && caret_pane_cursor(w, 1))
	app.palette_open(s, w)
	if !caret_step(t, s, w, 32) {return}
	focus := 0
	for pane, i in w.panes {
		if pane.node == app.window_tree(w).focus {focus = i}
	}
	other := 1 - focus
	testing.expect(t, !caret_pane_cursor(w, focus), "the focused pane draws no cursor under the palette")
	testing.expect(t, caret_pane_cursor(w, other), "an unfocused pane keeps its hollow cursor")
	app.palette_close(s, w)
	if !caret_step(t, s, w, 400) {return}
	if !caret_step(t, s, w, 416) {return}
	testing.expect(t, caret_pane_cursor(w, focus), "the cursor returns with the keyboard")
}

@(test)
one_colour_and_the_cursor_style_in_every_surface :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	s, w, ok := caret_start(t, &f, "caret-colour")
	if !ok {return}
	s.settings.cursor.animation = .Off
	// The built-in theme sets no cursor colour, so the cursor is the accent everywhere.
	accent := s.theme.accent
	testing.expect_value(t, s.theme.caret, accent)
	testing.expect_value(t, colour.rgba(s.settings.colors.cursor), accent)
	if !caret_step(t, s, w, 16) {return}
	testing.expect_value(t, w.carets.claim.paint.color, accent)

	// A program's OSC 12 recolours the cursor resting in its pane and nothing else.
	caret_feed(t, s, w, "\x1b]12;#ff0000\x07")
	if !caret_step(t, s, w, 32) {return}
	testing.expect_value(t, w.carets.claim.paint.color, render.Color{1, 0, 0, 1})
	app.palette_open(s, w)
	if !caret_step(t, s, w, 48) {return}
	testing.expect_value(t, w.carets.claim.owner, ui.caret_owner_of(&s.palette.query.caret))
	testing.expect_value(t, w.carets.claim.paint.color, accent)
	testing.expect_value(t, w.carets.claim.paint.shape, caret.Shape.Bar)

	// The fields follow cursor.style; DECSCUSR only changes its terminal.
	s.settings.cursor.style = .Block
	if !caret_step(t, s, w, 64) {return}
	testing.expect_value(t, w.carets.claim.paint.shape, caret.Shape.Block)
	app.palette_close(s, w)
	if !caret_step(t, s, w, 400) {return}
	if !caret_step(t, s, w, 416) {return}
	caret_feed(t, s, w, "\x1b[4 q")
	if !caret_step(t, s, w, 432) {return}
	testing.expect_value(t, w.carets.claim.paint.shape, caret.Shape.Underline)
}

@(test)
every_surface_blinks_with_the_one_window_phase :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	s, w, ok := caret_start(t, &f, "caret-blink")
	if !ok {return}
	s.settings.cursor.animation = .Off
	s.settings.cursor.blink = true
	s.settings.cursor.blink_interval = 300
	// The program asks for a steady cursor: the shell does not blink, the palette's caret does.
	caret_feed(t, s, w, "\x1b[2 q")
	if !caret_step(t, s, w, 16) {return}
	_, blinking := w.cursor_blink.(app.Cursor_Blink_On)
	testing.expect(t, !blinking, "a steady terminal cursor does not start the blink")
	app.palette_open(s, w)
	if !caret_step(t, s, w, 32) {return}
	on, field_blinks := w.cursor_blink.(app.Cursor_Blink_On)
	if !testing.expect(t, field_blinks, "the palette caret follows cursor.blink") {return}
	testing.expect_value(t, on.interval, 300 * time.Millisecond)
	testing.expect(t, on.visible)
	// A tick hides it, and the next frame draws no caret rect; moving the caret shows it again.
	app.cursor_blink_tick(w, on.deadline)
	testing.expect(t, !app.cursor_visible(w))
	if !caret_step(t, s, w, 48) {return}
	testing.expect(t, !w.carets.restart)
	app.handle_event(s, input.Text_Event{w.id, "a"})
	if !caret_step(t, s, w, 64) {return}
	testing.expect(t, w.carets.restart, "typing moves the caret, which restarts the blink")
	testing.expect(t, app.cursor_visible(w))

	// The interval is a setting.
	s.settings.cursor.blink_interval = 900
	if !caret_step(t, s, w, 80) {return}
	on, _ = w.cursor_blink.(app.Cursor_Blink_On)
	testing.expect_value(t, on.interval, 900 * time.Millisecond)
}
