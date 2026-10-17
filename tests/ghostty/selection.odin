package ghostty_test

import "core:testing"
import "aio:ghostty"

expect_selection_text :: proc(
	t: ^testing.T,
	terminal: ghostty.Terminal,
	selection: ^ghostty.Selection,
	expected: string,
) {
	options := ghostty.sized(ghostty.Terminal_Selection_Format_Options)
	options.selection = selection
	options.trim = true
	options.unwrap = true
	n: uint
	testing.expect_value(t, ghostty.terminal_selection_format_buf(terminal, options, nil, 0, &n), SPACE)
	testing.expect_value(t, n, uint(len(expected)))
	buffer: [256]u8
	result := ghostty.terminal_selection_format_buf(terminal, options, raw_data(buffer[:]), len(buffer), &n)
	testing.expect_value(t, result, SUCCESS)
	testing.expect_value(t, string(buffer[:n]), expected)
	allocated: [^]u8
	result = ghostty.terminal_selection_format_alloc(terminal, nil, options, &allocated, &n)
	if testing.expect_value(t, result, SUCCESS) {
		defer ghostty.free(nil, allocated, n)
		testing.expect_value(t, string(allocated[:n]), expected)
	}
}

@(test)
selection_ranges :: proc(t: ^testing.T) {
	terminal: ghostty.Terminal
	if !testing.expect_value(t, ghostty.terminal_new(nil, &terminal, 20, 3), SUCCESS) {
		return
	}
	defer ghostty.terminal_free(terminal)
	write(terminal, "hello world\r\nsecond line")
	ref := ghostty.sized(ghostty.Grid_Ref)
	testing.expect_value(t, ghostty.terminal_grid_ref(terminal, point(2, 0), &ref), SUCCESS)
	options := ghostty.sized(ghostty.Terminal_Select_Word_Options)
	options.ref = ref
	selection := ghostty.sized(ghostty.Selection)
	testing.expect_value(t, ghostty.terminal_select_word(terminal, &options, &selection), SUCCESS)
	expect_selection_text(t, terminal, &selection, "hello")
	contains: bool
	result := ghostty.terminal_selection_contains(terminal, &selection, point(0, 0), &contains)
	testing.expect_value(t, result, SUCCESS)
	testing.expect(t, contains)
	result = ghostty.terminal_selection_contains(terminal, &selection, point(5, 0), &contains)
	testing.expect_value(t, result, SUCCESS)
	testing.expect(t, !contains)
	order: ghostty.Selection_Order
	testing.expect_value(t, ghostty.terminal_selection_order(terminal, &selection, &order), SUCCESS)
	testing.expect_value(t, order, ghostty.Selection_Order.Forward)
	reversed := ghostty.sized(ghostty.Selection)
	result = ghostty.terminal_selection_ordered(terminal, &selection, .Reverse, &reversed)
	testing.expect_value(t, result, SUCCESS)
	testing.expect_value(t, ghostty.terminal_selection_order(terminal, &reversed, &order), SUCCESS)
	testing.expect_value(t, order, ghostty.Selection_Order.Reverse)
	expect_selection_text(t, terminal, &reversed, "hello")
	equal: bool
	testing.expect_value(t, ghostty.terminal_selection_equal(terminal, &selection, &reversed, &equal), SUCCESS)
	testing.expect(t, !equal)
	testing.expect_value(t, ghostty.terminal_selection_equal(terminal, &selection, &selection, &equal), SUCCESS)
	testing.expect(t, equal)
	line := ghostty.sized(ghostty.Terminal_Select_Line_Options)
	line.ref = ref
	testing.expect_value(t, ghostty.terminal_select_line(terminal, &line, &selection), SUCCESS)
	expect_selection_text(t, terminal, &selection, "hello world")
	testing.expect_value(t, ghostty.terminal_select_all(terminal, &selection), SUCCESS)
	expect_selection_text(t, terminal, &selection, "hello world\nsecond line")
	options.boundary_codepoints_len = 1
	testing.expect_value(t, ghostty.terminal_select_word(terminal, &options, &selection), INVALID)
}

@(test)
selection_gestures :: proc(t: ^testing.T) {
	terminal: ghostty.Terminal
	if !testing.expect_value(t, ghostty.terminal_new(nil, &terminal, 20, 3), SUCCESS) {
		return
	}
	defer ghostty.terminal_free(terminal)
	write(terminal, "hello world")
	gesture: ghostty.Selection_Gesture
	if !testing.expect_value(t, ghostty.selection_gesture_new(nil, &gesture), SUCCESS) {
		return
	}
	defer ghostty.selection_gesture_free(gesture, terminal)
	press, drag, release: ghostty.Selection_Gesture_Event
	if !testing.expect_value(t, ghostty.selection_gesture_event_new(nil, &press, .Press), SUCCESS) {
		return
	}
	defer ghostty.selection_gesture_event_free(press)
	if !testing.expect_value(t, ghostty.selection_gesture_event_new(nil, &drag, .Drag), SUCCESS) {
		return
	}
	defer ghostty.selection_gesture_event_free(drag)
	if !testing.expect_value(t, ghostty.selection_gesture_event_new(nil, &release, .Release), SUCCESS) {
		return
	}
	defer ghostty.selection_gesture_event_free(release)
	selection := ghostty.sized(ghostty.Selection)
	testing.expect_value(t, ghostty.selection_gesture_event(gesture, terminal, press, &selection), INVALID)
	ref := ghostty.sized(ghostty.Grid_Ref)
	testing.expect_value(t, ghostty.terminal_grid_ref(terminal, point(0, 0), &ref), SUCCESS)
	testing.expect_value(t, ghostty.selection_gesture_event_set(press, .Ref, &ref), SUCCESS)
	testing.expect_value(t, ghostty.selection_gesture_event(gesture, terminal, press, &selection), NONE)
	count: u32
	testing.expect_value(t, ghostty.selection_gesture_get(gesture, terminal, .Click_Count, &count), SUCCESS)
	testing.expect_value(t, count, 1)
	testing.expect_value(t, ghostty.terminal_grid_ref(terminal, point(5, 0), &ref), SUCCESS)
	testing.expect_value(t, ghostty.selection_gesture_event_set(drag, .Ref, &ref), SUCCESS)
	geometry := ghostty.Selection_Gesture_Geometry{columns = 20, cell_width = 10, screen_height = 60}
	testing.expect_value(t, ghostty.selection_gesture_event_set(drag, .Geometry, &geometry), SUCCESS)
	testing.expect_value(t, ghostty.selection_gesture_event(gesture, terminal, drag, &selection), SUCCESS)
	expect_selection_text(t, terminal, &selection, "hello")
	testing.expect_value(t, ghostty.selection_gesture_event(gesture, terminal, release, &selection), NONE)
	ghostty.selection_gesture_reset(gesture, terminal)
	anchor := ghostty.sized(ghostty.Grid_Ref)
	testing.expect_value(t, ghostty.selection_gesture_get(gesture, terminal, .Anchor, &anchor), NONE)
}
