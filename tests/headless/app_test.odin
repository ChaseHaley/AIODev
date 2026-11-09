package headless_test

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import w "core:sys/windows"
import "core:testing"
import app "../../src"
import "aio:platform"
import "aio:render"

// The whole app, started through app_init with the headless backend: it opens a window on the
// virtual desktop, splits a pane and draws offscreen, and the test process owns no window on the
// real desktop.
@(test)
app_runs_splits_and_draws_without_a_desktop_window :: proc(t: ^testing.T) {
	directory, err := os.make_directory_temp("", "aio-headless-*", context.allocator)
	if !testing.expect_value(t, err, nil) {return}
	defer {
		_ = os.remove_all(directory)
		delete(directory)
	}
	settings := strings.concatenate({directory, "/settings.ini"}, context.temp_allocator)
	written := os.write_entire_file(settings, transmute([]u8)string("shell.command = cmd.exe /d /q /k\n"))
	if !testing.expect_value(t, written, nil) {return}
	state := app.App{options = {data_dir = directory, inactive = true}}
	state.app_id = fmt.aprintf("AIODev.Test.Headless.%d", os.get_pid())
	defer app.app_destroy(&state)
	if !testing.expect_value(t, platform.init(&state.platform, state.app_id), platform.Init_Result.Primary) {
		delete(state.app_id)
		return
	}
	state.platform_ready = true
	if !testing.expect(t, app.app_init(&state)) {return}
	testing.expect_value(t, render.device_driver(state.device), render.Driver.Warp)
	w0 := state.windows[0]
	app.pane_split(&state, w0, .Right)
	testing.expect_value(t, len(w0.panes), 2)
	state.animations = false
	for _ in 0 ..< 3 {app.tick(&state)}
	surface := app.window_surface(w0)
	if !testing.expect(t, surface != nil, "the window has no surface") {return}
	presented, count_error := render.surface_present_count(surface)
	testing.expect_value(t, count_error, render.Error.None)
	testing.expect(t, presented > 0, "nothing was drawn")
	pixels, pixel_error := render.surface_read_pixels(state.device, surface, context.allocator)
	if !testing.expect_value(t, pixel_error, render.Error.None) {return}
	defer delete(pixels)
	testing.expect_value(t, len(pixels), int(w0.width * w0.height * 4))
	distinct_colors := 0
	first := [4]u8{pixels[0], pixels[1], pixels[2], pixels[3]}
	for i := 0; i < len(pixels); i += 4 {
		pixel := [4]u8{pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3]}
		if pixel != first {distinct_colors += 1}
	}
	testing.expect(t, distinct_colors > 0, "the frame is one flat colour")
	windows := process_windows()
	testing.expectf(t, len(windows) == 0, "the test process owns desktop windows: %v", windows)
}

// The class names of every top-level window this process owns.
@(private = "file")
process_windows :: proc() -> []string {
	found := make([dynamic]string, context.temp_allocator)
	w.EnumWindows(proc "system" (hwnd: w.HWND, lp: w.LPARAM) -> w.BOOL {
		pid: w.DWORD
		w.GetWindowThreadProcessId(hwnd, &pid)
		if pid != w.GetCurrentProcessId() {return true}
		list := (^[dynamic]string)(rawptr(uintptr(lp)))
		context = runtime.default_context()
		context.allocator = list.allocator
		class: [256]u16
		n := w.GetClassNameW(hwnd, &class[0], len(class))
		name, _ := w.utf16_to_utf8(class[:n], list.allocator)
		append(list, name)
		return true
	}, w.LPARAM(uintptr(&found)))
	return found[:]
}
