package app_test

import "aio:colour"
import "aio:ghostty"
import "aio:platform"
import "aio:render"
import "aio:term"
import "core:testing"
import "core:time"
import app "../../src"

@(private = "file")
cursor_feed :: proc(t: ^testing.T, s: ^app.App, w: ^app.Window, text: string) {
	entry := app.focused_session(s, w)
	if !testing.expect(t, entry != nil) {return}
	value := text
	testing.expect(t, term.with_terminal(entry.session, proc(terminal: ghostty.Terminal, data: rawptr) -> bool {
		text := (^string)(data)^
		ghostty.terminal_vt_write(terminal, raw_data(text), uint(len(text)))
		return true
	}, &value))
	// The direct terminal write bypasses the PTY reader's generation publication.
	term.clear_selection(entry.session)
	w.dirty = true
}

@(private = "file")
cursor_head :: proc(t: ^testing.T, s: ^app.App, w: ^app.Window) -> render.Rect {
	color := colour.rgba(s.settings.colors.cursor)
	for rect in w.list.rects {
		if rect.color == color && rect.rect.width == w.metrics.cell_width &&
		   rect.rect.height == w.metrics.cell_height {return rect.rect}
	}
	testing.expect(t, false, "the terminal cursor was not drawn")
	return {}
}

// A split pane reuses its draw list between terminal updates. Motion must replace that list on
// every sampled frame, including the last sample after the cursor stops requesting frames.
@(test)
cursor_motion_updates_cached_panes_and_settles_on_the_logical_cursor :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "cursor-motion", second_window = false) {return}
	s := &f.state
	w := s.windows[0]
	app.pane_split(s, w, .Right)
	app.handle_event(s, platform.Focus_Event{w.id, true})
	s.animations = true
	s.settings.cursor.animation = .Smooth
	s.settings.cursor.animation_duration = 100
	s.settings.cursor.animation_movement = true
	start := render.frame_time_at(time.tick_add({}, time.Second))
	w.frame = start
	cursor_feed(t, s, w, "\x1b[2J\x1b[H")
	if !testing.expect(t, app.window_build_frame(s, w)) {return}
	from := cursor_head(t, s, w)
	cursor_feed(t, s, w, "\x1b[1;21H")
	if !testing.expect(t, app.window_build_frame(s, w)) {return}
	testing.expect(t, app.cursor_motion_animating(w))
	target := from.x + 20 * w.metrics.cell_width
	middle := render.frame_time_at(time.tick_add(start.display, 40 * time.Millisecond))
	app.window_motion_update(s, w, middle)
	w.frame = middle
	if !testing.expect(t, app.window_build_frame(s, w)) {return}
	shown := cursor_head(t, s, w)
	testing.expect(t, shown.x > from.x && shown.x < target)

	last := render.frame_time_at(time.tick_add(start.display, 150 * time.Millisecond))
	app.window_motion_update(s, w, last)
	w.frame = last
	if !testing.expect(t, app.window_build_frame(s, w)) {return}
	testing.expect_value(t, cursor_head(t, s, w).x, target)
	testing.expect(t, !app.cursor_motion_animating(w))
	w.dirty = false
	testing.expect(t, !app.cursor_motion_animate(s, w, render.frame_time_at(time.tick_add(last.display, time.Second))))
	testing.expect(t, !w.dirty)

	// Losing keyboard focus cancels the effect, not the terminal's destination.
	cursor_feed(t, s, w, "\x1b[1;2H")
	if !testing.expect(t, app.window_build_frame(s, w)) {return}
	testing.expect(t, app.cursor_motion_animating(w))
	app.handle_event(s, platform.Focus_Event{w.id, false})
	app.window_motion_update(s, w, last)
	testing.expect(t, !app.cursor_motion_animating(w))
	app.handle_event(s, platform.Focus_Event{w.id, true})
	if !testing.expect(t, app.window_build_frame(s, w)) {return}
	testing.expect_value(t, cursor_head(t, s, w).x, from.x + w.metrics.cell_width)
	testing.expect(t, !app.cursor_motion_animating(w), "focus restoration must not replay old motion")

	// The OS motion preference wins even when the saved preset remains enabled.
	s.animations = false
	cursor_feed(t, s, w, "\x1b[1;10H")
	if !testing.expect(t, app.window_build_frame(s, w)) {return}
	testing.expect_value(t, cursor_head(t, s, w).x, from.x + 9 * w.metrics.cell_width)
	testing.expect(t, !app.cursor_motion_animating(w))
}
