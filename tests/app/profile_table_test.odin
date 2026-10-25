package app_test

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import app "../../src"
import "aio:platform"
import "aio:settings"
import "aio:ui"

@(private)
Profile_Fixture :: struct {
	state:     app.App,
	directory: string,
	path:      string,
}

@(private)
PROFILE_FIXTURE_SETTINGS :: `profile.alpha.name = Alpha
profile.alpha.command = cmd.exe
profile.alpha.directory = ~
profile.beta.name = Beta
profile.beta.command = cmd.exe
profile.beta.directory = ~
profile.gamma.name = Gamma
profile.gamma.command = cmd.exe
profile.gamma.directory = ~
profile.order = alpha, beta, gamma
shell.default_profile = default
`

@(private)
profile_fixture_create :: proc(
	t: ^testing.T,
	f: ^Profile_Fixture,
	name, text: string,
) -> bool {
	directory, directory_error := os.make_directory_temp("", "aio-profile-*", context.allocator)
	if !testing.expect_value(t, directory_error, nil) {return false}
	f.directory = directory
	f.path = strings.concatenate({directory, "/settings.ini"})
	if !testing.expect_value(t, os.write_entire_file(f.path, text), nil) {return false}
	f.state.options = {data_dir = directory, inactive = true}
	f.state.app_id = fmt.aprintf("AIODev.Test.Profile.%s.%d", name, os.get_pid())
	if !testing.expect_value(
		t,
		platform.init(&f.state.platform, f.state.app_id),
		platform.Init_Result.Primary,
	) {
		return false
	}
	f.state.platform_ready = true
	if !testing.expect(t, app.app_init(&f.state)) {return false}
	f.state.animations = false
	return true
}

@(private)
profile_fixture_destroy :: proc(t: ^testing.T, f: ^Profile_Fixture) {
	app.app_destroy(&f.state)
	if f.path != "" {
		testing.expect_value(t, os.remove(f.path), nil)
		delete(f.path)
	}
	if f.directory != "" {
		testing.expect_value(t, os.remove(f.directory), nil)
		delete(f.directory)
	}
}

@(private)
profile_open :: proc(f: ^Profile_Fixture) -> ^ui.Editor {
	app.settings_reveal_page(&f.state, &f.state.windows[0].editor, {search = .Clear, reload = true})
	return&f.state.windows[0].editor
}

@(private)
profile_item :: proc(p: ^ui.Editor, key: string) -> int {
	for item, index in p.items {
		if item.row >= 0 && p.rows[item.row].key == key {return index}
	}
	return -1
}

@(private)
profile_value :: proc(f: ^Profile_Fixture, id, field: string) -> string {
	profile := settings.profile_find(&f.state.settings.profiles, id)
	if profile == nil {return ""}
	switch field {
	case "name":
		return profile.name
	case "command":
		return profile.command
	case "directory":
		return profile.directory
	}
	return ""
}

@(private)
profile_file_has :: proc(path, line: string) -> bool {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {return false}
	for candidate in strings.split_lines(string(data), context.temp_allocator) {
		if strings.trim_space(candidate) == line {return true}
	}
	return false
}

@(private)
profile_file_text :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {return ""}
	return string(data)
}

@(private)
profile_file_lacks :: proc(path, prefix: string) -> bool {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {return true}
	for candidate in strings.split_lines(string(data), context.temp_allocator) {
		if strings.has_prefix(strings.trim_space(candidate), prefix) {return false}
	}
	return true
}

@(private)
profile_press :: proc(f: ^Profile_Fixture, key: platform.Key_Event) {
	e := key
	e.pressed = true
	w := f.state.windows[0]
	app.editor_outcome(&f.state, w, ui.editor_key(&w.editor, e))
}

@(test)
profile_table_writes_default_hidden_and_order :: proc(t: ^testing.T) {
	f: Profile_Fixture
	defer profile_fixture_destroy(t, &f)
	if !profile_fixture_create(t, &f, "writes", PROFILE_FIXTURE_SETTINGS) {return}
	e := profile_open(&f)
	if !testing.expect(t, ui.editor_select_key(e, "profile.beta")) {return}
	testing.expect_value(t, ui.editor_row(e).key, "profile.beta")
	testing.expect_value(t, ui.editor_key(e, {key = .Tab, pressed = true}), ui.Editor_Outcome.Changed)
	testing.expect_value(t, ui.editor_key(e, {key = .Enter, pressed = true}), ui.Editor_Outcome.Profile_Action)
	testing.expect_value(t, e.action, ui.Profile_Action.Default)
	app.editor_outcome(&f.state, f.state.windows[0], .Profile_Action)
	testing.expect(t, profile_file_has(f.path, `shell.default_profile = "beta"`))
	testing.expect(t, strings.contains(f.state.windows[0].editor.message, "Default profile saved"))
	testing.expect_value(t, f.state.windows[0].editor.error, false)
	testing.expect_value(t, f.state.settings.profiles.default_id, "beta")

	if !testing.expect(t, ui.editor_select_key(e, "profile.gamma")) {return}
	profile_press(&f, {key = .Tab})
	profile_press(&f, {key = .Arrow_Right})
	profile_press(&f, {key = .Space, text = " "})
	testing.expect(t, profile_file_has(f.path, "profile.gamma.hidden = true"))
	profile := settings.profile_find(&f.state.settings.profiles, "gamma")
	if testing.expect(t, profile != nil) {testing.expect(t, profile.hidden)}

	if !testing.expect(t, ui.editor_select_key(e, "profile.gamma")) {return}
	e.scroll = 0
	layout := ui.editor_layout({0, 40, 1200, 4000}, 1)
	gamma := profile_item(e, "profile.gamma")
	alpha := profile_item(e, "profile.alpha")
	if !testing.expect(t, gamma >= 0 && alpha >= 0) {return}
	handle := ui.editor_profile_parts(e, layout, gamma).handle
	alpha_row := ui.editor_row_parts(e, layout, alpha).row
	testing.expect_value(
		t,
		ui.editor_press(e, layout, nil, handle.x + handle.width / 2, handle.y + handle.height / 2, false),
		ui.Editor_Outcome.Changed,
	)
	testing.expect(t, ui.editor_drag(e, layout, nil, alpha_row.x + 40, alpha_row.y + 2))
	app.editor_outcome(&f.state, f.state.windows[0], ui.editor_release(e))
	testing.expectf(
		t,
		profile_file_has(f.path, "profile.order = gamma, alpha, beta, default"),
		"order file:\n%s",
		profile_file_text(f.path),
	)
	if testing.expect(t, profile_item(e, "profile.gamma") >= 0) {
		testing.expect_value(t, e.items[profile_item(e, "profile.gamma")].row >= 0, true)
	}
}

@(test)
profile_table_rejects_empty_duplicate_and_missing_commands :: proc(t: ^testing.T) {
	f: Profile_Fixture
	defer profile_fixture_destroy(t, &f)
	if !profile_fixture_create(t, &f, "validation", PROFILE_FIXTURE_SETTINGS) {return}
	e := profile_open(&f)
	before := profile_file_text(f.path)
	if !testing.expect(t, before != "") {return}

	if !testing.expect(t, ui.editor_select_key(e, "profile.alpha")) {return}
	profile_press(&f, {key = .Enter})
	testing.expect_value(t, e.expanded, "alpha")
	if !testing.expect(t, ui.editor_select_key(e, "profile.alpha.name")) {return}
	testing.expect_value(t, ui.editor_row(e).key, "profile.alpha.name")
	ui.field_set(&e.value, "beta")
	e.focus = .Control
	app.editor_outcome(&f.state, f.state.windows[0], .Save)
	testing.expect(t, f.state.windows[0].editor.error)
	testing.expect_value(t, f.state.windows[0].editor.error_key, "profile.alpha.name")
	testing.expectf(
		t,
		profile_file_text(f.path) == before,
		"before:\n%s\nafter:\n%s",
		before,
		profile_file_text(f.path),
	)

	if !testing.expect(t, ui.editor_select_key(e, "profile.alpha.name")) {return}
	ui.field_set(&e.value, "   ")
	e.focus = .Control
	app.editor_outcome(&f.state, f.state.windows[0], .Save)
	testing.expect_value(t, f.state.windows[0].editor.error_text, "A profile needs a name.")

	if !testing.expect(t, ui.editor_select_key(e, "profile.alpha.command")) {return}
	ui.field_set(&e.value, "missing.exe")
	e.focus = .Control
	app.editor_outcome(&f.state, f.state.windows[0], .Save)
	testing.expect(t, strings.contains(f.state.windows[0].editor.error_text, "Command not found"))
	testing.expect_value(t, profile_file_text(f.path), before)
}

@(test)
profile_table_enables_a_detected_shell_and_duplicates_and_removes :: proc(t: ^testing.T) {
	f: Profile_Fixture
	defer profile_fixture_destroy(t, &f)
	if !profile_fixture_create(t, &f, "detected", PROFILE_FIXTURE_SETTINGS) {return}
	testing.expect_value(
		t,
		settings.profile_detect(
			&f.state.settings,
			{"fake-shell", "Fake Shell", "cmd.exe", "~"},
		),
		nil,
	)
	testing.expect_value(t, settings.profiles_finalize(&f.state.settings), nil)
	e := profile_open(&f)

	if !testing.expect(t, ui.editor_select_key(e, "profiles.detected")) {return}
	profile_press(&f, {key = .Enter})
	testing.expect(t, e.detected_open)
	if !testing.expect(t, ui.editor_select_key(e, "profile.fake-shell")) {return}
	testing.expect_value(t, ui.editor_key(e, {key = .Enter, pressed = true}), ui.Editor_Outcome.Profile_Action)
	testing.expect_value(t, e.action, ui.Profile_Action.Enable)
	app.editor_outcome(&f.state, f.state.windows[0], .Profile_Action)
	testing.expectf(
		t,
		profile_file_has(f.path, `profile.fake-shell.name = "Fake Shell"`),
		"enable message=%s error=%s file:\n%s",
		f.state.windows[0].editor.message,
		f.state.windows[0].editor.error_text,
		profile_file_text(f.path),
	)
	testing.expect(t, profile_file_has(f.path, `profile.fake-shell.command = "cmd.exe"`))
	testing.expect(t, profile_file_has(f.path, `profile.fake-shell.directory = "~"`))
	testing.expect(t, profile_file_has(f.path, "profile.fake-shell.hidden = false"))
	testing.expect(t, profile_file_has(f.path, "profile.order = alpha, beta, gamma, default, fake-shell"))
	enabled := settings.profile_find(&f.state.settings.profiles, "fake-shell")
	if testing.expect(t, enabled != nil) {testing.expect(t, !enabled.detected)}

	if !testing.expect(t, ui.editor_select_key(e, "profile.beta")) {return}
	profile_press(&f, {key = .Tab})
	profile_press(&f, {key = .Delete})
	testing.expect_value(t, e.remove_confirm, "beta")
	if !testing.expect(t, ui.editor_select_key(e, "profile.beta.remove.confirm")) {return}
	app.editor_outcome(&f.state, f.state.windows[0], .Save)
	testing.expect(t, profile_file_lacks(f.path, "profile.beta."))
	testing.expect(t, profile_file_has(f.path, "profile.order = alpha, gamma, default, fake-shell"))
	testing.expect(t, settings.profile_find(&f.state.settings.profiles, "beta") == nil)

	if !testing.expect(t, ui.editor_select_key(e, "profile.alpha")) {return}
	profile_press(&f, {key = .Enter})
	ui.editor_profile_remove_ask(e, "alpha")
	testing.expect_value(t, e.remove_confirm, "alpha")
	if !testing.expect(t, ui.editor_select_key(e, "profile.alpha.duplicate")) {return}
	app.editor_outcome(&f.state, f.state.windows[0], .Save)
	testing.expect_value(t, e.remove_confirm, "")
	testing.expectf(
		t,
		profile_file_has(f.path, `profile.profile-1.name = "Alpha copy"`),
		"duplicate message=%s error=%s file:\n%s",
		f.state.windows[0].editor.message,
		f.state.windows[0].editor.error_text,
		profile_file_text(f.path),
	)
	testing.expect(t, profile_file_has(f.path, "profile.order = alpha, profile-1, gamma, default, fake-shell"))
	testing.expect_value(t, profile_value(&f, "profile-1", "command"), "cmd.exe")
}

@(test)
profile_table_keeps_the_built_in_default_and_resets_a_removed_default :: proc(t: ^testing.T) {
	f: Profile_Fixture
	defer profile_fixture_destroy(t, &f)
	if !profile_fixture_create(t, &f, "default", PROFILE_FIXTURE_SETTINGS) {return}
	e := profile_open(&f)
	for row in e.rows {
		if strings.has_prefix(row.key, "profile.default.remove") {
			testing.expectf(t, false, "default profile gained %s", row.key)
		}
		switch row.key {
		case "profile.alpha.name", "profile.alpha.hidden":
			testing.expect_value(t, row.default_value, row.value)
		}
	}

	if !testing.expect(t, ui.editor_select_key(e, "profile.beta")) {return}
	profile_press(&f, {key = .Tab})
	profile_press(&f, {key = .Enter})
	testing.expect_value(t, f.state.settings.profiles.default_id, "beta")

	if !testing.expect(t, ui.editor_select_key(e, "profile.beta")) {return}
	profile_press(&f, {key = .Tab})
	profile_press(&f, {key = .Delete})
	testing.expect_value(t, e.remove_confirm, "beta")
	app.editor_outcome(&f.state, f.state.windows[0], .Save)
	testing.expect(t, profile_file_lacks(f.path, "profile.beta."))
	testing.expect(t, profile_file_has(f.path, `shell.default_profile = "default"`))
	testing.expect_value(t, f.state.settings.profiles.default_id, "default")

	if !testing.expect(t, ui.editor_select_key(e, "profile.default")) {return}
	ui.editor_profile_remove_ask(e, "default")
	testing.expect_value(t, e.remove_confirm, "")
	profile_press(&f, {key = .Tab})
	profile_press(&f, {key = .Delete})
	testing.expect_value(t, e.remove_confirm, "")
	testing.expect(t, settings.profile_find(&f.state.settings.profiles, "default") != nil)
}

@(test)
profile_table_opens_detected_section_for_a_detected_default :: proc(t: ^testing.T) {
	f: Profile_Fixture
	defer profile_fixture_destroy(t, &f)
	text, replaced := strings.replace_all(
		PROFILE_FIXTURE_SETTINGS,
		"shell.default_profile = default",
		"shell.default_profile = fake-shell",
		context.temp_allocator,
	)
	if !testing.expect(t, replaced) {return}
	if !profile_fixture_create(t, &f, "detected-default", text) {return}
	testing.expect_value(
		t,
		settings.profile_detect(&f.state.settings, {"fake-shell", "Fake Shell", "cmd.exe", "~"}),
		nil,
	)
	testing.expect_value(t, settings.profiles_finalize(&f.state.settings), nil)
	e := profile_open(&f)
	testing.expect(t, e.detected_open)
	defaults := 0
	for row in e.rows {
		if .Default in row.flags {defaults += 1}
	}
	testing.expect_value(t, defaults, 1)
}

@(test)
profile_table_searches_by_profile_name :: proc(t: ^testing.T) {
	f: Profile_Fixture
	defer profile_fixture_destroy(t, &f)
	if !profile_fixture_create(t, &f, "search", PROFILE_FIXTURE_SETTINGS) {return}
	e := profile_open(&f)
	ui.field_set(&e.filter, "gamma")
	ui.editor_filter(e)
	row := ui.editor_row(e)
	if !testing.expect(t, row != nil) {return}
	testing.expect_value(t, row.key, "profile.gamma")
	testing.expect_value(t, row.title, "Gamma")
}
