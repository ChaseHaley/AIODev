package headless_test

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import app "../../src"
import "aio:platform"
import "aio:render"

// The whole app frame renders offscreen at a chosen DPI, the real build_frame and no window
// (VT-6's frame harness): a display at 144 DPI scales the window by 1.5, and moving the window to a
// 192 DPI display rescales it and draws again.
@(test)
whole_frame_renders_at_chosen_dpis :: proc(t: ^testing.T) {
	directory, err := os.make_directory_temp("", "aio-headless-dpi-*", context.allocator)
	if !testing.expect_value(t, err, nil) {return}
	defer {
		_ = os.remove_all(directory)
		delete(directory)
	}
	settings := strings.concatenate({directory, "/settings.ini"}, context.temp_allocator)
	written := os.write_entire_file(settings, transmute([]u8)string("shell.command = cmd.exe /d /q /k\n"))
	if !testing.expect_value(t, written, nil) {return}
	state := app.App{options = {data_dir = directory, inactive = true}}
	state.app_id = fmt.aprintf("AIODev.Test.HeadlessDpi.%d", os.get_pid())
	defer app.app_destroy(&state)
	if !testing.expect_value(t, platform.init(&state.platform, state.app_id), platform.Init_Result.Primary) {
		delete(state.app_id)
		return
	}
	state.platform_ready = true
	displays := []platform.Display{{rect = {0, 0, 2560, 1440}, dpi = 144}, {rect = {2560, 0, 6400, 2160}, dpi = 192}}
	if !testing.expect_value(t, platform.set_displays(&state.platform, displays), platform.Error.None) {return}
	if !testing.expect(t, app.app_init(&state)) {return}
	state.animations = false
	w := state.windows[0]
	for _ in 0 ..< 3 {app.tick(&state)}
	testing.expect_value(t, w.scale, f32(1.5))
	first := frame_size(t, &state, w)

	testing.expect_value(t, platform.window_set_position(&state.platform, w.id, 3000, 100), platform.Error.None)
	for _ in 0 ..< 3 {app.tick(&state)}
	testing.expect_value(t, w.scale, f32(2))
	second := frame_size(t, &state, w)
	testing.expect(t, second > 0 && first > 0, "a frame was not drawn")
}

// Reads back the window's last frame and returns its byte count, after checking it is not blank.
@(private = "file")
frame_size :: proc(t: ^testing.T, state: ^app.App, w: ^app.Window) -> int {
	surface := app.window_surface(w)
	if !testing.expect(t, surface != nil, "the window has no surface") {return 0}
	pixels, err := render.surface_read_pixels(state.device, surface, context.allocator)
	if !testing.expect_value(t, err, render.Error.None) {return 0}
	defer delete(pixels)
	testing.expect_value(t, len(pixels), int(w.width * w.height * 4))
	varied := false
	for i := 4; i < len(pixels); i += 4 {
		if pixels[i] != pixels[0] || pixels[i + 1] != pixels[1] || pixels[i + 2] != pixels[2] {varied = true; break}
	}
	testing.expect(t, varied, "the frame is one flat colour")
	return len(pixels)
}
