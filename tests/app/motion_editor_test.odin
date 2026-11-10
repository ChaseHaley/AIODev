package app_test

import app "../../src"
import "aio:settings"
import "aio:ui"
import "core:strings"
import "core:testing"

@(private)
motion_editor_open :: proc(t: ^testing.T, f: ^Profile_Fixture, name: string) -> ^ui.Editor {
	if !profile_fixture_create(t, f, name, PROFILE_FIXTURE_SETTINGS) {return nil}
	return profile_open(f)
}

@(private)
motion_editor_layout :: proc(p: ^ui.Editor) -> ui.Editor_Layout {
	l := ui.editor_layout({0, 40, 1200, 1400}, 1)
	ui.editor_fit(p, l)
	return l
}

@(private)
motion_editor_reset_shown :: proc(p: ^ui.Editor) -> bool {
	return ui.editor_row_parts(p, p.fit_layout, p.selected).reset.width > 0
}

@(private)
motion_editor_row :: proc(p: ^ui.Editor, key: string) -> ^ui.Editor_Row {
	for &row in p.rows {if row.key == key {return &row}}
	return nil
}

@(test)
motion_editor_rows_follow_the_context_tree :: proc(t: ^testing.T) {
	f: Profile_Fixture
	defer profile_fixture_destroy(t, &f)
	p := motion_editor_open(t, &f, "motion-rows")
	if !testing.expect(t, p != nil) {return}
	for key in ([]string{"motion.speed", ui.MOTION_PRESET_KEY, ui.MOTION_SAVE_PRESET_KEY}) {
		testing.expectf(t, profile_item(p, key) >= 0, "%s is listed", key)
	}
	// Contexts start collapsed, so only Panes shows; its children appear once it expands.
	keys := settings.MOTION_CONTEXT_KEY
	testing.expect(t, profile_item(p, keys[.Panes]) >= 0)
	testing.expect_value(t, profile_item(p, keys[.Split]), -1)
	if !testing.expect(t, ui.editor_select_key(p, keys[.Panes])) {return}
	profile_press(&f, {key = .Enter})
	for key in keys {testing.expectf(t, profile_item(p, key) >= 0, "header %s is listed", key)}
	// Enter on a child header shows its fields in order under it.
	testing.expect_value(t, profile_item(p, "motion.panes.split.duration"), -1)
	if !testing.expect(t, ui.editor_select_key(p, "motion.panes.split")) {return}
	profile_press(&f, {key = .Enter})
	previous := profile_item(p, "motion.panes.split")
	for field in ([]string{"on", "duration", "curve", "effect"}) {
		item := profile_item(p, strings.concatenate({"motion.panes.split.", field}, context.temp_allocator))
		testing.expectf(t, item > previous, "split %s follows the rows before it", field)
		previous = item
	}
	effect := motion_editor_row(p, "motion.panes.split.effect")
	if !testing.expect(t, effect != nil) {return}
	testing.expect_value(t, effect.value, "grow")
	testing.expect_value(t, len(effect.choices), 4)
	// Right expands and Left collapses; View has no effect.
	if !testing.expect(t, ui.editor_select_key(p, "motion.panes.view")) {return}
	profile_press(&f, {key = .Arrow_Right})
	testing.expect(t, profile_item(p, "motion.panes.view.duration") >= 0)
	testing.expect(t, profile_item(p, "motion.panes.view.curve") >= 0)
	testing.expect(t, motion_editor_row(p, "motion.panes.view.effect") == nil)
	profile_press(&f, {key = .Arrow_Left})
	testing.expect_value(t, profile_item(p, "motion.panes.view.duration"), -1)
	// Expansion survives a reload.
	p = profile_open(&f)
	testing.expect(t, profile_item(p, "motion.panes.split.duration") >= 0)
	testing.expect_value(t, profile_item(p, "motion.panes.view.duration"), -1)
	// Collapsing Panes hides its children and their fields, and expanding it brings them back as they were.
	if !testing.expect(t, ui.editor_select_key(p, keys[.Panes])) {return}
	profile_press(&f, {key = .Arrow_Left})
	testing.expect_value(t, profile_item(p, keys[.Split]), -1)
	testing.expect_value(t, profile_item(p, "motion.panes.split.duration"), -1)
	profile_press(&f, {key = .Arrow_Right})
	testing.expect(t, profile_item(p, "motion.panes.split.duration") >= 0)
}

@(test)
motion_editor_duration_saves_and_resets_one_context :: proc(t: ^testing.T) {
	f: Profile_Fixture
	defer profile_fixture_destroy(t, &f)
	p := motion_editor_open(t, &f, "motion-duration")
	if !testing.expect(t, p != nil) {return}
	w := f.state.windows[0]
	if !testing.expect(t, ui.editor_reveal(p, ui.Reveal_Row{"motion.panes.split.duration"})) {return}
	_ = motion_editor_layout(p)
	row := ui.editor_row(p)
	testing.expect(t, row.motion_inherited)
	testing.expect_value(t, row.value, "160")
	testing.expect_value(t, row.description, "From Panes.")
	testing.expect(t, !motion_editor_reset_shown(p))
	ui.editor_focus_row(p)
	ui.field_set(&p.value, "300")
	app.editor_outcome(&f.state, w, .Save)
	testing.expect(t, !p.error)
	testing.expect_value(t, f.state.settings.motion.contexts[.Split], "300ms")
	testing.expect_value(t, f.state.settings.motion.contexts[.Panes], "on 160ms decelerate")
	row = ui.editor_row(p)
	if !testing.expect_value(t, row.key, "motion.panes.split.duration") {return}
	testing.expect(t, !row.motion_inherited)
	testing.expect_value(t, row.value, "300")
	testing.expect(t, motion_editor_reset_shown(p))
	app.editor_outcome(&f.state, w, .Reset)
	testing.expect(t, !p.error)
	testing.expect_value(t, f.state.settings.motion.contexts[.Split], "")
	testing.expect(t, ui.editor_row(p).motion_inherited)
	testing.expect_value(t, ui.editor_row(p).value, "160")
}

@(test)
motion_editor_curve_drag_forks_a_builtin_and_assigns_it :: proc(t: ^testing.T) {
	f: Profile_Fixture
	defer profile_fixture_destroy(t, &f)
	p := motion_editor_open(t, &f, "motion-curve")
	if !testing.expect(t, p != nil) {return}
	w := f.state.windows[0]
	if !testing.expect(t, ui.editor_reveal(p, ui.Reveal_Row{"motion.panes.split.curve"})) {return}
	l := motion_editor_layout(p)
	testing.expect_value(t, ui.editor_row(p).value, "decelerate")
	field := ui.editor_row_parts(p, l, p.selected).field
	pressed := ui.editor_press(p, l, nil, field.x + field.width / 2, field.y + field.height / 2, false)
	testing.expect_value(t, pressed, ui.Editor_Outcome.Changed)
	if !testing.expect_value(t, ui.editor_popup(p), ui.Editor_Popup.Curve) {return}
	plot := ui.motion_curve_parts(ui.editor_popup_rect(p, l), false, 1).graph
	handle := ui.motion_plot_point(plot, 0.2, 0)
	testing.expect_value(t, ui.editor_press(p, l, nil, handle.x, handle.y, false), ui.Editor_Outcome.Changed)
	// Grabbing a handle changes nothing until it moves; the built-in keeps its name till then.
	testing.expect_value(t, p.motion_curve_name, "decelerate")
	testing.expect(t, ui.editor_drag(p, l, nil, handle.x + 20, handle.y - 30))
	testing.expect_value(t, p.motion_curve_name, "decelerate-2")
	change, problem := ui.editor_motion_change(p, false)
	testing.expect_value(t, problem, "")
	mutation, is_mutation := change.(settings.Motion_Mutation)
	set, is_set := mutation.(settings.Motion_Curve_Set)
	if !testing.expect(t, is_mutation && is_set) {return}
	testing.expect_value(t, set.name, "decelerate-2")
	assign, assigned := set.assign.?
	testing.expect(t, assigned && assign == .Split)
	app.editor_outcome(&f.state, w, ui.editor_release(p))
	testing.expect(t, !p.error)
	testing.expect_value(t, f.state.settings.motion.specs[.Split].curve, "decelerate-2")
	_, known := settings.motion_curve_find(&f.state.settings, "decelerate-2")
	testing.expect(t, known)
	// The popover stays open on the saved curve, with nothing left to save.
	testing.expect_value(t, ui.editor_popup(p), ui.Editor_Popup.Curve)
	testing.expect_value(t, ui.editor_row(p).value, "decelerate-2")
	testing.expect(t, !ui.editor_draft(p))
	// Escape closes it.
	profile_press(&f, {key = .Escape})
	testing.expect_value(t, ui.editor_popup(p), ui.Editor_Popup.None)
}

@(test)
motion_editor_presets_apply_save_and_delete :: proc(t: ^testing.T) {
	f: Profile_Fixture
	defer profile_fixture_destroy(t, &f)
	p := motion_editor_open(t, &f, "motion-presets")
	if !testing.expect(t, p != nil) {return}
	w := f.state.windows[0]
	if !testing.expect(t, ui.editor_reveal(p, ui.Reveal_Row{ui.MOTION_PRESET_KEY})) {return}
	ui.field_set(&p.value, "snappy")
	app.editor_outcome(&f.state, w, .Save)
	testing.expect(t, !p.error)
	testing.expect_value(t, f.state.settings.motion.contexts[.Panes], "on 110ms quick")
	testing.expect_value(t, ui.editor_row(p).value, "snappy")
	// Custom names no preset, so choosing it changes nothing.
	ui.field_set(&p.value, "")
	app.editor_outcome(&f.state, w, .Save)
	testing.expect_value(t, f.state.settings.motion.contexts[.Panes], "on 110ms quick")
	testing.expect_value(t, ui.field_string(&p.value), "snappy")

	if !testing.expect(t, ui.editor_reveal(p, ui.Reveal_Row{ui.MOTION_SAVE_PRESET_KEY})) {return}
	ui.editor_focus_row(p)
	ui.field_set(&p.value, "My Calm")
	change, problem := ui.editor_motion_change(p, false)
	testing.expect_value(t, problem, "")
	mutation, is_mutation := change.(settings.Motion_Mutation)
	save, is_save := mutation.(settings.Motion_Preset_Save)
	if !testing.expect(t, is_mutation && is_save) {return}
	testing.expect_value(t, save.name, "my-calm")
	app.editor_outcome(&f.state, w, .Save)
	testing.expect(t, !p.error)
	if !testing.expect_value(t, len(f.state.settings.motion.presets), 1) {return}
	testing.expect_value(t, f.state.settings.motion.presets[0].name, "my-calm")
	testing.expect_value(t, ui.editor_row(p).key, ui.MOTION_SAVE_PRESET_KEY)
	testing.expect_value(t, ui.field_string(&p.value), "")
	listed := false
	for row in p.rows {
		if row.key != ui.MOTION_PRESET_KEY {continue}
		for choice in row.choices {listed = listed || choice == "my-calm"}
	}
	testing.expect(t, listed)

	if !testing.expect(t, ui.editor_select_key(p, "motion.preset.my-calm")) {return}
	app.editor_outcome(&f.state, w, .Save)
	testing.expect(t, !p.error)
	testing.expect_value(t, len(f.state.settings.motion.presets), 0)
	testing.expect_value(t, profile_item(p, "motion.preset.my-calm"), -1)
}
