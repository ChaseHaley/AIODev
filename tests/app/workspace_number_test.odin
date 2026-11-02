package app_test

import "base:runtime"
import "core:testing"
import "core:strings"
import "core:math/rand"
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
	testing.expect_value(t, app.rename_target_commit(&state, nil,
		{app.Rename_Kind.Workspace, workspace.id}, name), app.Rename_Outcome.Saved)
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
workspace_creation_prompt_selects_suggestion_and_cancels_without_mutation :: proc(t: ^testing.T) {
	state: app.App
	w: app.Window
	append(&state.windows, &w)
	defer delete(state.windows)
	defer delete(w.rename.bytes)
	app.workspace_new(&state, &w, false)
	testing.expect(t, w.rename_open && w.rename_mode == .New_Workspace)
	testing.expect(t, ui.field_string(&w.rename) != "")
	testing.expect_value(t, ui.field_selected_text(&w.rename), ui.field_string(&w.rename))
	testing.expect_value(t, len(state.workspaces), 0)
	testing.expect_value(t, len(state.sessions), 0)
	app.rename_key(&state, &w, {key = .Escape, pressed = true})
	testing.expect(t, !w.rename_open)
	testing.expect_value(t, state.next_workspace_id, u32(0))
	app.workspace_new(&state, &w, true)
	testing.expect(t, w.rename_open && w.rename_mode == .New_Window)
	_ = ui.field_text(&w.rename, "  ")
	app.rename_key(&state, &w, {key = .Enter, pressed = true})
	testing.expect(t, w.rename_open)
	testing.expect_value(t, len(state.workspaces), 0)
	app.rename_finish(&state, &w, false)
}

@(test)
workspace_creation_rechecks_name_claimed_while_prompt_is_open :: proc(t: ^testing.T) {
	state: app.App
	w: app.Window
	append(&state.windows, &w)
	defer delete(state.windows)
	defer delete(w.rename.bytes)
	ui.notices_init(&state.notices)
	defer ui.notices_destroy(&state.notices)
	app.workspace_new(&state, &w, false)
	name, err := strings.clone(ui.field_string(&w.rename))
	if !testing.expect_value(t, err, nil) {return}
	workspace := new(app.Workspace)
	workspace.name = name
	append(&state.workspaces, workspace)
	defer app.workspace_destroy(workspace)
	defer delete(state.workspaces)
	app.rename_finish(&state, &w, true)
	testing.expect(t, w.rename_open)
	testing.expect_value(t, len(state.workspaces), 1)
	testing.expect_value(t, len(state.sessions), 0)
	app.rename_finish(&state, &w, false)
}
