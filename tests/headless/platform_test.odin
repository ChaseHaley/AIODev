package headless_test

import "core:fmt"
import "core:os"
import "core:testing"
import "aio:input"
import "aio:platform"

@(private = "file")
platform_open :: proc(t: ^testing.T, p: ^platform.Platform, name: string) -> bool {
	id := fmt.tprintf("AIODev.Test.Headless.%s.%d", name, os.get_pid())
	return testing.expect_value(t, platform.init(p, id), platform.Init_Result.Primary)
}

@(private = "file")
open_window :: proc(t: ^testing.T, p: ^platform.Platform, width, height: i32) -> input.Window_Id {
	id, err := platform.window_create(p, {title = "test", width = width, height = height, inactive = true})
	testing.expect_value(t, err, platform.Error.None)
	return id
}

// Taken off the queue, so the next read sees only what follows.
@(private = "file")
drain :: proc(p: ^platform.Platform) -> []platform.Event {
	events, _ := platform.poll_events(p)
	return events
}

// The topmost window under a point wins, and raising one brings it to the top; a hidden one is
// never hit.
@(test)
window_at_point_follows_z_order :: proc(t: ^testing.T) {
	p: platform.Platform
	if !platform_open(t, &p, "ZOrder") {return}
	defer _ = platform.destroy(&p)
	bottom := open_window(t, &p, 400, 300)
	top := open_window(t, &p, 400, 300)
	testing.expect_value(t, platform.window_set_position(&p, bottom, 100, 100), platform.Error.None)
	testing.expect_value(t, platform.window_set_position(&p, top, 300, 200), platform.Error.None)

	hit, x, y, err := platform.window_at_point(&p, 350, 250)
	testing.expect_value(t, err, platform.Error.None)
	testing.expect_value(t, hit, top)
	testing.expect_value(t, x, i32(50))
	testing.expect_value(t, y, i32(50))
	hit, _, _, _ = platform.window_at_point(&p, 150, 150)
	testing.expect_value(t, hit, bottom)

	testing.expect_value(t, platform.window_show_raised(&p, bottom), platform.Error.None)
	hit, _, _, _ = platform.window_at_point(&p, 350, 250)
	testing.expect_value(t, hit, bottom)
	testing.expect_value(t, platform.window_hide(&p, bottom), platform.Error.None)
	hit, _, _, _ = platform.window_at_point(&p, 350, 250)
	testing.expect_value(t, hit, top)
	hit, _, _, _ = platform.window_at_point(&p, 5, 5)
	testing.expect_value(t, hit, input.Window_Id(0))
}

// Focusing a window takes focus from the one that had it, with an event for each.
@(test)
focus_moves_with_events :: proc(t: ^testing.T) {
	p: platform.Platform
	if !platform_open(t, &p, "Focus") {return}
	defer _ = platform.destroy(&p)
	a := open_window(t, &p, 200, 100)
	b := open_window(t, &p, 200, 100)
	testing.expect(t, !platform.window_is_focused(&p, a) && !platform.window_is_focused(&p, b))
	_ = drain(&p)
	testing.expect_value(t, platform.window_focus(&p, a), platform.Error.None)
	testing.expect_value(t, platform.window_focus(&p, b), platform.Error.None)
	testing.expect(t, platform.window_is_focused(&p, b) && !platform.window_is_focused(&p, a))
	focus := make([dynamic]platform.Focus_Event, context.temp_allocator)
	for e in drain(&p) {
		if f, ok := e.(platform.Focus_Event); ok {append(&focus, f)}
	}
	expected := []platform.Focus_Event{{a, true}, {a, false}, {b, true}}
	if testing.expect_value(t, len(focus), len(expected)) {
		for f, i in focus {testing.expect_value(t, f, expected[i])}
	}
	// The windows cascade, so this point is in both; focusing raised b above a.
	hit, _, _, _ := platform.window_at_point(&p, 40, 40)
	testing.expect_value(t, hit, b)
	testing.expect_value(t, platform.window_focus(&p, a), platform.Error.None)
	hit, _, _, _ = platform.window_at_point(&p, 40, 40)
	testing.expect_value(t, hit, a)
}

// Moving a window onto a display of another DPI reports the new DPI, as WM_DPICHANGED does.
@(test)
moving_between_displays_reports_dpi :: proc(t: ^testing.T) {
	p: platform.Platform
	if !platform_open(t, &p, "Dpi") {return}
	defer _ = platform.destroy(&p)
	displays := []platform.Display{{rect = {0, 0, 1920, 1080}, dpi = 96}, {rect = {1920, 0, 3840, 2160}, dpi = 192}}
	testing.expect_value(t, platform.set_displays(&p, displays), platform.Error.None)
	id := open_window(t, &p, 400, 300)
	testing.expect_value(t, platform.window_dpi(&p, id), u32(96))
	_ = drain(&p)
	testing.expect_value(t, platform.window_set_position(&p, id, 2400, 100), platform.Error.None)
	testing.expect_value(t, platform.window_dpi(&p, id), u32(192))
	got: []platform.Event = drain(&p)
	testing.expect_value(t, len(got), 1)
	if len(got) == 1 {testing.expect_value(t, got[0], platform.Event(platform.Dpi_Event{id, 192}))}
	testing.expect_value(t, platform.window_set_position(&p, id, 2500, 100), platform.Error.None)
	testing.expect_value(t, len(drain(&p)), 0)
	testing.expect_value(t, platform.primary_dpi(&p), u32(96))
}

// The in-memory clipboard round-trips text with CRLF line breaks, as the Windows one stores them,
// and never touches the real clipboard.
@(test)
clipboard_round_trips_in_memory :: proc(t: ^testing.T) {
	p: platform.Platform
	if !platform_open(t, &p, "Clipboard") {return}
	defer _ = platform.destroy(&p)
	testing.expect(t, platform.clipboard_set_text(&p, "one\ntwo\r\nthree ✓"))
	text, ok := platform.clipboard_get_text(&p, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, text, "one\r\ntwo\r\nthree ✓")
	testing.expect(t, platform.clipboard_set_text(&p, ""))
	text, ok = platform.clipboard_get_text(&p, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, text, "")
}

// Many wakes before the loop polls produce one Wake_Event, and a pending wake ends a wait at once.
@(test)
wakes_coalesce :: proc(t: ^testing.T) {
	p: platform.Platform
	if !platform_open(t, &p, "Wake") {return}
	defer _ = platform.destroy(&p)
	_ = drain(&p)
	for _ in 0 ..< 5 {testing.expect_value(t, platform.wake(&p), platform.Error.None)}
	signaled, err := platform.wait_events(&p, 60_000, nil)
	testing.expect_value(t, err, platform.Error.None)
	testing.expect_value(t, signaled, -1)
	wakes := 0
	for e in drain(&p) {
		if _, ok := e.(platform.Wake_Event); ok {wakes += 1}
	}
	testing.expect_value(t, wakes, 1)
	testing.expect_value(t, len(drain(&p)), 0)
}

// Synthesized keys type with the US layout whatever the machine's layout is, and carry real
// virtual-key and scan codes for ConPTY's win32-input mode.
@(test)
keys_type_with_the_us_layout :: proc(t: ^testing.T) {
	buffer: [16]u8
	e, err := platform.synthesize_key(1, .Q, {.Shift}, true, buffer[:])
	testing.expect_value(t, err, platform.Error.None)
	testing.expect_value(t, e.text, "Q")
	testing.expect_value(t, e.unshifted, 'q')
	testing.expect_value(t, e.native.vk, u16(0x51))
	testing.expect_value(t, e.native.scan_code, u16(0x10))
	e, err = platform.synthesize_key(1, .Semicolon, {}, true, buffer[:])
	testing.expect_value(t, err, platform.Error.None)
	testing.expect_value(t, e.text, ";")
}
