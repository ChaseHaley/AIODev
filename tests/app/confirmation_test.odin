package app_test

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import app "../../src"
import "aio:glyphs"
import "aio:input"
import "aio:platform"
import "aio:render"
import "aio:ui"

@(private="file")
Confirmation_Fixture :: struct { state: app.App, directory, path: string }

@(private="file")
confirmation_fixture_init :: proc(t: ^testing.T, f: ^Confirmation_Fixture) -> bool {
	err: os.Error
	f.directory, err = os.make_directory_temp("", "aio-confirmation-*", context.allocator)
	if !testing.expect_value(t, err, nil) {return false}
	f.path = strings.concatenate({f.directory, "/settings.ini"})
	if !testing.expect_value(t, os.write_entire_file(f.path,
		"shell.command = pwsh.exe -NoLogo -NoProfile\ncursor.blink = false\n" +
		"profile.alternate.name = Alternate\nprofile.alternate.command = cmd.exe /d\n"), nil) {return false}
	f.state.options = {data_dir = f.directory, inactive = true}
	f.state.app_id = fmt.aprintf("AIODev.Test.Confirmation.%d.%p", os.get_pid(), f)
	if !testing.expect_value(t, platform.init(&f.state.platform, f.state.app_id), platform.Init_Result.Primary) {
		return false
	}
	f.state.platform_ready = true
	return testing.expect(t, app.app_init(&f.state))
}

@(private="file")
confirmation_fixture_destroy :: proc(t: ^testing.T, f: ^Confirmation_Fixture) {
	app.app_destroy(&f.state)
	if f.path != "" {testing.expect_value(t, os.remove(f.path), nil); delete(f.path)}
	if f.directory != "" {testing.expect_value(t, os.remove(f.directory), nil); delete(f.directory)}
}

@(private="file")
confirmation_open_subject :: proc(t: ^testing.T, state: ^app.App, w: ^app.Window, swap: bool) -> ^ui.Confirm {
	if swap {
		app.pane_shell_swap_request(state, w, w.tree.focus, "alternate")
		testing.expect(t, w.pending_swap.confirm.open)
		return &w.pending_swap.confirm
	}
	app.pending_close_open_tab(state, w, w.workspace.selected)
	testing.expect(t, w.pending_close.confirm.open)
	return &w.pending_close.confirm
}

@(private="file")
confirmation_test_key :: proc(state: ^app.App, w: ^app.Window, key: input.Key) {
	app.handle_event(state, platform.Key_Event{window = w.id, key = key, pressed = true})
	app.handle_event(state, platform.Key_Event{window = w.id, key = key, pressed = false})
}

@(private="file")
confirmation_test_mouse :: proc(state: ^app.App, w: ^app.Window, pressed: bool, x, y: f32) {
	app.handle_event(state, platform.Mouse_Button_Event{
		window = w.id, button = .Left, pressed = pressed, x = i32(x), y = i32(y),
	})
}

@(test)
confirmation_both_subjects_advance_draw_fade_and_release_payload :: proc(t: ^testing.T) {
	f: Confirmation_Fixture
	defer confirmation_fixture_destroy(t, &f)
	if !confirmation_fixture_init(t, &f) {return}
	state := &f.state
	w := state.windows[0]
	for swap in ([?]bool{false, true}) {
		state.animations = true
		c := confirmation_open_subject(t, state, w, swap)
		testing.expect(t, app.motion_active(state))
		app.update_motion(state)
		c.motion.started = time.tick_add(time.tick_now(), -200 * time.Millisecond)
		app.update_motion(state)
		testing.expect_value(t, c.motion.value, f32(1))
		l := ui.confirm_layout(f32(w.width), f32(w.height), w.scale, c.extended, c.show_option)
		app.handle_event(state, platform.Mouse_Move_Event{
			window = w.id, x = i32(l.accept.x + 10), y = i32(l.accept.y + 10),
		})
		app.update_motion(state)
		c.hover_motion.hover.started = time.tick_add(time.tick_now(), -100 * time.Millisecond)
		app.update_motion(state)
		testing.expect_value(t, c.hover_motion.hover.value, f32(1))
		render.draw_list_reset(&w.list)
		testing.expect_value(t, app.confirmation_draw(state, w), glyphs.Result.Ok)
		testing.expect(t, len(w.list.rects) > 0 && len(w.list.glyphs) > 0)
		confirmation_test_key(state, w, .Escape)
		testing.expect(t, !c.open && ui.presence_visible(c.presence))
		if swap {testing.expect_value(t, w.pending_swap.profile_id, "alternate")}
		else {testing.expect_value(t, w.pending_close.kind, app.Pending_Close_Kind.Tab)}
		app.update_motion(state)
		c.motion.started = time.tick_add(time.tick_now(), -200 * time.Millisecond)
		w.dirty = false
		app.update_motion(state)
		testing.expect(t, w.dirty && !ui.presence_visible(c.presence))
		testing.expect_value(t, w.pending_close.kind, app.Pending_Close_Kind.None)
		testing.expect_value(t, w.pending_swap.profile_id, "")
		render.draw_list_reset(&w.list)
		testing.expect_value(t, app.confirmation_draw(state, w), glyphs.Result.Ok)
		testing.expect_value(t, len(w.list.rects), 0)
		// Disabled motion still releases the same payload through the application's motion loop.
		state.animations = false
		c = confirmation_open_subject(t, state, w, swap)
		app.update_motion(state)
		testing.expect_value(t, c.motion.value, f32(1))
		confirmation_test_key(state, w, .Escape)
		app.update_motion(state)
		testing.expect(t, !ui.presence_visible(c.presence) && !c.release_due)
	}
}

@(test)
confirmation_both_subjects_cancel_outside_release_capture_and_focus :: proc(t: ^testing.T) {
	f: Confirmation_Fixture
	defer confirmation_fixture_destroy(t, &f)
	if !confirmation_fixture_init(t, &f) {return}
	state := &f.state
	w := state.windows[0]
	for swap in ([?]bool{false, true}) {
		c := confirmation_open_subject(t, state, w, swap)
		l := ui.confirm_layout(f32(w.width), f32(w.height), w.scale, c.extended, c.show_option)
		x, y := l.accept.x + 10, l.accept.y + 10
		confirmation_test_mouse(state, w, true, x, y)
		confirmation_test_mouse(state, w, false, 1, f32(w.height - 1))
		testing.expect(t, c.open && !ui.armed_down(c.armed))
		confirmation_test_mouse(state, w, true, x, y)
		app.handle_event(state, platform.Capture_Lost_Event{window = w.id})
		testing.expect(t, c.open && !ui.armed_down(c.armed))
		confirmation_test_mouse(state, w, false, x, y)
		confirmation_test_mouse(state, w, false, x, y)
		testing.expect(t, c.open)
		confirmation_test_mouse(state, w, true, 1, f32(w.height - 1))
		confirmation_test_mouse(state, w, false, 1, f32(w.height - 1))
		testing.expect(t, !c.open && !w.selecting)
		testing.expect_value(t, len(w.workspace.tabs), 1)
		testing.expect_value(t, app.focused_session(state, w).profile_id, "default")
		c = confirmation_open_subject(t, state, w, swap)
		if swap {c.option = true}
		confirmation_test_mouse(state, w, true, x, y)
		app.handle_event(state, platform.Focus_Event{window = w.id, focused = false})
		testing.expect(t, !c.open && !ui.armed_down(c.armed))
		state.animations = false
		app.update_motion(state)
		testing.expect(t, !ui.presence_visible(c.presence))
		testing.expect_value(t, w.pending_swap.profile_id, "")
		testing.expect_value(t, w.pending_close.kind, app.Pending_Close_Kind.None)
		testing.expect(t, state.settings.pane.confirm_shell_switch)
	}
}

@(test)
confirmation_accept_keeps_swap_identity_and_retires_last_tab_window :: proc(t: ^testing.T) {
	f: Confirmation_Fixture
	defer confirmation_fixture_destroy(t, &f)
	if !confirmation_fixture_init(t, &f) {return}
	state := &f.state
	w := state.windows[0]
	id := app.focused_session(state, w).id
	c := confirmation_open_subject(t, state, w, true)
	c.option = true
	confirmation_test_key(state, w, .Enter)
	entry := app.focused_session(state, w)
	testing.expect_value(t, entry.id, id)
	testing.expect_value(t, entry.profile_id, "alternate")
	testing.expect(t, !state.settings.pane.confirm_shell_switch)
	data, err := os.read_entire_file(f.path, context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect(t, strings.contains(string(data), "pane.confirm_shell_switch = false"))
	app.update_motion(state)
	app.pane_split(state, w, .Right)
	app.tab_close_request(state, w, 0)
	testing.expect(t, w.pending_close.confirm.open)
	window_id := w.id
	l := ui.confirm_layout(f32(w.width), f32(w.height), w.scale)
	confirmation_test_mouse(state, w, true, l.accept.x + 10, l.accept.y + 10)
	confirmation_test_mouse(state, w, false, l.accept.x + 10, l.accept.y + 10)
	testing.expect(t, app.window_find(state, window_id) == nil && !state.running)
	testing.expect_value(t, len(state.windows), 0)
	testing.expect_value(t, len(state.sessions), 0)
	testing.expect_value(t, len(state.workspaces), 0)
}
