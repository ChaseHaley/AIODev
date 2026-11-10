package app_test

import "aio:colour"
import "aio:ghostty"
import "aio:input"
import "aio:platform"
import "aio:render"
import "aio:term"
import "core:fmt"
import "core:os"
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
	for layer in w.list.layers {
		for i in layer.rect_start ..< layer.rect_start + layer.rect_count {
			rect := w.list.rects[i]
			r, clip := rect.rect, layer.clip
			if rect.color == color && r.width == w.metrics.cell_width &&
			   r.height == w.metrics.cell_height && r.x >= clip.x && r.y >= clip.y &&
			   r.x + r.width <= clip.x + clip.width && r.y + r.height <= clip.y + clip.height {
				return r
			}
		}
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

// Focus changes are immediate, but the one opaque cursor must cross the space between cards.
// Observe composed draw geometry, not the transition's internal coordinates.
@(test)
cursor_crosses_visible_panes_on_keyboard_and_pointer_focus :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "cursor-crossing", second_window = false) {return}
	s := &f.state
	w := s.windows[0]
	app.pane_split(s, w, .Right)
	app.handle_event(s, platform.Focus_Event{w.id, true})
	s.settings.pane.gap = 24
	app.window_relayout(s, w)
	s.animations = true
	s.settings.cursor.animation = .Smooth
	s.settings.cursor.animation_duration = 100
	s.settings.cursor.animation_movement = true
	s.settings.cursor.animation_across_panes = true
	start := time.tick_add({}, time.Second)
	w.frame = render.frame_time_at(start)
	cursor_feed(t, s, w, "\x1b[2J\x1b[H")
	if !testing.expect(t, app.window_build_frame(s, w)) {return}
	right := cursor_head(t, s, w)
	app.run_action(s, w, .Focus_Left)
	cursor_feed(t, s, w, "\x1b[2J\x1b[H")
	if !testing.expect(t, app.window_build_frame(s, w)) {return}
	testing.expect(t, cursor_head(t, s, w) == right, "focus must begin at the last drawn cursor")
	testing.expect(t, app.cursor_motion_animating(w))
	// A sampled head in the gap cannot have come from either pane's clipped local cursor.
	left_edge := w.panes[0].rect.x + w.panes[0].rect.width
	right_edge := w.panes[1].rect.x
	crossed_gap := false
	for ms := 1; ms < 100; ms += 1 {
		frame := render.frame_time_at(time.tick_add(start, time.Duration(ms) * time.Millisecond))
		app.window_motion_update(s, w, frame)
		w.frame = frame
		if !testing.expect(t, app.window_build_frame(s, w)) {return}
		head := cursor_head(t, s, w)
		crossed_gap ||= head.x < right_edge && head.x + head.width > left_edge
	}
	testing.expect(t, crossed_gap, "the crossing must remain visible outside both terminal clips")
	last := render.frame_time_at(time.tick_add(start, 150 * time.Millisecond))
	app.window_motion_update(s, w, last)
	w.frame = last
	if !testing.expect(t, app.window_build_frame(s, w)) {return}
	if !cursor_restore_frame(t, s, w) {return}
	left := cursor_head(t, s, w)
	testing.expect(t, left.x < right.x && !app.cursor_motion_animating(w))
	left_session := app.focused_session(s, w)
	for pressed in ([2]bool{true, false}) {
		pane := w.panes[1].rect
		app.handle_event(s, input.Mouse_Button_Event{window = w.id, button = .Left,
			pressed = pressed, x = i32(pane.x + pane.width / 2), y = i32(pane.y + pane.height / 2)})
	}
	testing.expect(t, app.focused_session(s, w) != nil && app.focused_session(s, w) != left_session,
		"pointer focus still owns input immediately")
	if !testing.expect(t, app.window_build_frame(s, w)) {return}
	testing.expect_value(t, cursor_head(t, s, w), left)
	middle := render.frame_time_at(time.tick_add(last.display, 40 * time.Millisecond))
	app.window_motion_update(s, w, middle)
	w.frame = middle
	if !testing.expect(t, app.window_build_frame(s, w)) {return}
	shown := cursor_head(t, s, w)
	testing.expect(t, shown.x > left.x && shown.x < right.x)
	// Output during the flight changes its destination without jumping the drawn head.
	cursor_feed(t, s, w, "\x1b[1;6H")
	if !testing.expect(t, app.window_build_frame(s, w)) {return}
	testing.expect_value(t, cursor_head(t, s, w), shown)
	// A rapid reversal likewise leaves the first frame at the actually drawn pose.
	app.run_action(s, w, .Focus_Left)
	if !testing.expect(t, app.window_build_frame(s, w)) {return}
	testing.expect_value(t, cursor_head(t, s, w), shown)
	finish := render.frame_time_at(time.tick_add(middle.display, 150 * time.Millisecond))
	app.window_motion_update(s, w, finish)
	w.frame = finish
	if !testing.expect(t, app.window_build_frame(s, w)) {return}
	if !cursor_restore_frame(t, s, w) {return}
	testing.expect_value(t, cursor_head(t, s, w), left)
	testing.expect(t, !app.cursor_motion_animating(w))
	w.dirty = false
	testing.expect(t, !app.cursor_motion_animate(s, w,
		render.frame_time_at(time.tick_add(finish.display, time.Second))))
	testing.expect(t, !w.dirty)
}

@(test)
cursor_crossing_disabled_and_off_restore_the_destination_without_motion :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "cursor-crossing-disabled", second_window = false) {return}
	s := &f.state
	w := s.windows[0]
	app.pane_split(s, w, .Right)
	app.handle_event(s, platform.Focus_Event{w.id, true})
	s.animations = true
	s.settings.cursor.animation = .Smooth
	s.settings.cursor.animation_movement = true
	s.settings.cursor.animation_across_panes = false
	w.frame = render.frame_time_at(time.tick_add({}, time.Second))
	cursor_feed(t, s, w, "\x1b[2J\x1b[H")
	if !testing.expect(t, app.window_build_frame(s, w)) {return}
	right := cursor_head(t, s, w)
	app.run_action(s, w, .Focus_Left)
	cursor_feed(t, s, w, "\x1b[2J\x1b[H")
	if !testing.expect(t, app.window_build_frame(s, w)) {return}
	left := cursor_head(t, s, w)
	testing.expect(t, left.x < right.x && !app.cursor_motion_animating(w))
	s.settings.cursor.animation_across_panes = true
	s.settings.cursor.animation = .Off
	app.run_action(s, w, .Focus_Right)
	if !testing.expect(t, app.window_build_frame(s, w)) {return}
	testing.expect_value(t, cursor_head(t, s, w), right)
	testing.expect(t, !app.cursor_motion_animating(w))
	s.settings.cursor.animation = .Smooth
	if !testing.expect(t, app.window_build_frame(s, w)) {return}
	app.run_action(s, w, .Focus_Left)
	if !testing.expect(t, app.window_build_frame(s, w)) {return}
	testing.expect(t, app.cursor_motion_animating(w))
	s.settings.cursor.animation_across_panes = false
	if !testing.expect(t, app.window_build_frame(s, w)) {return}
	testing.expect_value(t, cursor_head(t, s, w), left)
	testing.expect(t, !app.cursor_motion_animating(w))
}

@(test)
cursor_crossing_uses_last_local_pose_and_cancels_on_focus_loss :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "cursor-crossing-local", second_window = false) {return}
	s := &f.state
	w := s.windows[0]
	app.pane_split(s, w, .Right)
	app.handle_event(s, platform.Focus_Event{w.id, true})
	s.animations = true
	s.settings.cursor.animation = .Smooth
	s.settings.cursor.animation_duration = 100
	s.settings.cursor.animation_movement = true
	s.settings.cursor.animation_across_panes = true
	start := time.tick_add({}, time.Second)
	w.frame = render.frame_time_at(start)
	cursor_feed(t, s, w, "\x1b[2J\x1b[H")
	if !testing.expect(t, app.window_build_frame(s, w)) {return}
	cursor_feed(t, s, w, "\x1b[1;21H")
	if !testing.expect(t, app.window_build_frame(s, w)) {return}
	middle := render.frame_time_at(time.tick_add(start, 25 * time.Millisecond))
	app.window_motion_update(s, w, middle)
	w.frame = middle
	if !testing.expect(t, app.window_build_frame(s, w)) {return}
	local_pose := cursor_head(t, s, w)
	app.run_action(s, w, .Focus_Left)
	cursor_feed(t, s, w, "\x1b[2J\x1b[H")
	if !testing.expect(t, app.window_build_frame(s, w)) {return}
	testing.expect(t, cursor_head(t, s, w) == local_pose,
		"crossing must not start at the old pane's unpainted logical destination")
	// No frame between loss and restoration: the loss hook must still discard the crossing.
	app.handle_event(s, platform.Focus_Event{w.id, false})
	app.handle_event(s, platform.Focus_Event{w.id, true})
	if !testing.expect(t, app.window_build_frame(s, w)) {return}
	testing.expect(t, cursor_head(t, s, w).x < local_pose.x)
	testing.expect(t, !app.cursor_motion_animating(w))
}

@(test)
cursor_crossing_travels_from_a_float_to_the_tiling :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	s, w, _, ok := float_fixture(t, &f, "cursor-crossing-float")
	if !ok {return}
	app.handle_event(s, platform.Focus_Event{w.id, true})
	s.animations = true
	s.settings.cursor.animation = .Smooth
	s.settings.cursor.animation_duration = 100
	s.settings.cursor.animation_movement = true
	s.settings.cursor.animation_across_panes = true
	start := time.tick_add({}, time.Second)
	w.frame = render.frame_time_at(start)
	cursor_feed(t, s, w, "\x1b[2J\x1b[H")
	if !testing.expect(t, app.window_build_frame(s, w)) {return}
	float_head := cursor_head(t, s, w)
	app.run_action(s, w, .Focus_Left)
	cursor_feed(t, s, w, "\x1b[2J\x1b[H")
	if !testing.expect(t, app.window_build_frame(s, w)) {return}
	testing.expect_value(t, cursor_head(t, s, w), float_head)
	middle := render.frame_time_at(time.tick_add(start, 40 * time.Millisecond))
	app.window_motion_update(s, w, middle)
	w.frame = middle
	if !testing.expect(t, app.window_build_frame(s, w)) {return}
	head := cursor_head(t, s, w)
	testing.expect(t, head != float_head, "the cursor must leave the floating terminal")
	finish := render.frame_time_at(time.tick_add(start, 150 * time.Millisecond))
	app.window_motion_update(s, w, finish)
	w.frame = finish
	if !testing.expect(t, app.window_build_frame(s, w)) {return}
	if !cursor_restore_frame(t, s, w) {return}
	testing.expect(t, !app.cursor_motion_animating(w))
	testing.expect(t, cursor_head(t, s, w) != float_head)
}

@(private = "file")
cursor_restore_frame :: proc(t: ^testing.T, s: ^app.App, w: ^app.Window) -> bool {
	// A landed overlay owns the settlement frame. The next display frame must replace its
	// suppressed terminal cache and be the last cursor-requested frame.
	frame := render.frame_time_at(time.tick_add(w.frame.display, w.frame.period))
	app.window_motion_update(s, w, frame)
	w.frame = frame
	return testing.expect(t, app.window_build_frame(s, w))
}

@(test)
cursor_crossing_advances_while_the_destination_moves_every_frame :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "cursor-moving-destination", second_window = false) {return}
	s, w := &f.state, f.state.windows[0]
	app.pane_split(s, w, .Right)
	app.handle_event(s, platform.Focus_Event{w.id, true})
	s.animations = true
	s.settings.cursor.animation = .Smooth
	s.settings.cursor.animation_duration = 100
	s.settings.cursor.animation_movement = true
	s.settings.cursor.animation_across_panes = true
	start := time.tick_add({}, time.Second)
	w.frame = render.frame_time_at(start)
	cursor_feed(t, s, w, "\x1b[2J\x1b[H")
	if !testing.expect(t, app.window_build_frame(s, w)) {return}
	from := cursor_head(t, s, w)
	app.run_action(s, w, .Focus_Left)
	cursor_feed(t, s, w, "\x1b[2J\x1b[H")
	if !testing.expect(t, app.window_build_frame(s, w)) {return}
	previous := from.x
	for n in 1 ..= 5 {
		frame := render.frame_time_at(time.tick_add(start, time.Duration(n) * 20 * time.Millisecond))
		app.window_motion_update(s, w, frame)
		w.frame = frame
		cursor_feed(t, s, w, fmt.tprintf("\x1b[1;%dH", n + 1))
		if !testing.expect(t, app.window_build_frame(s, w)) {return}
		head := cursor_head(t, s, w)
		testing.expect(t, head.x < previous, "changing output must not freeze the crossing at its source")
		previous = head.x
	}
}

@(test)
markdown_float_masks_terminal_text_replayed_by_a_crossing_cursor :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "cursor-markdown-occlusion", second_window = false) {return}
	s, w := &f.state, f.state.windows[0]
	app.pane_split(s, w, .Right)
	app.handle_event(s, platform.Focus_Event{w.id, true})
	right := app.window_tree(w).focus
	text := "\x1b[2J\x1b[9;1H" +
		"WWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWW" +
		"WWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWW" +
		"\x1b[9;1H"
	cursor_feed(t, s, w, text)
	app.run_action(s, w, .Focus_Left)
	cursor_feed(t, s, w, text)
	path := fmt.tprintf("%s/cursor-cover.md", f.directory)
	if !testing.expect_value(t, os.write_entire_file(path, transmute([]u8)string("# Cover\n")), nil) {return}
	defer {testing.expect_value(t, os.remove(path), nil)}
	if !testing.expect(t, app.markdown_open_at(s, w, w.workspace, w.workspace.selected,
		app.window_tree(w).focus, path, focus = false, floating = true)) {return}
	floats := app.floating_rects(w)
	if !testing.expect_value(t, len(floats), 1) {return}
	cover := floats[0].rect
	app.pane_focus(s, w, right)
	s.animations = true
	s.settings.cursor.animation = .Smooth
	s.settings.cursor.animation_duration = 100
	s.settings.cursor.animation_movement = true
	s.settings.cursor.animation_across_panes = true
	start := time.tick_add({}, time.Second)
	w.frame = render.frame_time_at(start)
	if !testing.expect(t, app.window_build_frame(s, w)) {return}
	app.run_action(s, w, .Focus_Left)
	if !testing.expect(t, app.window_build_frame(s, w)) {return}
	surface, err := render.surface_create_offscreen(s.device, w.width, w.height)
	if !testing.expect_value(t, err, render.Error.None) {return}
	defer render.surface_destroy(surface)
	observed := false
	for ms := 5; ms < 95; ms += 5 {
		frame := render.frame_time_at(time.tick_add(start, time.Duration(ms) * time.Millisecond))
		app.window_motion_update(s, w, frame)
		w.frame = frame
		if !testing.expect(t, app.window_build_frame(s, w)) {return}
		head := cursor_head(t, s, w)
		if head.x < cover.x + 16 || head.x + head.width > cover.x + cover.width - 16 ||
		   head.y < cover.y + 64 || head.y + head.height > cover.y + cover.height - 16 {continue}
		testing.expect_value(t, render.frame_render(s.device, surface, &w.list, s.theme.window), render.Error.None)
		pixels, read_error := render.surface_read_pixels(s.device, surface, context.temp_allocator)
		if !testing.expect_value(t, read_error, render.Error.None) {return}
		rgb := s.settings.colors.cursor
		expected := [4]u8{rgb[2], rgb[1], rgb[0], 255}
		for y in int(head.y) + 1 ..< int(head.y + head.height) - 1 {
			for x in int(head.x) + 1 ..< int(head.x + head.width) - 1 {
				at := (y * int(w.width) + x) * 4
				pixel := [4]u8{pixels[at], pixels[at + 1], pixels[at + 2], pixels[at + 3]}
				testing.expect(t, pixel == expected, "covered terminal glyphs must not appear through Markdown")
			}
		}
		observed = true
		break
	}
	testing.expect(t, observed, "the fixture must put the traveling head inside the Markdown float")
}

@(test)
blink_hidden_cursor_animates_in_cached_panes_and_across_focus :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "cursor-hidden-blink", second_window = false) {return}
	s, w := &f.state, f.state.windows[0]
	app.pane_split(s, w, .Right)
	app.handle_event(s, platform.Focus_Event{w.id, true})
	s.animations = true
	s.settings.cursor.blink = true
	s.settings.cursor.animation = .Smear
	s.settings.cursor.animation_duration = 100
	s.settings.cursor.animation_movement = true
	s.settings.cursor.animation_across_panes = true
	app.run_action(s, w, .Focus_Left)
	cursor_feed(t, s, w, "\x1b[1 q\x1b[2J\x1b[H")
	app.run_action(s, w, .Focus_Right)
	start := time.tick_add({}, time.Second)
	w.frame = render.frame_time_at(start)
	cursor_feed(t, s, w, "\x1b[1 q\x1b[2J\x1b[Habcdefghijklmnop")
	if !testing.expect(t, app.window_build_frame(s, w)) {return}
	from := cursor_head(t, s, w)
	on, blinking := w.cursor_blink.(app.Cursor_Blink_On)
	if !testing.expect(t, blinking) {return}
	app.cursor_blink_tick(w, on.deadline)
	testing.expect(t, !app.cursor_visible(w))
	if !testing.expect(t, app.window_build_frame(s, w)) {return}

	cursor_feed(t, s, w, "\x1b[H")
	if !testing.expect(t, app.window_build_frame(s, w)) {return}
	testing.expect(t, app.cursor_motion_animating(w), "Home must animate from a blink-hidden departure")
	middle := render.frame_time_at(time.tick_add(start, 40 * time.Millisecond))
	app.window_motion_update(s, w, middle)
	w.frame = middle
	if !testing.expect(t, app.window_build_frame(s, w)) {return}
	head := cursor_head(t, s, w)
	target := from.x - 16 * w.metrics.cell_width
	testing.expect(t, head.x > target && head.x < from.x,
		"the frame scheduler must advance the visible effect without cancelling it for blinking")
	finish := render.frame_time_at(time.tick_add(start, 150 * time.Millisecond))
	app.window_motion_update(s, w, finish)
	w.frame = finish
	if !testing.expect(t, app.window_build_frame(s, w)) {return}
	testing.expect(t, !app.cursor_motion_animating(w))
	testing.expect(t, !app.cursor_visible(w), "finishing an effect must not disable the idle blink")

	app.run_action(s, w, .Focus_Left)
	if !testing.expect(t, app.window_build_frame(s, w)) {return}
	testing.expect(t, app.cursor_motion_animating(w), "a blink-hidden source must still seed pane travel")
	testing.expect_value(t, cursor_head(t, s, w).x, target)
	on, blinking = w.cursor_blink.(app.Cursor_Blink_On)
	if blinking && on.visible {
		app.cursor_blink_tick(w, on.deadline)
	}
	middle = render.frame_time_at(time.tick_add(finish.display, 40 * time.Millisecond))
	app.window_motion_update(s, w, middle)
	w.frame = middle
	if !testing.expect(t, app.window_build_frame(s, w)) {return}
	testing.expect(t, cursor_head(t, s, w).x < target)
	finish = render.frame_time_at(time.tick_add(finish.display, 150 * time.Millisecond))
	app.window_motion_update(s, w, finish)
	w.frame = finish
	if !testing.expect(t, app.window_build_frame(s, w)) {return}
	if !cursor_restore_frame(t, s, w) {return}
	testing.expect(t, !app.cursor_visible(w) && !app.cursor_motion_animating(w))
}

// Text fields follow the terminal's cursor animation: the palette's caret glides as the query
// grows, and the window keeps drawing until it lands.
@(test)
palette_caret_animates_with_the_cursor_setting :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "field-caret", second_window = false) {return}
	s := &f.state
	w := s.windows[0]
	app.handle_event(s, platform.Focus_Event{w.id, true})
	// The palette appears at once, so only its caret moves.
	s.animations = false
	app.palette_open(s, w)
	app.update_motion(s)
	s.animations = true
	s.settings.cursor.animation = .Smooth
	s.settings.cursor.animation_duration = 100
	s.settings.cursor.animation_movement = true
	start := render.frame_time_at(time.tick_add({}, time.Second))
	w.frame = start
	if !testing.expect(t, app.window_build_frame(s, w)) {return}
	testing.expect(t, !w.carets.moving)
	app.handle_event(s, input.Text_Event{w.id, "split"})
	w.frame = render.frame_time_at(time.tick_add(start.display, 20 * time.Millisecond))
	if !testing.expect(t, app.window_build_frame(s, w)) {return}
	testing.expect(t, w.carets.moving && app.window_animating(s, w), "a moving caret keeps the window drawing")
	last := render.frame_time_at(time.tick_add(start.display, 150 * time.Millisecond))
	app.window_motion_update(s, w, last)
	w.frame = last
	if !testing.expect(t, app.window_build_frame(s, w)) {return}
	testing.expect(t, !w.carets.moving && !app.window_animating(s, w))

	// Off draws the caret where it is.
	s.settings.cursor.animation = .Off
	app.handle_event(s, input.Text_Event{w.id, " right"})
	if !testing.expect(t, app.window_build_frame(s, w)) {return}
	testing.expect(t, !w.carets.moving)
}
