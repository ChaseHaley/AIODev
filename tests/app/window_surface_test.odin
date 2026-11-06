package app_test

import "core:os"
import "core:testing"
import app "../../src"

// A window can be left without a surface when device recovery cannot recreate it. It must survive a
// resize, a second recovery must rebuild it, and its next frame must create it if nothing else does.
@(test)
device_recovery_rebuilds_a_window_left_without_a_surface :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "device") { return }
	s := &f.state
	first, second := s.windows[0], s.windows[1]
	app.window_surface_release(first)
	app.window_resize(s, first, 640, 480)
	testing.expect(t, first.surface == nil)
	lost := s.device
	app.recover_device(s)
	testing.expect(t, s.running)
	testing.expect(t, s.device != lost)
	testing.expect(t, s.cache.device == s.device)
	testing.expect(t, first.surface != nil)
	testing.expect(t, second.surface != nil)
	app.window_surface_release(second)
	app.window_resize(s, second, 500, 400)
	app.tick(s)
	testing.expect(t, second.surface != nil)
}

// The dialog's answer is only for the window it was opened from, so it must not outlive that window.
@(test)
closing_a_window_closes_its_file_dialog :: proc(t: ^testing.T) {
	// GetOpenFileNameW changes the process's working directory despite OFN_NOCHANGEDIR, and the
	// runner writes its report relative to the working directory.
	directory, directory_error := os.get_working_directory(context.allocator)
	if !testing.expect_value(t, directory_error, nil) { return }
	defer delete(directory)
	defer testing.expect_value(t, os.set_working_directory(directory), nil)
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "dialog") { return }
	s := &f.state
	first, second := s.windows[0], s.windows[1]
	app.markdown_open_picker(s, second)
	if !testing.expect(t, s.markdown_pick != nil) { return }
	app.window_close(s, first)
	testing.expect(t, s.markdown_pick != nil)
	app.window_close(s, second)
	testing.expect(t, s.markdown_pick == nil)
}
