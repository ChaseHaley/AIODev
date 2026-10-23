package app_test

import "base:runtime"
import "core:fmt"
import "core:testing"
import app "../../src"

@(test)
workspace_number_preview_cancel_keeps_committed_sequence :: proc(t: ^testing.T) {
	state: app.App
	defer delete(state.workspaces)
	defer for len(state.workspaces) > 0 {
		testing.expect(t, app.workspace_discard_empty(&state, state.workspaces[len(state.workspaces)-1]))
	}
	for number: u32 = 1; number <= 4; number += 1 {
		workspace := app.workspace_create_empty(&state)
		if !testing.expect(t, workspace != nil) { return }
		testing.expect_value(t, workspace.name, fmt.tprintf("Workspace %d", number))
	}
	for id: u32 = 5; id <= 8; id += 1 {
		preview := app.workspace_create_empty(&state, true)
		if !testing.expect(t, preview != nil) { return }
		testing.expect_value(t, preview.id, id)
		testing.expect(t, app.workspace_index(&state, 4) == nil)
		testing.expect(t, app.workspace_discard_empty(&state, preview))
		testing.expect_value(t, state.next_workspace_id, id)
	}
	five := app.workspace_create_empty(&state)
	if !testing.expect(t, five != nil) { return }
	testing.expect_value(t, five.id, u32(9))
	testing.expect_value(t, five.name, "Workspace 5")
}

@(test)
workspace_number_manual_names_deletion_and_pending_previews :: proc(t: ^testing.T) {
	state: app.App
	defer delete(state.workspaces)
	defer for len(state.workspaces) > 0 {
		testing.expect(t, app.workspace_discard_empty(&state, state.workspaces[len(state.workspaces)-1]))
	}
	one := app.workspace_create_empty(&state)
	if !testing.expect(t, one != nil) { return }
	if !testing.expect(t, app.rename_target_commit(&state, nil,
		{app.Rename_Kind.Workspace, one.id}, "Workspace 2") == app.Rename_Outcome.Saved) { return }
	preview := app.workspace_create_empty(&state, true)
	if !testing.expect(t, preview != nil) { return }
	three := app.workspace_create_empty(&state)
	if !testing.expect(t, three != nil) { return }
	testing.expect_value(t, three.name, "Workspace 3")
	testing.expect_value(t, three.id, u32(3))
	testing.expect_value(t, one.name, "Workspace 2")
	name, number := app.workspace_default_name(&state)
	testing.expect_value(t, name, "Workspace 4")
	testing.expect_value(t, number, u32(4))
	delete(name)
	testing.expect_value(t, state.next_workspace_number, u32(3))
	testing.expect(t, app.workspace_discard_empty(&state, preview))
	testing.expect(t, app.rename_target_commit(&state, nil,
		{app.Rename_Kind.Workspace, one.id}, "Build tools") == app.Rename_Outcome.Saved)
	testing.expect(t, app.workspace_discard_empty(&state, three))
	four := app.workspace_create_empty(&state)
	if !testing.expect(t, four != nil) { return }
	testing.expect_value(t, four.id, u32(4))
	testing.expect_value(t, four.name, "Workspace 4")
	testing.expect_value(t, one.name, "Build tools")
}

@(test)
workspace_number_failure_and_exhaustion_preserve_counters :: proc(t: ^testing.T) {
	state := app.App{next_workspace_id = 7, next_workspace_number = 4}
	defer delete(state.workspaces)
	allocator := context.allocator
	context.allocator = runtime.nil_allocator()
	name, number := app.workspace_default_name(&state)
	context.allocator = allocator
	testing.expect_value(t, name, "")
	testing.expect_value(t, number, u32(0))
	testing.expect_value(t, state.next_workspace_id, u32(7))
	testing.expect_value(t, state.next_workspace_number, u32(4))
	state.next_workspace_number = max(u32)
	testing.expect(t, app.workspace_create_empty(&state) == nil)
	testing.expect_value(t, state.next_workspace_id, u32(7))
	preview := app.workspace_create_empty(&state, true)
	if !testing.expect(t, preview != nil) { return }
	testing.expect_value(t, preview.id, u32(8))
	testing.expect(t, app.workspace_discard_empty(&state, preview))
	state.next_workspace_number = 4
	state.next_workspace_id = max(u32)
	testing.expect(t, app.workspace_create_empty(&state, true) == nil)
	testing.expect(t, app.workspace_create_empty(&state) == nil)
	testing.expect_value(t, state.next_workspace_number, u32(4))
}
