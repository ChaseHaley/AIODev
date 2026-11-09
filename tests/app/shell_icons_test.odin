package app_test

import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import app "../../src"
import "aio:platform"
import "aio:render"
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

// Settings from `text`, read beside a folder holding icon.png; no window or device is created.
@(private)
Profile_Icon_Fixture :: struct {
	state:                 app.App,
	directory, icon, path: string,
}

@(private, require_results)
profile_icon_fixture_init :: proc(t: ^testing.T, f: ^Profile_Icon_Fixture, text: string) -> bool {
	directory_error: os.Error
	f.directory, directory_error = os.make_directory_temp("", "aio-icon-*", context.allocator)
	if !testing.expect_value(t, directory_error, nil) {return false}
	f.icon = strings.concatenate({f.directory, `\icon.png`})
	if !testing.expect_value(t, os.write_entire_file(f.icon, png_icon[:]), nil) {return false}
	parsed, diagnostics, parse_error := settings.parse(text)
	defer settings.diagnostics_destroy(&diagnostics)
	if !testing.expect_value(t, parse_error, nil) {return false}
	testing.expect_value(t, len(diagnostics), 0)
	f.state.settings = parsed
	f.path = strings.concatenate({f.directory, `\settings.ini`})
	f.state.settings_path = f.path
	ui.notices_init(&f.state.notices)
	return true
}

@(private)
profile_icon_fixture_destroy :: proc(f: ^Profile_Icon_Fixture) {
	app.shell_icons_destroy(&f.state.shell_icons)
	ui.notices_destroy(&f.state.notices)
	settings.destroy(&f.state.settings)
	if f.icon != "" {os.remove(f.icon)}
	if f.directory != "" {os.remove(f.directory)}
	delete(f.icon)
	delete(f.path)
	delete(f.directory)
}

// A session launched with `profile` whose shell shows `badge` and started `image`, as session_open
// records it.
@(private)
profile_icon_entry :: proc(profile, badge, image: string) -> app.Session_Entry {
	entry := app.Session_Entry{profile_id = strings.clone(profile)}
	entry.header.icon, entry.header.executable_path = badge, strings.clone(image)
	return entry
}

@(private)
profile_icon_entry_destroy :: proc(entry: ^app.Session_Entry) {
	delete(entry.profile_id)
	app.pane_header_destroy(&entry.header)
}

@(test)
shell_icon_load_accepts_local_png_and_refuses_device_and_oversized_files :: proc(t: ^testing.T) {
	f: Profile_Icon_Fixture
	defer profile_icon_fixture_destroy(&f)
	if !profile_icon_fixture_init(t, &f, "") {return}
	state := &f.state
	base := settings.profile_base(&state.settings.profiles)
	set_icon :: proc(base: ^settings.Profile, path: string) {
		delete(base.icon)
		base.icon = strings.clone(path)
	}

	set_icon(base, "icon.png")
	app.shell_icons_load(state)
	icon := app.shell_icon_find(state, base.id)
	if testing.expect(t, icon != nil, "a valid local PNG still loads") {
		testing.expect(t, icon.width > 0)
		testing.expect_value(t, icon.path, "icon.png")
	}
	testing.expect_value(t, len(state.notices.items), 0)

	// The extended-length alias reads the same local PNG, so only the path policy refuses it.
	device := strings.concatenate({`\\?\`, f.icon})
	defer delete(device)
	set_icon(base, device)
	app.shell_icons_load(state)
	testing.expect(t, app.shell_icon_find(state, base.id) == nil)
	testing.expect_value(t, len(state.notices.items), 1)

	// A valid PNG padded past the 32 MiB cap decodes only when the size guard is missing.
	oversized := strings.concatenate({f.directory, `\oversized.png`})
	defer delete(oversized)
	defer os.remove(oversized)
	if !testing.expect_value(t, os.write_entire_file(oversized, png_icon[:]), nil) {return}
	file, open_error := os.open(oversized, os.O_RDWR)
	if !testing.expect_value(t, open_error, nil) {return}
	truncate_error := os.truncate(file, (32 << 20) + 1)
	os.close(file)
	if !testing.expect_value(t, truncate_error, nil) {return}
	set_icon(base, "oversized.png")
	app.shell_icons_load(state)
	testing.expect(t, app.shell_icon_find(state, base.id) == nil)
	testing.expect_value(t, len(state.notices.items), 1)
}

@(test)
pane_draws_the_icon_of_the_profile_it_was_launched_with :: proc(t: ^testing.T) {
	f: Profile_Icon_Fixture
	defer profile_icon_fixture_destroy(&f)
	if !profile_icon_fixture_init(t, &f, "profile.cmd.name = Command Prompt\n" +
		"profile.cmd.command = cmd.exe\nprofile.cmd.icon = icon.png\n") {return}
	device, device_error := render.device_create(.Warp)
	if !testing.expect_value(t, device_error, render.Error.None) {return}
	defer render.device_destroy(device)
	f.state.device = device
	app.shell_icons_load(&f.state)
	defer app.program_icon_cache_destroy(&f.state.program_icons)

	other := profile_icon_entry("cmd", "C:", "")
	defer profile_icon_entry_destroy(&other)
	image, _ := app.pane_badge_source(&f.state, &other)
	if testing.expect(t, image != nil, "a non-default profile's pane draws that profile's Icon") {
		testing.expect_value(t, image.profile, "cmd")
	}
	badge, atlas, result := app.pane_icon(&f.state, &other, 16)
	testing.expect_value(t, result, render.Build_Status.Ok)
	testing.expect_value(t, badge, "C:")
	testing.expect(t, atlas.width > 0, "the Icon is drawn in place of the text badge")

	// The default profile has no Icon, and a session that started nothing has no icon of its own.
	plain := profile_icon_entry("default", ">_", "")
	defer profile_icon_entry_destroy(&plain)
	image, _ = app.pane_badge_source(&f.state, &plain)
	testing.expect(t, image == nil, "another profile's Icon is not drawn")
	badge, atlas, result = app.pane_icon(&f.state, &plain, 16)
	testing.expect_value(t, result, render.Build_Status.Ok)
	testing.expect_value(t, badge, ">_")
	testing.expect_value(t, atlas.width, 0)
}

@(test)
empty_icon_on_a_pwsh_profile_resolves_to_the_pwsh_executables_icon :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "pwsh-icon", second_window = false) {return}
	s := &f.state
	base := settings.profile_base(&s.settings.profiles)
	testing.expect_value(t, base.icon, "")
	delete(base.command)
	base.command = strings.clone("pwsh.exe -NoLogo -NoProfile")
	id, created := app.tab_create(s, s.windows[0].workspace, profile_id = base.id)
	if !testing.expect(t, created) {return}
	entry := app.session_find(s, id)
	image, executable := app.pane_badge_source(s, entry)
	testing.expect(t, image == nil)
	// The Store's pwsh.exe is an alias; the icon is read from the executable it started.
	testing.expect(t, strings.has_suffix(strings.to_lower(executable, context.temp_allocator), `\pwsh.exe`),
		"an empty Icon stands for the launched pwsh.exe")
	pixels: [16 * 16 * 4]u8
	testing.expect(t, platform.executable_icon(executable, 16, pixels[:]), "pwsh.exe carries its own icon")
	_, atlas, result := app.pane_icon(s, entry, 16)
	for deadline := time.tick_now(); atlas.width == 0 && result == .Ok; {
		if time.tick_since(deadline) > 5 * time.Second {break}
		time.sleep(10 * time.Millisecond)
		_, _ = app.program_icons_adopt(s)
		_, atlas, result = app.pane_icon(s, entry, 16)
	}
	testing.expect_value(t, result, render.Build_Status.Ok)
	testing.expect(t, atlas.width > 0, "the pane draws pwsh's own icon")
}

@(test)
explicit_profile_icon_wins_over_the_executables_own_icon :: proc(t: ^testing.T) {
	f: Profile_Icon_Fixture
	defer profile_icon_fixture_destroy(&f)
	if !profile_icon_fixture_init(t, &f, "profile.default.command = cmd.exe\n" +
		"profile.default.icon = icon.png\n") {return}
	app.shell_icons_load(&f.state)

	root, _ := os.lookup_env("SystemRoot", context.temp_allocator)
	cmd := strings.concatenate({root, `\System32\cmd.exe`}, context.temp_allocator)
	pixels: [16 * 16 * 4]u8
	testing.expect(t, platform.executable_icon(cmd, 16, pixels[:]), "the executable's icon is there to lose")
	entry := profile_icon_entry("default", "C:", cmd)
	defer profile_icon_entry_destroy(&entry)
	image, executable := app.pane_badge_source(&f.state, &entry)
	if testing.expect(t, image != nil, "the explicit Icon wins") {
		testing.expect_value(t, image.path, "icon.png")
	}
	testing.expect_value(t, executable, "")
}
