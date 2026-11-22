package app_test

import "aio:ghostty"
import "cosmos:input"
import "aio:layout"
import "aio:settings"
import "aio:term"
import "aio:ui"
import "core:testing"
import "core:time"
import app "../../src"

// Runs the held track press's next repeat at the moment it falls due; false when no press is held.
hold_repeat :: proc(state: ^app.App, w: ^app.Window) -> bool {
	due, pending := app.scroll_hold_deadline(w)
	if !pending {return false}
	app.scroll_hold_tick(state, w, due)
	return true
}

// A track press held down keeps paging toward the pointer, as a Windows scrollbar does: once at the press,
// then after the repeat delay and every interval, until the thumb is under the pointer. Moving the
// pointer retargets it, leaving the track pauses it, and the release ends it.
@(test)
held_track_press_repeats_pages_until_the_thumb_meets_the_pointer :: proc(t: ^testing.T) {
	s: term.Session
	testing.expect_value(t, ghostty.terminal_new(nil, &s.terminal, 80, 24), ghostty.Result.Success)
	defer ghostty.terminal_free(s.terminal)
	text := "line\r\n"
	for _ in 0 ..< 200 {ghostty.terminal_vt_write(s.terminal, raw_data(text), len(text))}
	state: app.App
	state.settings, _, _ = settings.parse("")
	state.settings.status.panel = false
	defer settings.destroy(&state.settings)
	state.sessions = make([dynamic]app.Session_Entry)
	defer delete(state.sessions)
	append(&state.sessions, app.Session_Entry{id = 1, session = &s})
	tab: app.Tab
	if !testing.expect_value(t, layout.init(&tab.tree, {.Terminal, 1}), nil) {return}
	defer layout.destroy(&tab.tree)
	workspace: app.Workspace
	append(&workspace.tabs, &tab)
	defer delete(workspace.tabs)
	w := app.Window{workspace = &workspace, scale = 1, width = 1000, height = 600}
	w.panes = make([dynamic]layout.Pane_Rect)
	defer delete(w.panes)
	append(&w.panes, layout.Pane_Rect{content = {.Terminal, 1}, rect = {0, 100, 800, 500}})
	pane := w.panes[0]
	bar, _ := app.pane_scrollbar_geometry(&state, &w, pane)
	track := bar.track
	x := i32(track.x + 3)
	middle := i32(track.y + track.height / 2)
	top, bottom := i32(track.y + 2), i32(track.y + track.height - 2)
	start, _ := term.scrollbar(&s)
	testing.expect_value(t, start.offset + start.len, start.total)

	// The press pages once at once, and holds the track.
	pressed := time.tick_now()
	app.gesture_button(&state, &w, input.Mouse_Button_Event{button = .Left, pressed = true, x = x, y = middle})
	first, _ := term.scrollbar(&s)
	testing.expect_value(t, start.offset - first.offset, start.len)
	testing.expect_value(t, w.scroll_hold.bar, app.Scroll_Hold_Bar.Pane)
	due, pending := app.scroll_hold_deadline(&w)
	testing.expect(t, pending)
	testing.expect(t, time.tick_diff(pressed, due) >= ui.SCROLLBAR_REPEAT_DELAY)
	testing.expect(t, time.tick_diff(pressed, due) < ui.SCROLLBAR_REPEAT_DELAY + 100 * time.Millisecond)
	// Nothing pages before the delay is over.
	app.scroll_hold_tick(&state, &w, time.tick_add(due, -time.Millisecond))
	waiting, _ := term.scrollbar(&s)
	testing.expect_value(t, waiting.offset, first.offset)

	// Then one page per interval, each toward the pointer, until the thumb is under it.
	previous, pages := first.offset, 0
	for pages < 30 {
		before, _ := app.scroll_hold_deadline(&w)
		if !hold_repeat(&state, &w) {break}
		current, _ := term.scrollbar(&s)
		if current.offset == previous {break}
		testing.expect(t, current.offset < previous)
		testing.expect_value(t, previous - current.offset, start.len)
		after, _ := app.scroll_hold_deadline(&w)
		testing.expect_value(t, time.tick_diff(before, after), ui.SCROLLBAR_REPEAT_INTERVAL)
		previous = current.offset
		pages += 1
	}
	testing.expect(t, pages >= 2 && pages < 30)
	bar, _ = app.pane_scrollbar_geometry(&state, &w, pane)
	testing.expect(t, f32(middle) >= bar.thumb.y && f32(middle) < bar.thumb.y + bar.thumb.height)
	// It meets the pointer and stops, though the press is still held.
	_ = hold_repeat(&state, &w)
	_ = hold_repeat(&state, &w)
	stopped, _ := term.scrollbar(&s)
	testing.expect_value(t, stopped.offset, previous)
	testing.expect_value(t, w.scroll_hold.bar, app.Scroll_Hold_Bar.Pane)

	// The press began above the thumb. The pointer crossing below it does not reverse the paging: it
	// pauses, as a native scrollbar does, however long it waits.
	app.gesture_move(&state, &w, input.Mouse_Move_Event{x = x, y = bottom, buttons = {.Left}})
	for _ in 0 ..< 10 {_ = hold_repeat(&state, &w)}
	crossed, _ := term.scrollbar(&s)
	testing.expect_value(t, crossed.offset, previous)

	// Off the track it pauses too, and back above the thumb it resumes and pages up to the start.
	app.gesture_move(&state, &w, input.Mouse_Move_Event{x = 0, y = top, buttons = {.Left}})
	for _ in 0 ..< 10 {_ = hold_repeat(&state, &w)}
	paused, _ := term.scrollbar(&s)
	testing.expect_value(t, paused.offset, previous)
	app.gesture_move(&state, &w, input.Mouse_Move_Event{x = x, y = top, buttons = {.Left}})
	for _ in 0 ..< 30 {_ = hold_repeat(&state, &w)}
	resumed, _ := term.scrollbar(&s)
	testing.expect_value(t, resumed.offset, 0)

	// The release ends it: nothing is due, and nothing pages.
	app.gesture_button(&state, &w, input.Mouse_Button_Event{button = .Left, pressed = false, x = x, y = bottom})
	testing.expect_value(t, w.scroll_hold.bar, app.Scroll_Hold_Bar.None)
	_, pending = app.scroll_hold_deadline(&w)
	testing.expect(t, !pending)
	testing.expect(t, !hold_repeat(&state, &w))
	released, _ := term.scrollbar(&s)
	testing.expect_value(t, released.offset, resumed.offset)
}
