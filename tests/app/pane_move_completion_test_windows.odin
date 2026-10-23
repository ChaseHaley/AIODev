package app_test

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
		w.id, w.workspace, w.tree = id, workspace, &tab.tree
		w.width, w.height, w.scale = 640, 480, 1
		append(&state.windows, w)
		switch i {
		case 0: f.source = w
		case 1: f.destination = w
		case 2: f.observer = w
		}
	}
	f.node = f.source.tree.root
	_, err := layout.split_direction(f.source.tree, f.node, .Right, 0.5, {.Terminal, 4})
	if !testing.expect_value(t, err, nil) {return false}
	f.source.tree.focus = f.node
	for w in state.windows {
		w.cursor_phase_visible = false
		w.wheel_remainder = 0.5
		w.selecting = true
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
		testing.expect(t, w.cursor_phase_visible)
		borrowed := prepared && w == f.destination
		testing.expect_value(t, w.selecting, borrowed)
		testing.expect_value(t, w.wheel_remainder, borrowed ? f32(0.5) : 0)
	}
	testing.expect(t, !f.observer.cursor_phase_visible && f.observer.selecting)
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
			if !testing.expect(t, app.pane_transfer(state, f.destination, source, destination,
				f.node, destination.tree.root, .Right, false)) {return}
		case 1:
			if !testing.expect(t, app.pane_to_tab(state, f.destination, source, f.node)) {return}
			destination = app.selected_tab(f.destination.workspace)
		case 2:
			f.destination.preparing, f.destination.workspace.provisional = true, true
			delete(f.destination.workspace.name)
			f.destination.workspace.name = ""
			destination.tree.nodes[destination.tree.root] = source.tree.nodes[f.node]
			if !testing.expect(t, app.pane_to_window(state, f.source, source, f.node, f.destination.id)) {
				return
			}
			testing.expect(t, !f.destination.preparing && !f.destination.workspace.provisional)
			testing.expect_value(t, f.destination.workspace.name, "Workspace 4")
		}
		testing.expect_value(t, source.title, "remaining source")
		testing.expect_value(t, destination.title, kind == 1 ? "" : "destination")
		testing.expect(t, app.selected_tab(f.destination.workspace) == destination)
		testing.expect(t, f.destination.tree == &destination.tree && destination.marked)
		testing.expect_value(t, f.destination.tree.nodes[f.destination.tree.focus].(layout.Pane).content.id, u32(1))
		testing.expect_value(t, len(f.source.panes), 1)
		testing.expect_value(t, f.source.panes[0].content.id, u32(4))
		testing.expect_value(t, len(f.destination.panes), kind == 0 ? 2 : 1)
		testing.expect_value(t, len(state.windows), 3)
		move_expect_handoff(t, &f, kind == 2)
	}
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
			moved = app.pane_transfer(state, f.destination, source, destination,
				f.node, destination.tree.root, .Right, false)
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
	f.source.workspace.selected, f.source.tree = 1, &other.tree
	f.source.tab_menu.open = true
	if !testing.expect(t, app.pane_transfer(state, f.destination, source, destination,
		f.node, destination.tree.root, .Right, false)) {return}
	testing.expect(t, app.selected_tab(f.source.workspace) == other && f.source.tree == &other.tree)
	testing.expect(t, f.source.tab_menu.open && f.source.selecting && !f.source.cursor_phase_visible)
	testing.expect_value(t, f.source.wheel_remainder, f32(0.5))
	testing.expect_value(t, source.tree.nodes[source.tree.focus].(layout.Pane).content.id, u32(4))
	testing.expect_value(t, len(f.source.panes), 1)
	testing.expect_value(t, f.source.panes[0].content.id, u32(5))
}
