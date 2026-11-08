package app_test

import "base:runtime"
import "core:testing"
import "core:strings"
import "core:math/rand"
import "aio:platform"
import "aio:ui"
import app "../../src"

@(test)
workspace_phrases_are_unique_and_previews_remain_unnamed :: proc(t: ^testing.T) {
	state: app.App
	defer delete(state.workspaces)
	defer for len(state.workspaces) > 0 {
		testing.expect(t, app.workspace_discard_empty(&state, state.workspaces[len(state.workspaces)-1]))
	}
	for _ in 0 ..< 100 {
		workspace := app.workspace_create_empty(&state)
		if !testing.expect(t, workspace != nil) {return}
		testing.expect_value(t, strings.count(workspace.name, " "), 2)
		for other in state.workspaces {
			if other != workspace {testing.expect(t, !strings.equal_fold(workspace.name, other.name))}
		}
	}
	preview := app.workspace_create_empty(&state, true)
	if !testing.expect(t, preview != nil) {return}
	testing.expect_value(t, preview.name, "")
	testing.expect(t, app.workspace_discard_empty(&state, preview))
	// Rewind the generator to force a collision with a manually assigned name.
	rng := rand.create(42)
	context.random_generator = rand.default_random_generator(&rng)
	name := app.workspace_default_name(&state)
	defer delete(name)
	workspace := app.workspace_create_empty(&state)
	if !testing.expect(t, workspace != nil) {return}
	testing.expect_value(t, app.rename_target_commit(&state, app.Rename_Workspace_Target{workspace.id}, name,
		.Workspace_Row), app.Rename_Outcome.Saved)
	rng = rand.create(42)
	other := app.workspace_default_name(&state)
	defer delete(other)
	testing.expect(t, !strings.equal_fold(name, other))
}

@(test)
workspace_phrase_allocation_failure_preserves_identity :: proc(t: ^testing.T) {
	state := app.App{next_workspace_id = 7}
	defer delete(state.workspaces)
	allocator := context.allocator
	context.allocator = runtime.nil_allocator()
	name := app.workspace_default_name(&state)
	workspace := app.workspace_create_empty(&state)
	context.allocator = allocator
	testing.expect_value(t, name, "")
	testing.expect(t, workspace == nil)
	testing.expect_value(t, state.next_workspace_id, u32(7))
	state.next_workspace_id = max(u32)
	testing.expect(t, app.workspace_create_empty(&state) == nil)
}

@(test)
workspace_creation_starts_naming_in_the_chip_and_keeps_the_suggestion :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "chip-naming") {return}
	s, w := &f.state, f.state.windows[0]
	count := len(s.workspaces)
	app.workspace_new(s, w, false)
	testing.expect_value(t, len(s.workspaces), count + 1)
	testing.expect(t, app.chip_name_shown(w))
	suggestion := strings.clone(w.workspace.name, context.temp_allocator)
	testing.expect(t, suggestion != "")
	testing.expect_value(t, ui.field_selected_text(&w.rename), suggestion)
	// Escape and an empty field both keep the suggested name; neither undoes the creation.
	app.rename_key(s, w, {key = .Escape, pressed = true})
	testing.expect(t, !app.rename_shown(w))
	testing.expect_value(t, w.workspace.name, suggestion)
	testing.expect_value(t, len(s.workspaces), count + 1)
	app.workspace_name_begin(s, w)
	ui.field_set(&w.rename, "  ")
	app.rename_key(s, w, {key = .Enter, pressed = true})
	testing.expect(t, !app.rename_shown(w))
	testing.expect_value(t, w.workspace.name, suggestion)
	// A new window takes the field, and a launch opens one without asking for a name.
	app.workspace_new(s, w, true)
	second := s.windows[len(s.windows) - 1]
	testing.expect(t, second != w && app.rename_shown(second) && !app.rename_shown(w))
	app.rename_finish(s, second, false)
	windows := len(s.windows)
	app.workspace_new(s, nil, true, name_it = false)
	testing.expect_value(t, len(s.windows), windows + 1)
	testing.expect(t, !app.rename_shown(s.windows[len(s.windows) - 1]))
}

@(test)
workspace_chip_keeps_field_open_on_a_used_name_and_a_lost_focus_saves :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "chip-used-name") {return}
	s, w := &f.state, f.state.windows[0]
	first := strings.clone(w.workspace.name, context.temp_allocator)
	app.workspace_new(s, w, false)
	suggestion := strings.clone(w.workspace.name, context.temp_allocator)
	ui.field_set(&w.rename, first)
	app.rename_key(s, w, {key = .Enter, pressed = true})
	chip, shown := w.overlay.(app.Overlay_Chip_Name)
	testing.expect(t, shown && chip.error)
	testing.expect_value(t, w.workspace.name, suggestion)
	// The workspace's own name is not a conflict, in any letter case.
	ui.field_set(&w.rename, strings.to_upper(suggestion, context.temp_allocator))
	app.rename_finish(s, w, true)
	testing.expect(t, !app.rename_shown(w))
	app.workspace_name_begin(s, w)
	ui.field_set(&w.rename, "Typed then left")
	app.handle_event(s, platform.Focus_Event{w.id, false})
	testing.expect(t, !app.rename_shown(w))
	testing.expect_value(t, w.workspace.name, "Typed then left")
	// A used name cannot survive losing focus: the field closes on the name the workspace has.
	app.workspace_name_begin(s, w)
	ui.field_set(&w.rename, first)
	app.handle_event(s, platform.Focus_Event{w.id, false})
	testing.expect(t, !app.rename_shown(w))
	testing.expect_value(t, w.workspace.name, "Typed then left")
}

@(test)
every_new_window_opens_at_the_configured_size :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "default-window-size") {return}
	s, w := &f.state, f.state.windows[0]
	expected := app.initial_geometry(s)
	// A hidden workspace remembers the much larger window its session last filled.
	app.workspace_new(s, w, false)
	app.rename_finish(s, w, false)
	hidden := w.workspace
	app.window_resize(s, w, 2400, 1400)
	testing.expect(t, app.workspace_select(s, w, s.workspaces[0]))
	app.window_resize(s, w, 2300, 1300)
	testing.expect(t, app.window_open(s, hidden))
	opened := app.window_for_workspace(s, hidden)
	if !testing.expect(t, opened != nil) {return}
	testing.expect_value(t, u32(opened.width), expected.surface_width)
	testing.expect_value(t, u32(opened.height), expected.surface_height)
}

@(test)
workspace_name_taken_ignores_previews_and_the_edited_workspace :: proc(t: ^testing.T) {
	owner := app.Workspace{id = 7, name = "Build Tools"}
	preview := app.Workspace{id = 8, name = "Preview Name", provisional = true}
	state: app.App
	defer delete(state.workspaces)
	append(&state.workspaces, &owner, &preview)
	testing.expect(t, app.workspace_name_taken(&state, "build tools", 0))
	testing.expect(t, !app.workspace_name_taken(&state, "BUILD TOOLS", owner.id))
	testing.expect(t, !app.workspace_name_taken(&state, "preview name", 0))
	testing.expect(t, !app.workspace_name_taken(&state, "Unused Name", 0))
}
