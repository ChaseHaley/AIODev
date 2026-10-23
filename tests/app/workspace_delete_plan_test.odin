package app_test

import "core:testing"
import app "../../src"
import "aio:platform"

@(test)
workspace_delete_plan_derives_owner_destination_and_first_tab :: proc(t: ^testing.T) {
	state: app.App
	defer delete(state.workspaces)
	defer delete(state.windows)
	one: app.Workspace = {id = 1, name = "One"}
	two: app.Workspace = {id = 2, name = "Two"}
	three: app.Workspace = {id = 3, name = "Three"}
	defer delete(one.tabs)
	defer delete(two.tabs)
	defer delete(three.tabs)
	append(&state.workspaces, &one, &two, &three)
	owner: app.Window
	owner.id, owner.workspace = 7, &two
	append(&state.windows, &owner)

	// The first eligible workspace after the subject that nobody displays becomes the destination.
	plan := app.workspace_delete_plan(&state, &two)
	testing.expect_value(t, plan.workspace, u32(2))
	testing.expect_value(t, plan.owner, platform.Window_Id(7))
	testing.expect_value(t, plan.destination, u32(3))
	testing.expect(t, !plan.fresh)
	testing.expect(t, plan.created_tab)

	// An existing empty destination needs its first tab; one with a tab does not.
	first: app.Tab
	append(&three.tabs, &first)
	plan = app.workspace_delete_plan(&state, &two)
	testing.expect(t, !plan.fresh && !plan.created_tab)

	// Every alternative is displayed, so the owner gets a fresh workspace and its first tab.
	one_owner: app.Window
	one_owner.id, one_owner.workspace = 8, &one
	three_owner: app.Window
	three_owner.id, three_owner.workspace = 9, &three
	append(&state.windows, &one_owner, &three_owner)
	plan = app.workspace_delete_plan(&state, &two)
	testing.expect_value(t, plan.destination, u32(0))
	testing.expect(t, plan.fresh && plan.created_tab)
}

@(test)
workspace_delete_plan_replaces_only_an_owned_or_last_workspace :: proc(t: ^testing.T) {
	state: app.App
	defer delete(state.workspaces)
	defer delete(state.windows)
	one: app.Workspace = {id = 1, name = "One"}
	two: app.Workspace = {id = 2, name = "Two"}
	defer delete(one.tabs)
	defer delete(two.tabs)
	append(&state.workspaces, &one, &two)

	// A hidden workspace among others has nobody to replace and leaves no destination.
	plan := app.workspace_delete_plan(&state, &one)
	testing.expect_value(t, plan.workspace, u32(1))
	testing.expect_value(t, plan.owner, platform.Window_Id(0))
	testing.expect_value(t, plan.destination, u32(0))
	testing.expect(t, !plan.fresh && !plan.created_tab)

	// The last workspace still gets a fresh one, so the shared set never empties (D-053).
	ordered_remove(&state.workspaces, 1)
	plan = app.workspace_delete_plan(&state, &one)
	testing.expect(t, plan.fresh && plan.created_tab)

	// Without a subject there is no plan.
	plan = app.workspace_delete_plan(&state, nil)
	testing.expect_value(t, plan.workspace, u32(0))
	testing.expect(t, !plan.fresh && !plan.created_tab)
}

@(test)
workspace_delete_plan_skips_provisional_destinations_and_compares_identity :: proc(t: ^testing.T) {
	state: app.App
	defer delete(state.workspaces)
	defer delete(state.windows)
	one: app.Workspace = {id = 1, name = "One"}
	two: app.Workspace = {id = 2, name = "Two"}
	three: app.Workspace = {id = 3, name = "Three"}
	defer delete(one.tabs)
	defer delete(two.tabs)
	defer delete(three.tabs)
	append(&state.workspaces, &two, &one, &three)
	owner: app.Window
	owner.id, owner.workspace = 4, &two
	three_owner: app.Window
	three_owner.id, three_owner.workspace = 6, &three
	append(&state.windows, &owner, &three_owner)

	// A provisional workspace cannot receive the replacement; the displayed one may not either.
	one.provisional = true
	plan := app.workspace_delete_plan(&state, &two)
	testing.expect_value(t, plan.destination, u32(0))
	testing.expect(t, plan.fresh && plan.created_tab)

	// Once it is eligible it wins by list order, and its empty tab list needs a first tab.
	one.provisional = false
	plan = app.workspace_delete_plan(&state, &two)
	testing.expect_value(t, plan.destination, u32(1))
	recorded := plan

	// Adding a tab changes the first-tab need, not the identity the question recorded.
	tab: app.Tab
	append(&one.tabs, &tab)
	plan = app.workspace_delete_plan(&state, &two)
	testing.expect(t, app.workspace_delete_plan_same(plan, recorded))
	testing.expect(t, recorded.created_tab && !plan.created_tab)

	// Losing the owning window changes the identity, so the question must reopen.
	ordered_remove(&state.windows, 0)
	plan = app.workspace_delete_plan(&state, &two)
	testing.expect_value(t, plan.owner, platform.Window_Id(0))
	testing.expect(t, !app.workspace_delete_plan_same(plan, recorded))
}
