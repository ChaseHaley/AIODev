package app_test

// The headless backend answers file dialogs from a script; the desktop build compiles these out.
@(require) import "core:os"
@(require) import "core:path/filepath"
@(require) import "core:strings"
@(require) import "core:testing"
@(require) import app "../../src"
@(require) import "aio:platform"
@(require) import "aio:settings"
@(require) import "aio:ui"

when platform.AIO_HEADLESS {
	// Presses the Browse button of row `key`, answers its file dialog with `answer` (empty cancels)
	// and lets the app collect the answer, as the event loop's tick does.
	@(private = "file")
	icon_browse :: proc(t: ^testing.T, f: ^Profile_Fixture, key, answer: string) -> bool {
		w := f.state.windows[0]
		e := &w.editor
		if !testing.expect(t, ui.editor_select_key(e, key), key) {return false}
		l := ui.editor_layout({0, 40, 1200, 8000}, 1, true)
		ui.editor_fit(e, l)
		browse := ui.editor_row_parts(e, l, e.selected).browse
		if !testing.expect(t, browse.width > 0, key) {return false}
		testing.expect_value(t, platform.file_pick_script(&f.state.platform, answer), platform.Error.None)
		outcome := ui.editor_press(e, l, nil, browse.x + browse.width / 2, browse.y + browse.height / 2, false)
		if !testing.expect_value(t, outcome, ui.Editor_Outcome.Browse_Icon) {return false}
		app.editor_outcome(&f.state, w, outcome)
		if !testing.expect(t, f.state.dialogs.icon != nil, "the icon dialog opened") {return false}
		app.file_dialogs_tick(&f.state)
		return testing.expect(t, f.state.dialogs.icon == nil, "the icon dialog closed")
	}

	// The last file dialog the app opened, as the headless platform recorded it.
	@(private = "file")
	icon_browse_last :: proc(f: ^Profile_Fixture) -> platform.File_Pick_Record {
		picks := f.state.platform.record.file_picks
		return len(picks) > 0 ? picks[len(picks) - 1] : {}
	}

	// Browse on a profile's Icon opens a PNG dialog owned by the window; a cancel writes nothing, and
	// a chosen PNG saves to the file, loads as the profile's icon and fills the field. The next dialog
	// starts in that PNG's folder.
	@(test)
	icon_browse_chooses_a_profile_icon_and_cancel_keeps_it :: proc(t: ^testing.T) {
		f: Profile_Fixture
		defer profile_fixture_destroy(t, &f)
		if !profile_fixture_create(t, &f, "icon-browse", PROFILE_FIXTURE_SETTINGS) {return}
		icon := strings.concatenate({f.directory, `\chosen.png`}, context.temp_allocator)
		if !testing.expect_value(t, os.write_entire_file(icon, png_icon[:]), nil) {return}
		defer os.remove(icon)
		e := profile_open(&f)
		if !testing.expect(t, ui.editor_select_key(e, "profile.alpha")) {return}
		profile_press(&f, {key = .Enter})
		testing.expect_value(t, e.expanded, "alpha")

		if !icon_browse(t, &f, "profile.alpha.icon", "") {return}
		pick := icon_browse_last(&f)
		testing.expect_value(t, pick.window, f.state.windows[0].id)
		testing.expect_value(t, pick.filter_name, "PNG images")
		testing.expect_value(t, pick.pattern, "*.png")
		testing.expect_value(t, pick.directory, "")
		testing.expect(t, !pick.folders)
		testing.expect(t, profile_file_lacks(f.path, "profile.alpha.icon"))
		testing.expect(t, app.shell_icon_find(&f.state, "alpha") == nil)

		if !icon_browse(t, &f, "profile.alpha.icon", icon) {return}
		profile := settings.profile_find(&f.state.settings.profiles, "alpha")
		if !testing.expect(t, profile != nil) {return}
		testing.expect_value(t, profile.icon, icon)
		testing.expect(t, !profile_file_lacks(f.path, "profile.alpha.icon"))
		testing.expect(t, !e.error, e.message)
		testing.expect_value(t, ui.editor_row(e).key, "profile.alpha.icon")
		testing.expect_value(t, ui.editor_row(e).value, icon)
		testing.expect_value(t, ui.field_string(&e.value), icon)
		loaded := app.shell_icon_find(&f.state, "alpha")
		if testing.expect(t, loaded != nil, "the chosen PNG is the profile's icon") {
			testing.expect_value(t, loaded.path, icon)
		}

		// A cancel from the icon's own folder keeps it.
		if !icon_browse(t, &f, "profile.alpha.icon", "") {return}
		testing.expect_value(t, icon_browse_last(&f).directory, filepath.dir(icon))
		testing.expect_value(t, settings.profile_find(&f.state.settings.profiles, "alpha").icon, icon)
		testing.expect(t, app.shell_icon_find(&f.state, "alpha") != nil)
		testing.expect_value(t, len(f.state.platform.record.file_picks), 3)
	}

	// A link program's Icon takes a chosen PNG the same way, and a cancel leaves it.
	@(test)
	icon_browse_chooses_a_link_program_icon :: proc(t: ^testing.T) {
		f: Profile_Fixture
		defer profile_fixture_destroy(t, &f)
		if !profile_fixture_create(t, &f, "icon-browse-opener", "") {return}
		icon := strings.concatenate({f.directory, `\nvim.png`}, context.temp_allocator)
		if !testing.expect_value(t, os.write_entire_file(icon, png_icon[:]), nil) {return}
		defer os.remove(icon)
		w := f.state.windows[0]
		e := profile_open(&f)
		if !testing.expect(t, ui.editor_select_key(e, "openers.add")) {return}
		app.editor_outcome(&f.state, w, .Save)
		testing.expect_value(t, e.opener_expanded, "program-1")

		if !icon_browse(t, &f, "opener.program-1.icon", icon) {return}
		opener := settings.opener_find(&f.state.settings.openers, "program-1")
		if !testing.expect(t, opener != nil) {return}
		testing.expect_value(t, opener.icon, icon)
		testing.expect(t, !e.error, e.message)
		testing.expect_value(t, ui.field_string(&e.value), icon)

		if !icon_browse(t, &f, "opener.program-1.icon", "") {return}
		testing.expect_value(t, icon_browse_last(&f).directory, filepath.dir(icon))
		testing.expect_value(t, settings.opener_find(&f.state.settings.openers, "program-1").icon, icon)
	}

	// Program icon files take one entry per chosen PNG, named for its file: a new name is added and a
	// name already listed has its PNG replaced in place. The dialog starts in the last entry's folder.
	@(test)
	icon_browse_adds_program_icon_files_entries :: proc(t: ^testing.T) {
		f: Profile_Fixture
		defer profile_fixture_destroy(t, &f)
		if !profile_fixture_create(t, &f, "icon-browse-programs", `tabs.program_icon_files = codex=icons\codex.png` + "\n") {
			return
		}
		nvim := strings.concatenate({f.directory, `\nvim.png`}, context.temp_allocator)
		codex := strings.concatenate({f.directory, `\Codex.png`}, context.temp_allocator)
		_ = profile_open(&f)

		if !icon_browse(t, &f, settings.PROGRAM_ICON_FILES_KEY, nvim) {return}
		testing.expect_value(t, icon_browse_last(&f).directory, strings.concatenate({f.directory, `\icons`}, context.temp_allocator))
		testing.expect_value(t, f.state.settings.tabs.program_icon_files, strings.concatenate({`codex=icons\codex.png; nvim=`, nvim}, context.temp_allocator))
		path, found := settings.program_icon_file(&f.state.settings, "nvim")
		testing.expect(t, found)
		testing.expect_value(t, path, nvim)

		if !icon_browse(t, &f, settings.PROGRAM_ICON_FILES_KEY, codex) {return}
		testing.expect_value(t, icon_browse_last(&f).directory, f.directory)
		testing.expect_value(
			t,
			f.state.settings.tabs.program_icon_files,
			strings.concatenate({`Codex=`, codex, `; nvim=`, nvim}, context.temp_allocator),
		)

		before := f.state.settings.tabs.program_icon_files
		before = strings.clone(before, context.temp_allocator)
		if !icon_browse(t, &f, settings.PROGRAM_ICON_FILES_KEY, "") {return}
		testing.expect_value(t, f.state.settings.tabs.program_icon_files, before)
	}
}
