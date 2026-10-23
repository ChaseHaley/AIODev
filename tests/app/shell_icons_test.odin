package app_test

import "core:os"
import "core:strings"
import "core:testing"
import app "../../src"
import "aio:settings"
import "aio:ui"

// A 2 x 2, 8-bit RGBA PNG: small enough to decode, real enough to prove the loader still runs.
@(private)
png_icon := [?]u8 {
	0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
	0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
	0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02,
	0x08, 0x06, 0x00, 0x00, 0x00, 0x72, 0xB6, 0x0D,
	0x24, 0x00, 0x00, 0x00, 0x11, 0x49, 0x44, 0x41,
	0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0xF0,
	0x1F, 0x84, 0x19, 0x60, 0x0C, 0x00, 0x47, 0xCA,
	0x07, 0xF9, 0x67, 0x59, 0x6E, 0xB7, 0x00, 0x00,
	0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42,
	0x60, 0x82,
}

// The icon loader only needs settings, notices, and a settings path, so no window or device is
// created; the atlas upload and rendering are covered by the other app tests.
@(test)
shell_icon_load_accepts_local_png_and_refuses_device_and_oversized_files :: proc(t: ^testing.T) {
	directory, directory_error := os.make_directory_temp("", "aio-icon-*", context.allocator)
	if !testing.expect_value(t, directory_error, nil) {return}
	defer delete(directory)
	defer os.remove(directory)

	icon := strings.concatenate({directory, `\icon.png`})
	defer delete(icon)
	defer os.remove(icon)
	if !testing.expect_value(t, os.write_entire_file(icon, png_icon[:]), nil) {return}

	state := app.App{}
	state.settings_path = strings.concatenate({directory, `\settings.ini`})
	defer delete(state.settings_path)
	defer settings.destroy(&state.settings)
	ui.notices_init(&state.notices)
	defer ui.notices_destroy(&state.notices)

	state.settings.shell.icon = "icon.png"
	app.shell_icon_load(&state)
	testing.expect(t, state.shell_icon.width > 0, "a valid local PNG still loads")
	testing.expect_value(t, len(state.notices.items), 0)

	// The extended-length alias reads the same local PNG, so only the path policy refuses it.
	device := strings.concatenate({`\\?\`, icon})
	defer delete(device)
	state.settings.shell.icon = device
	app.shell_icon_load(&state)
	testing.expect_value(t, state.shell_icon.width, 0)
	testing.expect_value(t, len(state.notices.items), 1)

	// A valid PNG padded past the 32 MiB cap decodes only when the size guard is missing.
	oversized := strings.concatenate({directory, `\oversized.png`})
	defer delete(oversized)
	defer os.remove(oversized)
	if !testing.expect_value(t, os.write_entire_file(oversized, png_icon[:]), nil) {return}
	file, open_error := os.open(oversized, os.O_RDWR)
	if !testing.expect_value(t, open_error, nil) {return}
	truncate_error := os.truncate(file, (32 << 20) + 1)
	os.close(file)
	if !testing.expect_value(t, truncate_error, nil) {return}
	state.settings.shell.icon = "oversized.png"
	app.shell_icon_load(&state)
	testing.expect_value(t, state.shell_icon.width, 0)
	testing.expect_value(t, len(state.notices.items), 1)
}
