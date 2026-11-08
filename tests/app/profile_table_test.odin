package app_test

import "aio:input"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import app "../../src"
import "aio:platform"
import "aio:settings"
import "aio:ui"

@(test)
profile_detected_row_drag_survives_publication_and_reopen :: proc(t: ^testing.T) {
	f: Profile_Fixture
	defer profile_fixture_destroy(t, &f)
	if !profile_fixture_create(t, &f, "detected-order", PROFILE_FIXTURE_SETTINGS) {return}
	id := ""
	for profile in f.state.settings.profiles.items {
		if profile.detected {id = strings.clone(profile.id, context.temp_allocator); break}
	}
	if !testing.expect(t, id != "") {return}
	e := profile_open(&f)
	l := ui.editor_layout({0, 40, 1200, 8000}, 1)
	ui.editor_fit(e, l)
	item := profile_item(e, fmt.tprintf("profile.%s", id))
	alpha := profile_item(e, "profile.alpha")
	if !testing.expect(t, item >= 0 && alpha >= 0) {return}
	handle := ui.editor_profile_parts(e, l, item).handle
	target := ui.editor_row_parts(e, l, alpha).row
	testing.expect_value(t, ui.editor_press(e, l, nil, handle.x + 10, handle.y + 20, false), ui.Editor_Outcome.Changed)
	testing.expect(t, ui.editor_drag(e, l, nil, target.x + 40, target.y))
	app.editor_outcome(&f.state, f.state.windows[0], ui.editor_release(e))
	testing.expect(t, !e.error)
	testing.expect_value(t, f.state.settings.profiles.order[0], id)
	e = profile_open(&f)
	for row in e.rows {
		if row.kind == .Profile {
			testing.expect_value(t, row.profile, id)
			break
		}
	}
}

@(test)
profile_add_and_remove_preserve_settings_scroll :: proc(t: ^testing.T) {
	f: Profile_Fixture
	defer profile_fixture_destroy(t, &f)
	if !profile_fixture_create(t, &f, "viewport", PROFILE_FIXTURE_SETTINGS) {return}
	e := profile_open(&f)
	if !testing.expect(t, ui.editor_select_key(e, "profiles.add")) {return}
	e.scroll = 35
	app.editor_outcome(&f.state, f.state.windows[0], .Save)
	testing.expect_value(t, e.scroll, 35)
	ui.editor_request_set(e, ui.Profile_Request{.Remove, strings.clone("profile-1")})
	app.editor_outcome(&f.state, f.state.windows[0], .Profile_Action)
	removing := app.confirmation_asking(f.state.windows[0], app.Profile_Remove)
	if !testing.expect(t, removing != nil) {return}
	testing.expect_value(t, app.editor_profile_remove_text(removing^).title, "Delete New Profile?")
	e.scroll = 35
	app.confirmation_finish(&f.state, f.state.windows[0], true)
	testing.expect_value(t, e.scroll, 35)
}

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
	_ = app.settings_load(&f.state, &f.state.windows[0].editor)
	app.settings_reveal_page(&f.state.windows[0].editor, {search = .Clear})
	ui.editor_fit(&f.state.windows[0].editor, ui.editor_layout({0, 40, 1200, 1400}, 1))
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
profile_press :: proc(f: ^Profile_Fixture, key: input.Key_Event) {
	e := key
	e.pressed = true
	w := f.state.windows[0]
	app.editor_outcome(&f.state, w, ui.editor_key(&w.editor, e))
}

@(test)
profile_show_in_menus_inverts_persistence_and_resets_to_shown :: proc(t: ^testing.T) {
	f: Profile_Fixture
	defer profile_fixture_destroy(t, &f)
	if !profile_fixture_create(t, &f, "show-in-menus", PROFILE_FIXTURE_SETTINGS) {return}
	e := profile_open(&f)
	if !testing.expect(t, ui.editor_select_key(e, "profile.alpha")) {return}
	profile_press(&f, {key = .Enter})
	if !testing.expect(t, ui.editor_select_key(e, "profile.alpha.hidden")) {return}
	testing.expect_value(t, ui.editor_row(e).title, "Show in menus")
	testing.expect_value(t, ui.editor_row(e).value, "true")
	testing.expect_value(t, ui.editor_row(e).default_value, "true")
	ui.field_set(&e.value, "false")
	app.editor_outcome(&f.state, f.state.windows[0], .Save)
	testing.expect(t, profile_file_has(f.path, "profile.alpha.hidden = true"))
	testing.expect_value(t, ui.editor_row(e).value, "false")
	app.editor_outcome(&f.state, f.state.windows[0], .Reset)
	testing.expect(t, profile_file_has(f.path, "profile.alpha.hidden = false"))
	testing.expect_value(t, ui.editor_row(e).value, "true")
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
	request, requested := e.request.(ui.Profile_Request)
	testing.expect(t, requested && request.action == .Default)
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
	layout := ui.editor_layout({0, 40, 1200, 8000}, 1)
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
		strings.contains(profile_file_text(f.path), "profile.order = gamma, alpha, beta,"),
		"order file:\n%s",
		profile_file_text(f.path),
	)
	if testing.expect(t, profile_item(e, "profile.gamma") >= 0) {
		testing.expect_value(t, e.items[profile_item(e, "profile.gamma")].row >= 0, true)
	}
	ordered: [settings.PROFILE_LIMIT]int
	count := settings.profiles_in_order(&f.state.settings.profiles, ordered[:])
	if testing.expect(t, count > 0) {
		testing.expect_value(t, f.state.settings.profiles.items[ordered[0]].id, "gamma")
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
	ui.editor_focus_row(e)
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
	ui.editor_focus_row(e)
	app.editor_outcome(&f.state, f.state.windows[0], .Save)
	testing.expect_value(t, f.state.windows[0].editor.error_text, "A profile needs a name.")

	if !testing.expect(t, ui.editor_select_key(e, "profile.alpha.command")) {return}
	ui.field_set(&e.value, "missing.exe")
	ui.editor_focus_row(e)
	app.editor_outcome(&f.state, f.state.windows[0], .Save)
	testing.expect(t, strings.contains(f.state.windows[0].editor.error_text, "Command not found"))
	testing.expect_value(t, profile_file_text(f.path), before)
}

@(test)
profile_table_and_inline_save_agree_on_detected_names :: proc(t: ^testing.T) {
	f: Profile_Fixture
	defer profile_fixture_destroy(t, &f)
	if !profile_fixture_create(t, &f, "name-facts", PROFILE_FIXTURE_SETTINGS) {return}
	testing.expect_value(t, settings.profile_detect(&f.state.settings, {"found", "  ALPHA  ", "cmd.exe", "~"}), nil)
	e := profile_open(&f)
	table, error := ui.profile_table_build(&f.state.settings.profiles)
	defer ui.profile_table_destroy(&table)
	testing.expect_value(t, error, nil)
	for row in table.rows {if row.id == "alpha" {testing.expect_value(t, row.note, "")}}
	if !testing.expect(t, ui.editor_select_key(e, "profile.alpha")) {return}
	profile_press(&f, {key = .Enter})
	if !testing.expect(t, ui.editor_select_key(e, "profile.alpha.name")) {return}
	ui.field_set(&e.value, "Alpha")
	ui.editor_focus_row(e)
	app.editor_outcome(&f.state, f.state.windows[0], .Save)
	testing.expect(t, !e.error)
	testing.expect(t, profile_file_has(f.path, `profile.alpha.name = "Alpha"`))
	testing.expect_value(t, profile_value(&f, "alpha", "name"), "Alpha")
	before := profile_file_text(f.path)
	if !testing.expect(t, ui.editor_select_key(e, "profile.alpha.name")) {return}
	ui.field_set(&e.value, "  bETA  ")
	ui.editor_focus_row(e)
	app.editor_outcome(&f.state, f.state.windows[0], .Save)
	testing.expect_value(t, e.error_text, "Another profile uses this name.")
	testing.expect_value(t, profile_file_text(f.path), before)
	if !testing.expect(t, ui.editor_select_key(e, "profile.alpha.command")) {return}
	ui.field_set(&e.value, " \t ")
	ui.editor_focus_row(e)
	app.editor_outcome(&f.state, f.state.windows[0], .Save)
	testing.expect_value(t, e.error_text, "A profile needs a command line.")
	testing.expect_value(t, profile_file_text(f.path), before)
}

@(test)
profile_generated_names_have_no_table_warning_and_save_unchanged :: proc(t: ^testing.T) {
	f: Profile_Fixture
	defer profile_fixture_destroy(t, &f)
	if !profile_fixture_create(t, &f, "generated-names", PROFILE_FIXTURE_SETTINGS) {return}
	e := profile_open(&f)
	for key, index in ([?]string{"profiles.add", "profiles.add", "profile.alpha.duplicate", "profile.alpha.duplicate"}) {
		if key == "profile.alpha.duplicate" {
			ui.editor_request_set(e, ui.Profile_Request{.Duplicate, strings.clone("alpha")})
			app.editor_outcome(&f.state, f.state.windows[0], .Profile_Action)
		} else {
			if !testing.expect(t, ui.editor_reveal(e, ui.Reveal_Row{key})) {return}
			app.editor_outcome(&f.state, f.state.windows[0], .Save)
		}
		if !testing.expect(t, !e.error) {return}
		id := fmt.tprintf("profile-%d", index + 1)
		profile := settings.profile_find(&f.state.settings.profiles, id)
		if !testing.expect(t, profile != nil) {return}
		name := strings.clone(profile.name, context.temp_allocator)
		table, error := ui.profile_table_build(&f.state.settings.profiles)
		defer ui.profile_table_destroy(&table)
		testing.expect_value(t, error, nil)
		for row in table.rows {if row.id == id {testing.expect_value(t, row.note, "")}}
		if !testing.expect(t, ui.editor_reveal(e, ui.Reveal_Row{fmt.tprintf("profile.%s.name", id)})) {return}
		ui.field_set(&e.value, name)
		ui.editor_focus_row(e)
		app.editor_outcome(&f.state, f.state.windows[0], .Save)
		testing.expect(t, !e.error)
		testing.expect_value(t, profile_value(&f, id, "name"), name)
	}
}

@(test)
profile_table_reuses_detected_default_identity_on_reopen :: proc(t: ^testing.T) {
	f: Profile_Fixture
	defer profile_fixture_destroy(t, &f)
	if !profile_fixture_create(t, &f, "default-identity",
		"profile.order = default, pwsh\nprofile.pwsh.hidden = true\n",
	) {return}
	for _ in 0 ..< 2 {
		e := profile_open(&f)
		testing.expect(t, !ui.editor_select_key(e, "profile.pwsh"))
		testing.expect(t, ui.editor_select_key(e, "profile.default"))
		testing.expect(t, .Protected in ui.editor_row(e).flags)
	}
}

@(test)
profile_table_includes_detected_and_confirms_custom_removal :: proc(t: ^testing.T) {
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
	// Pages read machine shells from the revision's input snapshot, which the running settings
	// were parsed with; the fake shell joins both.
	inputs := &f.state.settings_inputs
	detected := make([dynamic]settings.Detected_Profile, context.temp_allocator)
	append(&detected, ..inputs.detected[:])
	append(&detected, settings.Detected_Profile{"fake-shell", "Fake Shell", "cmd.exe", "~"})
	replacement, inputs_error := settings.inputs_read(inputs.themes_directory, detected[:])
	if !testing.expect_value(t, inputs_error, nil) {return}
	settings.inputs_destroy(inputs)
	inputs^ = replacement
	e := profile_open(&f)

	testing.expect(t, !ui.editor_select_key(e, "profiles.detected"))
	testing.expect(t, ui.editor_select_key(e, "profile.fake-shell"))
	testing.expect(t, .Protected in ui.editor_row(e).flags)
	profile_press(&f, {key = .Tab})
	profile_press(&f, {key = .Delete})
	testing.expect(t, app.confirmation_asking(f.state.windows[0], app.Profile_Remove) == nil)
	testing.expect(t, settings.profile_visible(settings.profile_find(&f.state.settings.profiles, "fake-shell")))
	app.editor_profile_remove_ask(&f.state, f.state.windows[0], "fake-shell")
	testing.expect(t, app.confirmation_asking(f.state.windows[0], app.Profile_Remove) == nil)

	testing.expect(t, ui.editor_select_key(e, "profile.beta"))
	ui.editor_focus_row(e)
	profile_press(&f, {key = .Delete})
	testing.expect(t, app.confirmation_asking(f.state.windows[0], app.Profile_Remove) != nil)
	app.confirmation_finish(&f.state, f.state.windows[0], false)
	testing.expect(t, !profile_file_lacks(f.path, "profile.beta.command"))
	app.editor_profile_remove_ask(&f.state, f.state.windows[0], "beta")
	app.confirmation_finish(&f.state, f.state.windows[0], true)
	testing.expect(t, profile_file_lacks(f.path, "profile.beta."))
	testing.expect(t, settings.profile_find(&f.state.settings.profiles, "beta") == nil)
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
	testing.expect(t, app.confirmation_asking(f.state.windows[0], app.Profile_Remove) != nil)
	app.confirmation_finish(&f.state, f.state.windows[0], true)
	testing.expect(t, profile_file_lacks(f.path, "profile.beta."))
	testing.expect(t, profile_file_has(f.path, `shell.default_profile = "default"`))
	testing.expect_value(t, f.state.settings.profiles.default_id, "default")

	if !testing.expect(t, ui.editor_select_key(e, "profile.default")) {return}
	profile_press(&f, {key = .Tab})
	profile_press(&f, {key = .Delete})
	testing.expect(t, app.confirmation_asking(f.state.windows[0], app.Profile_Remove) == nil)
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
