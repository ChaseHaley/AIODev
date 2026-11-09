package app_test

import "aio:input"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import app "../../src"
import "aio:layout"
import "aio:platform"
import "aio:ui"

@(private="file")
Move_Fixture :: struct {
	state: app.App,
	source, destination, observer: ^app.Window,
	node: layout.Node_Id,
}

@(private="file")
move_fixture_init :: proc(t: ^testing.T, f: ^Move_Fixture) -> bool {
	state := &f.state
	state.options.inactive = true
	state.app_id = fmt.aprintf("AIODev.Test.MoveCompletion.%d.%p", os.get_pid(), f)
	if !testing.expect_value(t, platform.init(&state.platform, state.app_id), platform.Init_Result.Primary) {
		return false
	}
	state.platform_ready = true
	ui.notices_init(&state.notices)
	for i in 0 ..< 3 {
		workspace := app.workspace_create_empty(state)
		if !testing.expect(t, workspace != nil) {return false}
		tab := new(app.Tab)
		if !testing.expect_value(t, layout.init(&tab.tree, {.Terminal, u32(i + 1)}), nil) {
			free(tab)
			return false
		}
		workspace.next_tab_id = 1
		tab.id = 1
		append(&workspace.tabs, tab)
		id, err := platform.window_create(&state.platform, {hidden = true, width = 640, height = 480})
		if !testing.expect_value(t, err, platform.Error.None) {return false}
		w := new(app.Window)
		w.id, w.workspace = id, workspace
		w.width, w.height, w.scale = 640, 480, 1
		append(&state.windows, w)
		switch i {
		case 0: f.source = w
		case 1: f.destination = w
		case 2: f.observer = w
		}
	}
	source_tree := app.window_tree(f.source)
	f.node = source_tree.root
	_, err := layout.split_direction(source_tree, f.node, .Right, 0.5, {.Terminal, 4})
	if !testing.expect_value(t, err, nil) {return false}
	source_tree.focus = f.node
	for w in state.windows {
		app.focus_init(w)
		w.cursor_blink = app.Cursor_Blink_On{}
		w.wheel_remainder = 0.5
		w.selection = app.Selection_Selecting{}
	}
	return true
}

@(private="file")
move_fixture_destroy :: proc(t: ^testing.T, f: ^Move_Fixture) {
	state := &f.state
	for len(state.windows) > 0 {app.window_close(state, state.windows[len(state.windows) - 1])}
	delete(state.windows)
	for workspace in state.workspaces {app.workspace_destroy(workspace)}
	delete(state.workspaces)
	ui.notices_destroy(&state.notices)
	if state.platform_ready {testing.expect_value(t, platform.destroy(&state.platform), platform.Error.None)}
	delete(state.app_id)
}

@(private="file")
move_expect_handoff :: proc(t: ^testing.T, f: ^Move_Fixture, prepared := false) {
	for w in ([?]^app.Window{f.source, f.destination}) {
		testing.expect(t, app.cursor_visible(w))
		borrowed := prepared && w == f.destination
		testing.expect_value(t, app.selection_active(w), borrowed)
		testing.expect_value(t, w.wheel_remainder, borrowed ? f32(0.5) : 0)
	}
	testing.expect(t, !app.cursor_visible(f.observer) && app.selection_active(f.observer))
	testing.expect_value(t, f.observer.wheel_remainder, f32(0.5))
}

@(test)
pane_move_completion_selects_titles_and_relayouts_all_destinations :: proc(t: ^testing.T) {
	for kind in 0 ..< 3 {
		f: Move_Fixture
		defer move_fixture_destroy(t, &f)
		if !move_fixture_init(t, &f) {return}
		state := &f.state
		source := app.selected_tab(f.source.workspace)
		destination := app.selected_tab(f.destination.workspace)
		source.title, _ = strings.clone("stale source")
		source.name, _ = strings.clone("remaining source")
		destination.title, _ = strings.clone("stale destination")
		destination.name, _ = strings.clone("destination")
		switch kind {
		case 0:
			if !testing.expect(t, app.pane_drop_commit(state, f.destination,
				app.Pane_Grab{source, f.node}, f.destination,
				app.Pane_Drop{tab = destination, place = .Beside,
					target = destination.tree.root, direction = .Right})) {return}
		case 1:
			if !testing.expect(t, app.pane_to_tab(state, f.destination, source, f.node)) {return}
			destination = app.selected_tab(f.destination.workspace)
		case 2:
			f.destination.phase, f.destination.workspace.provisional = .Preparing, true
			delete(f.destination.workspace.name)
			f.destination.workspace.name = ""
			destination.tree.nodes[destination.tree.root] = source.tree.nodes[f.node]
			app.focus_init(f.destination)
			if !testing.expect(t, app.pane_to_window(state, f.source, source, f.node, f.destination.id)) {
				return
			}
			testing.expect(t, f.destination.phase == .Shown && !f.destination.workspace.provisional)
			testing.expect(t, f.destination.workspace.name != "")
		}
		testing.expect_value(t, source.title, "remaining source")
		testing.expect_value(t, destination.title, kind == 1 ? "" : "destination")
		testing.expect(t, app.selected_tab(f.destination.workspace) == destination)
		shown := app.window_tree(f.destination)
		testing.expect(t, shown == &destination.tree && destination.marked)
		testing.expect_value(t, shown.nodes[shown.focus].(layout.Pane).content.id, u32(1))
		testing.expect_value(t, len(f.source.panes), 1)
		testing.expect_value(t, f.source.panes[0].content.id, u32(4))
		testing.expect_value(t, len(f.destination.panes), kind == 0 ? 2 : 1)
		testing.expect_value(t, len(state.windows), 3)
		move_expect_handoff(t, &f, kind == 2)
	}
}

@(private="file")
move_find_pane :: proc(
	tree: ^layout.Layout,
	content: layout.Content,
) -> (
	layout.Node_Id,
	bool,
) {
	for node, i in tree.nodes {
		if pane, ok := node.(layout.Pane); ok && pane.content == content {
			return layout.Node_Id(i), true
		}
	}
	return layout.INVALID_NODE, false
}

// Settings is content like any other: a terminal can join its tab, its pane can move into a
// terminal tab, and only the one-page-per-workspace rule remains.
@(test)
settings_content_moves_like_any_other_pane_and_stays_unique :: proc(t: ^testing.T) {
	f: Move_Fixture
	defer move_fixture_destroy(t, &f)
	if !move_fixture_init(t, &f) {return}
	state := &f.state
	source := app.selected_tab(f.source.workspace)
	destination := app.selected_tab(f.destination.workspace)
	layout.destroy(&destination.tree)
	if !testing.expect_value(t, layout.init(&destination.tree, {.Settings, 0}), nil) {return}

	if !testing.expect(t, app.pane_drop_commit(state, f.destination,
		app.Pane_Grab{source, f.node}, f.destination,
		app.Pane_Drop{tab = destination, place = .Beside,
			target = destination.tree.root, direction = .Right})) {return}
	settings_node, settings_found := move_find_pane(&destination.tree, {.Settings, 0})
	_, terminal_found := move_find_pane(&destination.tree, {.Terminal, 1})
	testing.expect(t, settings_found && terminal_found)
	// The arriving terminal has focus; settings follows the focused pane instead of the tab root.
	testing.expect(t, !app.settings_active(f.destination))
	app.pane_focus(state, f.destination, settings_node)
	testing.expect(t, app.settings_active(f.destination))

	if !testing.expect(t, app.pane_drop_commit(state, f.source,
		app.Pane_Grab{destination, settings_node}, f.source,
		app.Pane_Drop{tab = source, place = .Beside, target = source.tree.focus, direction = .Right})) {return}
	_, moved_to_source := move_find_pane(&source.tree, {.Settings, 0})
	_, left_destination := move_find_pane(&destination.tree, {.Settings, 0})
	testing.expect(t, moved_to_source && !left_destination)
	testing.expect(t, app.settings_active(f.source))

	observer := app.selected_tab(f.observer.workspace)
	layout.destroy(&observer.tree)
	if !testing.expect_value(t, layout.init(&observer.tree, {.Settings, 0}), nil) {return}
	source_settings, found := move_find_pane(&source.tree, {.Settings, 0})
	if !testing.expect(t, found) {return}
	source_root, observer_root := source.tree.root, observer.tree.root
	testing.expect(t, !app.pane_drop_commit(state, f.observer,
		app.Pane_Grab{source, source_settings}, f.observer,
		app.Pane_Drop{tab = observer, place = .Beside, target = observer.tree.root, direction = .Right}))
	testing.expect_value(t, source.tree.root, source_root)
	testing.expect_value(t, observer.tree.root, observer_root)
	testing.expect(t, !app.pane_to_tab(state, f.observer, source, source_settings))
	testing.expect_value(t, len(f.source.workspace.tabs), 1)
	testing.expect_value(t, len(f.observer.workspace.tabs), 1)
}


@(private="file")
Move_Failure :: struct {backing: runtime.Allocator, remaining: int, failed: bool}

@(private="file")
move_failure_allocator :: proc(
	data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	location: runtime.Source_Code_Location,
) -> ([]u8, runtime.Allocator_Error) {
	failure := cast(^Move_Failure)data
	if !failure.failed && size > 0 &&
	   (mode == .Alloc || mode == .Alloc_Non_Zeroed || mode == .Resize || mode == .Resize_Non_Zeroed) {
		if failure.remaining == 0 {failure.failed = true; return nil, .Out_Of_Memory}
		failure.remaining -= 1
	}
	return failure.backing.procedure(failure.backing.data, mode, size, alignment, old_memory, old_size, location)
}

@(test)
pane_move_completion_allocation_failure_restores_departed_focus :: proc(t: ^testing.T) {
	for to_tab in ([?]bool{false, true}) {
		f: Move_Fixture
		defer move_fixture_destroy(t, &f)
		if !move_fixture_init(t, &f) {return}
		state := &f.state
		source := app.selected_tab(f.source.workspace)
		destination := app.selected_tab(f.destination.workspace)
		failure := Move_Failure{backing = context.allocator, remaining = to_tab ? 1 : 0}
		allocator := runtime.Allocator{move_failure_allocator, &failure}
		root, focus := source.tree.root, source.tree.focus
		moved := false
		if to_tab {
			if !testing.expect_value(t, reserve(&f.destination.workspace.tabs, 2), nil) {return}
			context.allocator = allocator
			moved = app.pane_to_tab(state, f.destination, source, f.node)
			context.allocator = failure.backing
		} else {
			for len(destination.tree.nodes) + 2 <= cap(destination.tree.nodes) {
				append(&destination.tree.nodes, layout.Vacant{})
			}
			destination.tree.nodes.allocator = allocator
			moved = app.pane_drop_commit(state, f.destination, app.Pane_Grab{source, f.node}, f.destination,
				app.Pane_Drop{tab = destination, place = .Beside,
					target = destination.tree.root, direction = .Right})
			destination.tree.nodes.allocator = failure.backing
		}
		testing.expect(t, failure.failed && !moved)
		testing.expect_value(t, source.tree.root, root)
		testing.expect_value(t, source.tree.focus, focus)
		testing.expect_value(t, len(f.destination.workspace.tabs), 1)
		testing.expect_value(t, len(state.workspaces), 3)
		testing.expect_value(t, destination.tree.nodes[destination.tree.root].(layout.Pane).content.id, u32(2))
		move_expect_handoff(t, &f)
	}
}

@(test)
pane_move_completion_preserves_unrelated_selected_source_tab :: proc(t: ^testing.T) {
	f: Move_Fixture
	defer move_fixture_destroy(t, &f)
	if !move_fixture_init(t, &f) {return}
	state := &f.state
	source := app.selected_tab(f.source.workspace)
	destination := app.selected_tab(f.destination.workspace)
	other := new(app.Tab)
	if !testing.expect_value(t, layout.init(&other.tree, {.Terminal, 5}), nil) {free(other); return}
	f.source.workspace.next_tab_id += 1
	other.id = f.source.workspace.next_tab_id
	append(&f.source.workspace.tabs, other)
	f.source.workspace.selected = 1
	f.source.overlay = app.Overlay_Tab_Menu{tab = other.id}
	if !testing.expect(t, app.pane_drop_commit(state, f.destination,
		app.Pane_Grab{source, f.node}, f.destination,
		app.Pane_Drop{tab = destination, place = .Beside,
			target = destination.tree.root, direction = .Right})) {return}
	testing.expect(t, app.selected_tab(f.source.workspace) == other)
	testing.expect(t, app.window_tree(f.source) == &other.tree)
	testing.expect(t, app.tab_menu_shown(f.source) && app.selection_active(f.source) && !app.cursor_visible(f.source))
	testing.expect_value(t, f.source.wheel_remainder, f32(0.5))
	testing.expect_value(t, source.tree.nodes[source.tree.focus].(layout.Pane).content.id, u32(4))
	testing.expect_value(t, len(f.source.panes), 1)
	testing.expect_value(t, f.source.panes[0].content.id, u32(5))
}

@(test)
pane_drag_dropdown_cancel_gap_scroll_and_last_pane_guard :: proc(t: ^testing.T) {
	f: Move_Fixture
	defer move_fixture_destroy(t, &f)
	if !move_fixture_init(t, &f) {return}
	state, w := &f.state, f.source
	w.height = 260
	for _ in 0 ..< 12 {if !testing.expect(t, app.workspace_create_empty(state) != nil) {return}}
	seed_pane_drag(w, app.selected_tab(w.workspace), f.node)
	chip := app.workspace_button_rect(state, w)
	testing.expect(t, app.pane_workspace_drag_move(state, w, w, chip.x + 4, chip.y + 4, false))
	testing.expect(t, app.pane_workspace_drag_move(state, w, w, chip.x + 4, 37, false))
	held, _ := app.pane_drag_destination(w).(app.Drop_Workspace_Dropdown)
	testing.expect_value(t, held.row, -1)
	testing.expect(t, app.drag_wheel(state, w, -1))
	testing.expect_value(t, w.workspace_picker.scroll, 1)
	app.handle_event(state, input.Key_Event{window = w.id, key = .Escape, pressed = true})
	testing.expect(t, !app.drag_held(w) && !app.workspace_picker_active(&w.workspace_picker))
	testing.expect_value(t, app.tab_pane_count(app.selected_tab(w.workspace)), 2)
	other := f.destination
	seed_pane_drag(other, app.selected_tab(other.workspace), app.window_tree(other).root)
	chip = app.workspace_button_rect(state, other)
	testing.expect(t, app.pane_workspace_drag_move(state, other, other, chip.x + 4, chip.y + 4, false))
	row := app.workspace_picker_row_rect(other, len(other.workspace_picker.rows) + 1)
	other.workspace_picker.scroll = len(other.workspace_picker.rows)
	row = app.workspace_picker_row_rect(other, len(other.workspace_picker.rows) + 1)
	testing.expect(t, app.pane_workspace_drag_move(state, other, other, row.x + 4, row.y + 4, false))
	held, _ = app.pane_drag_destination(other).(app.Drop_Workspace_Dropdown)
	testing.expect_value(t, held.row, -1)
	app.pane_drag_cancel(state, other)
	testing.expect_value(t, len(state.windows), 3)
}

// When the tab a drag hovered is gone, cancelling still enters the pane of the tab it gives back.
@(test)
pane_drag_cancel_enters_the_destination_tab_it_restores_by_index :: proc(t: ^testing.T) {
	f: Move_Fixture
	defer move_fixture_destroy(t, &f)
	if !move_fixture_init(t, &f) {return}
	state, w, destination := &f.state, f.source, f.destination
	other := new(app.Tab)
	if !testing.expect_value(t, layout.init(&other.tree, {.Terminal, 5}), nil) {
		free(other)
		return
	}
	other.id = 2
	append(&destination.workspace.tabs, other)
	app.tab_select(state, destination, 1, .Preserve_Marks)
	if !testing.expect(t, focus_holds_shown(destination)) {return}
	w.drag = app.Drag_Active {
		carry = app.Pane_Carry {
			grab = {app.selected_tab(w.workspace), f.node},
			visit = {window = destination.id, original_index = 0},
		},
	}
	app.pane_drag_cancel(state, w)
	testing.expect_value(t, destination.workspace.selected, 0)
	testing.expect(t, focus_holds_shown(destination))
}
