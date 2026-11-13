package app_test

import "core:testing"
import app "../../src"
import "aio:font"
import "aio:glyphs"
import "aio:layout"
import "aio:render"
import "aio:ui"

// A workspace whose tabs have ids 1..len(groups) and the groups `groups` gives them by id, each group it names
// existing unnamed in Red.
@(private = "file")
grouped_workspace :: proc(state: ^app.App, groups: []u32) -> ^app.Workspace {
	workspace := new(app.Workspace)
	workspace.id = 1
	append(&state.workspaces, workspace)
	for group, i in groups {
		tab := new(app.Tab)
		tab.id, tab.group = u32(i + 1), group
		_ = layout.init(&tab.tree, {.Terminal, u32(i + 1)})
		append(&workspace.tabs, tab)
		if group != 0 && app.tab_group_find(workspace, group) == nil {
			append(&workspace.groups, app.Tab_Group{id = group, color = 1})
			workspace.next_group_id = max(workspace.next_group_id, group)
		}
	}
	workspace.next_tab_id = u32(len(groups))
	return workspace
}

@(private = "file")
grouped_destroy :: proc(state: ^app.App) {
	for workspace in state.workspaces {
		for tab in workspace.tabs {
			layout.destroy(&tab.tree)
			free(tab)
		}
		for &group in workspace.groups {app.tab_group_destroy(&group)}
		delete(workspace.groups)
		delete(workspace.tabs)
		free(workspace)
	}
	delete(state.workspaces)
	delete(state.windows)
}

@(private = "file")
groups_of :: proc(workspace: ^app.Workspace) -> [8]u32 {
	out: [8]u32
	for tab, i in workspace.tabs {if i < len(out) {out[i] = tab.group}}
	return out
}

@(private = "file")
ids_of :: proc(workspace: ^app.Workspace) -> [8]u32 {
	out: [8]u32
	for tab, i in workspace.tabs {if i < len(out) {out[i] = tab.id}}
	return out
}

@(private = "file")
grouped_window :: proc(state: ^app.App, workspace: ^app.Workspace, horizontal: bool) -> ^app.Window {
	w := new(app.Window)
	w^ = {
		id              = 91,
		workspace       = workspace,
		width           = 1200,
		height          = 700,
		scale           = 1,
		rail_wide       = true,
		rail            = app.Rail_Docked{},
		tabs_horizontal = horizontal,
	}
	append(&state.windows, w)
	return w
}

@(private = "file")
grouped_window_destroy :: proc(w: ^app.Window) {
	app.tab_presentation_destroy(&w.presentation)
	free(w)
}

// The tabs settle in their places, as a frame with motion off leaves them.
@(private = "file")
grouped_settle :: proc(state: ^app.App, w: ^app.Window) {
	app.tab_presentation_fit(state, w)
	_ = app.tab_presentation_animate(state, w, {})
}

@(test)
tab_groups_tidy_keeps_each_group_adjacent_and_drops_empty_ones :: proc(t: ^testing.T) {
	state: app.App
	defer grouped_destroy(&state)
	// Ungrouped tabs between two tabs of group 1 join it; a tab naming no group has none.
	workspace := grouped_workspace(&state, {1, 0, 0, 1, 9})
	pop(&workspace.groups)
	app.tab_groups_tidy(workspace)
	testing.expect_value(t, groups_of(workspace), [8]u32{1, 1, 1, 1, 0, 0, 0, 0})

	// A group's tabs after its first run leave it, and a group left without tabs goes.
	other := grouped_workspace(&state, {1, 2, 1, 1})
	append(&other.groups, app.Tab_Group{id = 3, color = 2})
	app.tab_groups_tidy(other)
	testing.expect_value(t, groups_of(other), [8]u32{1, 2, 0, 0, 0, 0, 0, 0})
	testing.expect_value(t, len(other.groups), 2)
	testing.expect(t, app.tab_group_find(other, 3) == nil)
}

@(test)
tab_groups_settle_joins_between_members_and_keeps_whole_groups :: proc(t: ^testing.T) {
	state: app.App
	defer grouped_destroy(&state)
	// Landing between two tabs of a group joins it.
	between := grouped_workspace(&state, {1, 0, 1})
	moved := [1]^app.Tab{between.tabs[1]}
	app.tab_groups_settle(between, moved[:])
	testing.expect_value(t, groups_of(between), [8]u32{1, 1, 1, 0, 0, 0, 0, 0})

	// A tab that moved away from the rest of its group leaves it.
	away := grouped_workspace(&state, {1, 1, 0, 1})
	moved[0] = away.tabs[3]
	app.tab_groups_settle(away, moved[:])
	testing.expect_value(t, groups_of(away), [8]u32{1, 1, 0, 0, 0, 0, 0, 0})

	// At its group's edge, a moved tab leaves it: only landing between two of its tabs keeps it there.
	beside := grouped_workspace(&state, {0, 1, 1})
	moved[0] = beside.tabs[1]
	app.tab_groups_settle(beside, moved[:])
	testing.expect_value(t, groups_of(beside), [8]u32{0, 0, 1, 0, 0, 0, 0, 0})

	// A tab keeps its group only through an unbroken run to the neighbour sharing it.
	broken := grouped_workspace(&state, {1, 0, 1})
	tail := [2]^app.Tab{broken.tabs[1], broken.tabs[2]}
	app.tab_groups_settle(broken, tail[:])
	testing.expect_value(t, groups_of(broken), [8]u32{1, 0, 0, 0, 0, 0, 0, 0})

	// All of a group moves as a whole, wherever it lands outside another group.
	whole := grouped_workspace(&state, {0, 2, 2, 0})
	pair := [2]^app.Tab{whole.tabs[1], whole.tabs[2]}
	app.tab_groups_settle(whole, pair[:])
	testing.expect_value(t, groups_of(whole), [8]u32{0, 2, 2, 0, 0, 0, 0, 0})
}

@(test)
moving_a_tab_steps_over_group_edges_before_crossing_them :: proc(t: ^testing.T) {
	state: app.App
	defer grouped_destroy(&state)
	workspace := grouped_workspace(&state, {0, 1, 1, 0})
	w := grouped_window(&state, workspace, true)
	defer grouped_window_destroy(w)
	// An ungrouped tab beside a group joins it where it is, then moves within it.
	app.tab_move_step(&state, w, 3, -1)
	testing.expect_value(t, ids_of(workspace), [8]u32{1, 2, 3, 4, 0, 0, 0, 0})
	testing.expect_value(t, groups_of(workspace), [8]u32{0, 1, 1, 1, 0, 0, 0, 0})
	app.tab_move_step(&state, w, 3, -1)
	testing.expect_value(t, ids_of(workspace), [8]u32{1, 2, 4, 3, 0, 0, 0, 0})
	// A tab at its group's edge leaves the group where it is.
	app.tab_move_step(&state, w, 1, -1)
	testing.expect_value(t, ids_of(workspace), [8]u32{1, 2, 4, 3, 0, 0, 0, 0})
	testing.expect_value(t, groups_of(workspace), [8]u32{0, 0, 1, 1, 0, 0, 0, 0})
	// Past a folded group a tab moves in one step, staying ungrouped.
	app.tab_group_find(workspace, 1).folded = true
	app.tab_move_step(&state, w, 1, 1)
	testing.expect_value(t, ids_of(workspace), [8]u32{1, 4, 3, 2, 0, 0, 0, 0})
	testing.expect_value(t, groups_of(workspace), [8]u32{0, 1, 1, 0, 0, 0, 0, 0})
}

@(test)
a_tab_alone_in_its_group_moves_with_it_past_whole_groups :: proc(t: ^testing.T) {
	state: app.App
	defer grouped_destroy(&state)
	workspace := grouped_workspace(&state, {2, 1, 1, 0})
	w := grouped_window(&state, workspace, true)
	defer grouped_window_destroy(w)
	app.tab_move_step(&state, w, 0, 1)
	testing.expect_value(t, ids_of(workspace), [8]u32{2, 3, 1, 4, 0, 0, 0, 0})
	testing.expect_value(t, groups_of(workspace), [8]u32{1, 1, 2, 0, 0, 0, 0, 0})
	app.tab_move_step(&state, w, 2, 1)
	testing.expect_value(t, ids_of(workspace), [8]u32{2, 3, 4, 1, 0, 0, 0, 0})
	testing.expect_value(t, groups_of(workspace), [8]u32{1, 1, 0, 2, 0, 0, 0, 0})
}

@(test)
a_folded_group_hides_its_tabs_from_tab_cycling_until_one_is_shown :: proc(t: ^testing.T) {
	state: app.App
	defer grouped_destroy(&state)
	workspace := grouped_workspace(&state, {0, 1, 1, 0})
	app.tab_group_find(workspace, 1).folded = true
	testing.expect(t, !app.tab_shown(workspace, 1) && !app.tab_shown(workspace, 2))
	testing.expect_value(t, app.tab_shown_step(workspace, 0, 1), 3)
	testing.expect_value(t, app.tab_shown_step(workspace, 3, 1), 0)
	testing.expect_value(t, app.tab_shown_step(workspace, 0, -1), 3)
	// A close never leaves a folded tab shown: the nearest shown tab to the right comes first.
	testing.expect_value(t, app.tab_nearest_shown(workspace, 1), 3)
	testing.expect_value(t, app.tab_nearest_shown(workspace, 0, 1), 0)
	// Choosing a tab of a folded group, as Activity or the palette does, unfolds it.
	app.workspace_tab_choose(workspace, 2)
	testing.expect(t, !app.tab_group_find(workspace, 1).folded)
}

@(test)
folding_the_shown_group_shows_the_nearest_tab_outside_it :: proc(t: ^testing.T) {
	state: app.App
	defer grouped_destroy(&state)
	workspace := grouped_workspace(&state, {0, 1, 1, 0})
	// The rail needs no text to lay out a folded chip; the strip measures its count.
	w := grouped_window(&state, workspace, false)
	defer grouped_window_destroy(w)
	app.workspace_tab_choose(workspace, 2)
	testing.expect(t, app.tab_group_fold(&state, w, 1, true))
	testing.expect_value(t, workspace.selected, 3)
	testing.expect(t, app.tab_group_find(workspace, 1).folded)
	// With nothing else open, the group stays unfolded.
	alone := grouped_workspace(&state, {4, 4})
	only := grouped_window(&state, alone, false)
	defer grouped_window_destroy(only)
	app.workspace_tab_choose(alone, 0)
	testing.expect(t, !app.tab_group_fold(&state, only, 4, true))
	testing.expect(t, !app.tab_group_find(alone, 4).folded)
}

@(test)
whole_groups_keep_their_label_when_their_tabs_change_workspace :: proc(t: ^testing.T) {
	state: app.App
	defer grouped_destroy(&state)
	source := grouped_workspace(&state, {1, 1, 2, 2})
	destination := grouped_workspace(&state, {1})
	reserve(&destination.groups, len(destination.groups) + len(source.groups))
	ids := [3]u32{1, 2, 3}
	carried := app.tab_groups_carry(source, destination, ids[:])
	testing.expect_value(t, len(carried), 1)
	to := app.tab_group_carried(carried, 1)
	testing.expect(t, to != 0 && to != 1)
	testing.expect(t, app.tab_group_find(destination, to) != nil)
	testing.expect_value(t, app.tab_group_carried(carried, 2), 0)
	testing.expect(t, app.tab_group_find(source, 1) == nil && app.tab_group_find(source, 2) != nil)
}

@(test)
the_strip_puts_each_chip_before_its_tabs_and_folds_them_into_it :: proc(t: ^testing.T) {
	state: app.App
	defer grouped_destroy(&state)
	workspace := grouped_workspace(&state, {0, 1, 1, 0})
	w := grouped_window(&state, workspace, true)
	defer grouped_window_destroy(w)
	// A folded chip measures its count, so the strip needs real text.
	fonts, font_error := font.system_create()
	if !testing.expect_value(t, font_error, font.Error.None) {return}
	defer font.system_destroy(fonts)
	device, device_error := render.device_create(.Warp)
	if !testing.expect_value(t, device_error, render.Error.None) {return}
	defer render.device_destroy(device)
	cache: glyphs.Cache
	glyphs.init(&cache, fonts, device)
	defer glyphs.destroy(&cache)
	if !testing.expect(t, ui.text_init(&w.ui_text, fonts, &cache, 14)) {return}
	grouped_settle(&state, w)
	bar := app.window_tab_bar(&state, w)
	chip := ui.HEIGHT_COMPACT + 2 * ui.TAB_CHIP_MARGIN
	testing.expect_value(t, bar.end, bar.x + 4 * bar.tab_width + chip)
	second := app.window_tab_rect(&state, w, 1)
	testing.expect_value(t, second.x, bar.x + bar.tab_width + chip)
	middle := second.x - chip / 2
	testing.expect(t, app.window_tab_hit(&state, w, bar, middle, 20) == app.Tab_Chrome_Group{1})
	testing.expect(t, app.window_tab_hit(&state, w, bar, second.x + 2, 20) == app.Tab_Chrome_Tab{1})

	// Folded, the group's tabs take no room and no clicks; the chip stays, the tabs after it close up.
	app.tab_group_find(workspace, 1).folded = true
	grouped_settle(&state, w)
	bar = app.window_tab_bar(&state, w)
	last := app.window_tab_rect(&state, w, 3)
	testing.expect(t, last.x < bar.x + 2 * bar.tab_width + 2 * chip)
	testing.expect(t, app.window_tab_hit(&state, w, bar, last.x + 2, 20) == app.Tab_Chrome_Tab{3})
	folded := app.tab_layout(&state, w, true).runs[0]
	testing.expect(t, app.window_tab_hit(&state, w, bar, app.tab_chip_strip_rect(w, bar, folded).x + 2, 20) ==
		app.Tab_Chrome_Group{1})
}

@(test)
the_rail_gives_each_chip_the_row_above_its_tabs :: proc(t: ^testing.T) {
	state: app.App
	defer grouped_destroy(&state)
	workspace := grouped_workspace(&state, {0, 1, 1, 0})
	w := grouped_window(&state, workspace, false)
	defer grouped_window_destroy(w)
	grouped_settle(&state, w)
	testing.expect_value(t, app.rail_row_count(w), 5)
	first := app.rail_row_rect_for_tab(w, 0)
	second := app.rail_row_rect_for_tab(w, 1)
	testing.expect_value(t, second.y - first.y, 2 * first.height)
	chip := app.tab_chrome_hit(&state, w, first.x + 8, first.y + first.height * 1.5, .Left)
	testing.expect(t, chip.target == app.Tab_Chrome_Group{1})
	app.tab_group_find(workspace, 1).folded = true
	grouped_settle(&state, w)
	testing.expect_value(t, app.rail_row_count(w), 3)
	last := app.rail_row_rect_for_tab(w, 3)
	testing.expect_value(t, last.y - first.y, 2 * first.height)
}

@(test)
a_groups_tray_runs_from_its_chip_to_its_last_tab_and_goes_while_folded :: proc(t: ^testing.T) {
	state: app.App
	defer grouped_destroy(&state)
	state.theme.text = {1, 1, 1, 1}
	workspace := grouped_workspace(&state, {1, 1, 0, 2})
	w := grouped_window(&state, workspace, true)
	defer grouped_window_destroy(w)
	Expected :: struct {
		shown: bool,
		ends:  ui.Tray_Ends,
	}
	trays :: proc(state: ^app.App, w: ^app.Window) -> (out: [4]Expected) {
		for &tray, i in out {
			color, ends := app.tab_tray(state, w, i)
			tray = {color.a > 0, ends}
		}
		return
	}
	testing.expect_value(t, trays(&state, w), [4]Expected{{true, {}}, {true, {.End}}, {}, {true, {.End}}})
	app.tab_group_find(workspace, 1).folded = true
	testing.expect_value(t, trays(&state, w), [4]Expected{{}, {}, {}, {true, {.End}}})
}

@(test)
a_dragged_tab_passes_a_chip_as_a_tab_and_joins_the_group_just_after_it :: proc(t: ^testing.T) {
	state: app.App
	defer grouped_destroy(&state)
	workspace := grouped_workspace(&state, {0, 1, 1, 0})
	w := grouped_window(&state, workspace, false)
	defer grouped_window_destroy(w)
	grouped_settle(&state, w)
	row := app.rail_row_rect_for_tab(w, 0)
	// The pointer for a block starting `start` rows down the rail, holding the tab by its middle.
	at :: proc(row: render.Rect, start: f32) -> f32 {return row.y + (start + 0.5) * row.height}
	workspace.tabs[3].marked = true
	x := row.x + 20
	app.tab_press(&state, w, 3, x, app.rail_row_rect_for_tab(w, 3).y + row.height / 2, false)
	// Without the dragged tab the rail reads tab 1, the chip, tab 2, tab 3: 2.2 rows down the block has
	// passed the chip's middle but not tab 2's, so it is in the group, its gap below the chip.
	testing.expect(t, app.tab_drag_move(&state, w, x, at(row, 2.2)))
	testing.expect_value(t, ids_of(workspace), [8]u32{1, 4, 2, 3, 0, 0, 0, 0})
	testing.expect_value(t, app.tab_layout(nil, w, false).places[1].slot, 2)
	// Back above the chip's middle it is outside the group, its gap above the chip.
	testing.expect(t, app.tab_drag_move(&state, w, x, at(row, 1.4)))
	testing.expect_value(t, ids_of(workspace), [8]u32{1, 4, 2, 3, 0, 0, 0, 0})
	testing.expect_value(t, app.tab_layout(nil, w, false).places[1].slot, 1)
	testing.expect(t, app.tab_drag_move(&state, w, x, at(row, 2.2)))
	app.tab_drag_release(&state, w)
	testing.expect_value(t, groups_of(workspace), [8]u32{0, 1, 1, 1, 0, 0, 0, 0})
}

@(test)
a_dragged_chip_carries_its_group_past_a_tab_once_the_chip_passes_its_middle :: proc(t: ^testing.T) {
	state: app.App
	defer grouped_destroy(&state)
	workspace := grouped_workspace(&state, {0, 0, 1, 1})
	w := grouped_window(&state, workspace, false)
	defer grouped_window_destroy(w)
	grouped_settle(&state, w)
	chip := app.tab_group_chip_rect(&state, w, 1)
	x, y := chip.x + 20, chip.y + chip.height / 2
	app.tab_chip_press(&state, w, 1, x, y)
	// The chip's top 0.6 of a row up has passed the middle of the row of tab 2, but not of tab 1.
	testing.expect(t, app.tab_drag_move(&state, w, x, y - 0.4 * chip.height))
	testing.expect_value(t, ids_of(workspace), [8]u32{1, 2, 3, 4, 0, 0, 0, 0})
	testing.expect(t, app.tab_drag_move(&state, w, x, y - 0.7 * chip.height))
	testing.expect_value(t, ids_of(workspace), [8]u32{1, 3, 4, 2, 0, 0, 0, 0})
	app.tab_drag_release(&state, w)
	testing.expect_value(t, groups_of(workspace), [8]u32{0, 1, 1, 0, 0, 0, 0, 0})
}

@(test)
no_two_groups_share_both_a_name_and_a_colour :: proc(t: ^testing.T) {
	state: app.App
	defer grouped_destroy(&state)
	workspace := grouped_workspace(&state, {1, 0, 2, 0})
	app.tab_group_find(workspace, 2).color = 2
	w := grouped_window(&state, workspace, true)
	defer grouped_window_destroy(w)
	grouped_settle(&state, w)
	// Both groups are nameless, so group 2 cannot take group 1's colour until their names differ.
	testing.expect(t, !app.tab_group_color_set(&state, w, 2, 1))
	rename :: proc(state: ^app.App, id: u32, name: string) -> app.Rename_Outcome {
		return app.rename_target_commit(state, app.Rename_Group_Target{1, id}, name, .Automatic_Title)
	}
	testing.expect_value(t, rename(&state, 2, "Build"), app.Rename_Outcome.Saved)
	testing.expect(t, app.tab_group_color_set(&state, w, 2, 1))
	// Names compare exactly: a name differing only in case tells the groups apart.
	testing.expect_value(t, rename(&state, 1, "Build"), app.Rename_Outcome.Taken)
	testing.expect_value(t, app.tab_group_find(workspace, 1).name, "")
	testing.expect_value(t, rename(&state, 1, "build"), app.Rename_Outcome.Saved)
	// A new group of a taken name takes a colour free for it.
	created := app.tab_group_create(&state, w, 3, "Build")
	testing.expect(t, created != nil && created.color != 1)
}

@(test)
the_group_menu_and_the_tab_menu_offer_folding_colours_and_groups_to_join :: proc(t: ^testing.T) {
	f: Menu_Fixture
	defer menu_fixture_destroy(&f)
	if !menu_fixture_init(t, &f, 3) {return}
	defer delete(f.workspace.groups)
	w := &f.w
	append(&f.workspace.groups, app.Tab_Group{id = 1, color = 2})
	f.workspace.next_group_id = 1
	f.workspace.tabs[1].group, f.workspace.tabs[2].group = 1, 1

	app.tab_group_menu_open(&f.state, w, 1, 10, 20)
	labels := [?]string{"Rename group…", "Color", "", "Fold", "New tab in group", "Move group to workspace…", "",
		"Ungroup", "Close group"}
	if !testing.expect_value(t, len(w.tab_menu.items), len(labels)) {return}
	for label, i in labels {testing.expect_value(t, w.tab_menu.items[i].label, label)}
	testing.expect_value(t, app.tab_menu_target(w), 1)
	// Color lists the palette, the group's own checked; choosing one recolours the group.
	ui.menu_select(&w.tab_menu.menu, 1)
	app.tab_menu_choose(&f.state, w)
	testing.expect(t, app.tab_submenu_shown(w))
	testing.expect_value(t, len(w.tab_menu.submenu.items), len(app.WORKSPACE_ICON_COLORS) - 1)
	testing.expect(t, w.tab_menu.submenu.items[1].checked && !w.tab_menu.submenu.items[0].checked)
	menu_key(&f, {key = .Enter})
	testing.expect(t, !app.tab_menu_shown(w))
	testing.expect_value(t, app.tab_group_find(&f.workspace, 1).color, 1)
	// Fold runs as a command on the group; the shown tab is outside it, so it stays shown.
	app.tab_group_menu_open(&f.state, w, 1, 10, 20)
	ui.menu_select(&w.tab_menu.menu, 3)
	app.tab_menu_choose(&f.state, w)
	testing.expect(t, app.tab_group_find(&f.workspace, 1).folded)
	testing.expect_value(t, f.workspace.selected, 0)

	// The tab menu's "Add to group" lists "New group", then the groups the tab is not in.
	app.tab_menu_open(&f.state, w, 0, 10, 20)
	ui.menu_select(&w.tab_menu.menu, 3)
	app.tab_menu_choose(&f.state, w)
	if !testing.expect(t, app.tab_submenu_shown(w)) {return}
	sub := w.tab_menu.submenu.items
	if !testing.expect_value(t, len(sub), 3) {return}
	testing.expect(t, sub[0].label == "New group" && sub[1].separator && sub[2].label == "Unnamed group")
	menu_key(&f, {key = .Arrow_Down})
	menu_key(&f, {key = .Enter})
	testing.expect_value(t, ids_of(&f.workspace), [8]u32{2, 3, 1, 0, 0, 0, 0, 0})
	testing.expect_value(t, groups_of(&f.workspace), [8]u32{1, 1, 1, 0, 0, 0, 0, 0})
	// The shown tab joined a folded group, which unfolds to show it.
	testing.expect(t, !app.tab_group_find(&f.workspace, 1).folded)
}
