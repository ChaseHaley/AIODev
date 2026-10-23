package app_test

import "core:testing"
import app "../../src"

@(test)
workspace167_eligibility_subsets_match_their_callers :: proc(t: ^testing.T) {
	state: app.App
	defer delete(state.workspaces)
	defer delete(state.windows)
	first := app.workspace_create_empty(&state)
	second := app.workspace_create_empty(&state)
	third := app.workspace_create_empty(&state)
	fourth := app.workspace_create_empty(&state)
	if !testing.expect(t, first != nil && second != nil && third != nil && fourth != nil) {return}
	defer {for workspace in state.workspaces {app.workspace_destroy(workspace)}}
	second.provisional = true
	preparing := app.Window{workspace = third, preparing = true}
	ready := app.Window{workspace = fourth}
	append(&state.windows, &preparing)
	append(&state.windows, &ready)
	stale := app.Workspace{id = first.id}

	testing.expect(t, !app.workspace_eligible(&state, nil))
	testing.expect(t, !app.workspace_eligible(&state, &stale))
	testing.expect(t, app.workspace_eligible(&state, first))
	testing.expect(t, !app.workspace_eligible(&state, second))
	testing.expect(t, !app.workspace_eligible(&state, third))
	testing.expect(t, app.workspace_eligible(&state, fourth))

	testing.expect(t, app.workspace_registered(&state, second))
	testing.expect(t, !app.workspace_registered(&state, &stale))

	testing.expect(t, app.workspace_row_target(&state, first.id) == first)
	testing.expect(t, app.workspace_row_target(&state, second.id) == nil)
	testing.expect(t, app.workspace_row_target(&state, third.id) == nil)
	testing.expect(t, app.workspace_row_target(&state, fourth.id) == fourth)
	testing.expect(t, app.workspace_row_target(&state, max(u32)) == nil)

	testing.expect(t, app.workspace_icon_set(&state, second, 2, "🌈"))
	testing.expect_value(t, second.icon.emoji, "🌈")
	testing.expect(t, app.workspace_icon_color_set(&state, second, 3))
	testing.expect_value(t, second.icon.tint, 3)
	testing.expect(t, !app.workspace_icon_set(&state, &stale, 2, "🌈"))

	testing.expect(t, !app.workspace_discard_empty(&state, fourth))
	testing.expect(t, app.workspace_discard_empty(&state, second))
}
