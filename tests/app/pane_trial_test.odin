package app_test

import "base:runtime"
import "core:testing"
import app "../../src"
import "aio:layout"
import "aio:ui"

@(private="file")
trial_clone :: proc(tree: ^layout.Layout) -> layout.Layout {
	copy_tree := tree^
	copy_tree.nodes = make([dynamic]layout.Node, len(tree.nodes))
	copy(copy_tree.nodes[:], tree.nodes[:])
	return copy_tree
}

@(private="file")
trial_unchanged :: proc(t: ^testing.T, tree, snapshot: ^layout.Layout) {
	testing.expect_value(t, tree.root, snapshot.root)
	testing.expect_value(t, tree.focus, snapshot.focus)
	testing.expect_value(t, tree.zoomed, snapshot.zoomed)
	testing.expect_value(t, tree.next_pane_order, snapshot.next_pane_order)
	if testing.expect_value(t, len(tree.nodes), len(snapshot.nodes)) {
		for node, i in tree.nodes {testing.expect_value(t, node, snapshot.nodes[i])}
	}
}

@(private="file")
trial_committed_rect :: proc(t: ^testing.T, state: ^app.App, w: ^app.Window,
	tree: ^layout.Layout, node: layout.Node_Id) -> layout.Rect {
	rects := make([dynamic]layout.Pane_Rect)
	defer delete(rects)
	layout.compute(tree, app.window_content_area(state, w), app.window_gap(state, w), &rects, false)
	for pane in rects {if pane.node == node {return pane.rect}}
	testing.expect(t, false)
	return {}
}

@(test)
pane_trial_split_is_detached_and_matches_committed_geometry :: proc(t: ^testing.T) {
	for scale in ([?]f32{1, 1.5, 1.75}) {
		for gap in ([?]int{0, 5, 24}) {
			for zoomed in ([?]bool{false, true}) {
				for direction in layout.Direction {
					for ratio in ([?]f32{0.05, 0.3, 0.5, 0.95}) {
						tree: layout.Layout
						if !testing.expect_value(t, layout.init(&tree, {.Terminal, 1}), nil) {return}
						defer layout.destroy(&tree)
						right, _ := layout.split_direction(&tree, 0, .Right, 0.6, {.Terminal, 2})
						tree.focus, tree.zoomed = right, zoomed
						snapshot := trial_clone(&tree)
						defer layout.destroy(&snapshot)
						workspace: app.Workspace
						state := app.App{next_session_id = 2}
						state.settings.pane.gap = gap
						w := app.Window{tree = &tree, workspace = &workspace, scale = scale,
							width = i32(1000*scale), height = i32(650*scale)}
						result := app.pane_trial_split(&state, &w, direction, ratio, context.allocator)
						testing.expect_value(t, result.error, app.Pane_Trial_Error.None)
						trial_unchanged(t, &tree, &snapshot)
						added, err := layout.split_direction(&snapshot, right, direction, ratio, {.Terminal, 3})
						testing.expect_value(t, err, nil)
						testing.expect_value(t, result.rect, trial_committed_rect(t, &state, &w, &snapshot, added))
					}
				}
			}
		}
	}
}

@(test)
pane_trial_move_dock_and_transfer_preserve_inputs_and_match_commit :: proc(t: ^testing.T) {
	for mode in 0 ..< 4 {
		for direction in layout.Direction {
			for scale in ([?]f32{1, 1.5, 1.75}) {
				for zoomed in ([?]bool{false, true}) {
					source, destination: layout.Layout
					testing.expect_value(t, layout.init(&source, {.Terminal, 1}), nil)
					defer layout.destroy(&source)
					right, _ := layout.split_direction(&source, 0, .Right, 0.5, {.Terminal, 2})
					_, _ = layout.split_direction(&source, right, .Down, 0.4, {.Terminal, 3})
					testing.expect_value(t, layout.init(&destination, {.Terminal, 4}), nil)
					defer layout.destroy(&destination)
					_, _ = layout.split_direction(&destination, 0, .Down, 0.7, {.Terminal, 5})
					source.focus, source.zoomed = right, zoomed
					destination.zoomed = zoomed
					before_source, before_destination := trial_clone(&source), trial_clone(&destination)
					defer layout.destroy(&before_source)
					defer layout.destroy(&before_destination)
					workspace: app.Workspace
					state: app.App
					state.settings.pane.gap = 5
					w := app.Window{workspace = &workspace, scale = scale,
						width = i32(1000*scale), height = i32(650*scale)}
					dest := mode < 2 ? &source : &destination
					result := app.pane_trial_move(&state, &w, &source, dest, right, 0,
						direction, mode%2 == 1, context.allocator)
					testing.expect_value(t, result.error, app.Pane_Trial_Error.None)
					trial_unchanged(t, &source, &before_source)
					trial_unchanged(t, &destination, &before_destination)
					added := layout.INVALID_NODE
					moved := false
					committed := &before_source
					switch mode {
					case 0: added, moved = layout.move_pane(committed, right, 0, direction)
					case 1: added, moved = layout.dock_pane(committed, right, direction)
					case 2, 3:
						committed = &before_destination
						added, moved = layout.transfer_pane(&before_source, committed, right, 0, direction, mode == 3)
					}
					testing.expect(t, moved)
					testing.expect_value(t, result.rect, trial_committed_rect(t, &state, &w, committed, added))
					retained := result.rect
					state.settings.pane.gap = 24
					_ = app.pane_trial_move(&state, &w, &source, dest, right, 0,
						direction, mode%2 == 1, context.allocator)
					testing.expect_value(t, result.rect, retained)
				}
			}
		}
	}
}

@(test)
pane_trial_minimum_keeps_unchanged_exemption_and_process_header_dpi_policy :: proc(t: ^testing.T) {
	for scale in ([?]f32{1, 1.5, 1.75}) {
		state := app.App{next_session_id = 2}
		ui.notices_init(&state.notices)
		defer ui.notices_destroy(&state.notices)
		state.settings.window.padding = 8
		state.settings.pane.minimum_columns = 40
		state.settings.pane.show_headers = true
		state.sessions = make([dynamic]app.Session_Entry)
		defer delete(state.sessions)
		append(&state.sessions, app.Session_Entry{id = 2})
		tree: layout.Layout
		testing.expect_value(t, layout.init(&tree, {.Terminal, 1}), nil)
		defer layout.destroy(&tree)
		right, _ := layout.split_direction(&tree, 0, .Right, 0.9, {.Terminal, 2})
		tree.focus, tree.zoomed = right, true
		workspace: app.Workspace
		w := app.Window{tree = &tree, workspace = &workspace, scale = scale,
			width = i32(1000*scale), height = i32(650*scale),
			metrics = {cell_width = 10*scale, cell_height = 20*scale}}
		snapshot := trial_clone(&tree)
		defer layout.destroy(&snapshot)
		// The narrow left pane is already below 40 columns and does not shrink.
		result := app.pane_trial_split(&state, &w, .Down, 0.5, context.allocator)
		testing.expect_value(t, result.error, app.Pane_Trial_Error.None)
		state.sessions[0].process_padding = 260
		testing.expect_value(t, app.pane_trial_split(&state, &w, .Down, 0.5,
			context.allocator).error, app.Pane_Trial_Error.Minimum)
		state.sessions[0].process_padding = 0
		state.settings.pane.minimum_columns = 0
		state.settings.pane.minimum_rows = 14
		// A half-height pane fits 14 rows until its header and padding are reserved.
		testing.expect_value(t, app.pane_trial_split(&state, &w, .Down, 0.5,
			context.allocator).error, app.Pane_Trial_Error.Minimum)
		state.settings.pane.show_headers = false
		testing.expect_value(t, app.pane_trial_split(&state, &w, .Down, 0.5,
			context.allocator).error, app.Pane_Trial_Error.None)
		state.settings.window.padding = 80
		testing.expect_value(t, app.pane_trial_split(&state, &w, .Down, 0.5,
			context.allocator).error, app.Pane_Trial_Error.Minimum)
		state.settings.pane.minimum_rows = 0
		testing.expect_value(t, app.pane_trial_split(&state, &w, .Down, 0.5,
			context.allocator).error, app.Pane_Trial_Error.None)
		trial_unchanged(t, &tree, &snapshot)
	}
}

@(test)
pane_trial_move_minimum_and_invalid_operations_are_detached :: proc(t: ^testing.T) {
	state: app.App
	state.settings.pane.minimum_columns = 1000
	state.settings.pane.minimum_rows = 1000
	source, destination: layout.Layout
	testing.expect_value(t, layout.init(&source, {.Terminal, 1}), nil)
	defer layout.destroy(&source)
	_, _ = layout.split_direction(&source, 0, .Right, 0.5, {.Terminal, 2})
	testing.expect_value(t, layout.init(&destination, {.Terminal, 3}), nil)
	defer layout.destroy(&destination)
	before_source, before_destination := trial_clone(&source), trial_clone(&destination)
	defer layout.destroy(&before_source)
	defer layout.destroy(&before_destination)
	workspace: app.Workspace
	w := app.Window{tree = &source, workspace = &workspace, scale = 1, width = 1000, height = 650,
		metrics = {cell_width = 10, cell_height = 20}}
	for root in ([?]bool{false, true}) {
		testing.expect_value(t, app.pane_trial_move(&state, &w, &source, &source, 0, 1,
			.Down, root, context.allocator).error, app.Pane_Trial_Error.Minimum)
		testing.expect_value(t, app.pane_trial_move(&state, &w, &source, &destination, 0, 0,
			.Down, root, context.allocator).error, app.Pane_Trial_Error.Minimum)
	}
	testing.expect_value(t, app.pane_trial_move(&state, &w, &source, &source, 0, 0,
		.Right, false, context.allocator).error, app.Pane_Trial_Error.Invalid)
	testing.expect_value(t, app.pane_trial_move(&state, &w, &source, &destination, layout.INVALID_NODE, 0,
		.Right, true, context.allocator).error, app.Pane_Trial_Error.Invalid)
	trial_unchanged(t, &source, &before_source)
	trial_unchanged(t, &destination, &before_destination)
	settings_tree: layout.Layout
	testing.expect_value(t, layout.init(&settings_tree, {.Settings, 0}), nil)
	defer layout.destroy(&settings_tree)
	// A terminal may join a settings tab; the 1000-cell minimum still refuses the trial.
	testing.expect_value(t, app.pane_trial_move(&state, &w, &source, &settings_tree, 0, 0,
		.Right, false, context.allocator).error, app.Pane_Trial_Error.Minimum)
}

@(private="file")
Trial_Fail_Allocator :: struct {
	backing:   runtime.Allocator,
	remaining: int,
}

@(private="file")
trial_fail_allocation :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int,
	old_memory: rawptr, old_size: int, location := #caller_location) -> ([]u8, runtime.Allocator_Error) {
	f := cast(^Trial_Fail_Allocator)data
	if mode == .Alloc || mode == .Alloc_Non_Zeroed || mode == .Resize || mode == .Resize_Non_Zeroed {
		if f.remaining == 0 {return nil, .Out_Of_Memory}
		f.remaining -= 1
	}
	return f.backing.procedure(f.backing.data, mode, size, alignment, old_memory, old_size, location)
}

@(test)
pane_trial_allocation_failures_leave_inputs_and_return_no_geometry :: proc(t: ^testing.T) {
	state: app.App
	source, destination: layout.Layout
	testing.expect_value(t, layout.init(&source, {.Terminal, 1}), nil)
	defer layout.destroy(&source)
	_, _ = layout.split_direction(&source, 0, .Right, 0.5, {.Terminal, 2})
	testing.expect_value(t, layout.init(&destination, {.Terminal, 3}), nil)
	defer layout.destroy(&destination)
	source.zoomed, destination.zoomed = true, true
	before_source, before_destination := trial_clone(&source), trial_clone(&destination)
	defer layout.destroy(&before_source)
	defer layout.destroy(&before_destination)
	workspace: app.Workspace
	w := app.Window{tree = &source, workspace = &workspace, scale = 1, width = 1000, height = 650}
	for mode in 0 ..< 4 {
		allocations := mode == 3 ? 4 : 3
		for allowed in 0 ..= allocations {
			failure := Trial_Fail_Allocator{context.allocator, allowed}
			allocator := runtime.Allocator{trial_fail_allocation, &failure}
			result: app.Pane_Trial_Result
			switch mode {
			case 0: result = app.pane_trial_split(&state, &w, .Right, 0.5, allocator)
			case 1, 2: result = app.pane_trial_move(&state, &w, &source, &source, 0, 1, .Down, mode == 2, allocator)
			case 3: result = app.pane_trial_move(&state, &w, &source, &destination, 0, 0, .Down, true, allocator)
			}
			testing.expect_value(t, result.error, allowed == allocations ? app.Pane_Trial_Error.None : .Allocation)
			if allowed < allocations {testing.expect_value(t, result.rect, layout.Rect{})}
			trial_unchanged(t, &source, &before_source)
			trial_unchanged(t, &destination, &before_destination)
		}
	}
}
