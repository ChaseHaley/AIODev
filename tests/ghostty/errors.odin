package ghostty_test

import "core:testing"
import "aio:ghostty"

Allocation_Attempts :: struct {
	count: int,
}

deny_alloc :: proc "c" (ctx: rawptr, length: uint, alignment: u8, ret_addr: uintptr) -> rawptr {
	attempts := cast(^Allocation_Attempts)ctx
	attempts.count += 1
	return nil
}

deny_resize :: proc "c" (
	ctx, memory: rawptr,
	memory_len: uint,
	alignment: u8,
	new_len: uint,
	ret_addr: uintptr,
) -> bool {
	return false
}

deny_remap :: proc "c" (
	ctx, memory: rawptr,
	memory_len: uint,
	alignment: u8,
	new_len: uint,
	ret_addr: uintptr,
) -> rawptr {
	return nil
}

deny_free :: proc "c" (ctx, memory: rawptr, memory_len: uint, alignment: u8, ret_addr: uintptr) {
}

@(test)
allocation_failure :: proc(t: ^testing.T) {
	attempts: Allocation_Attempts
	vtable := ghostty.Allocator_Vtable{
		alloc = deny_alloc,
		resize = deny_resize,
		remap = deny_remap,
		free = deny_free,
	}
	allocator := ghostty.Allocator{ctx = &attempts, vtable = &vtable}
	terminal: ghostty.Terminal
	testing.expect_value(t, ghostty.terminal_new(&allocator, &terminal, 10, 3), ghostty.Result.Out_Of_Memory)
	defer ghostty.terminal_free(terminal)
	testing.expect(t, terminal == nil)
	state: ghostty.Render_State
	testing.expect_value(t, ghostty.render_state_new(&allocator, &state), ghostty.Result.Out_Of_Memory)
	defer ghostty.render_state_free(state)
	testing.expect(t, state == nil)
	event: ghostty.Key_Event
	testing.expect_value(t, ghostty.key_event_new(&allocator, &event), ghostty.Result.Out_Of_Memory)
	defer ghostty.key_event_free(event)
	testing.expect(t, event == nil)
	testing.expect(t, ghostty.alloc(&allocator, 32) == nil)
	testing.expect_value(t, attempts.count, 4)
}

@(test)
invalid_arguments_and_sized :: proc(t: ^testing.T) {
	terminal: ghostty.Terminal
	testing.expect_value(t, ghostty.terminal_new(nil, &terminal, 0, 3), INVALID)
	defer ghostty.terminal_free(terminal)
	testing.expect_value(t, ghostty.terminal_get(nil, .Cols, nil), INVALID)
	testing.expect_value(t, ghostty.render_state_update(nil, nil), INVALID)
	stop := ghostty.sized(ghostty.Terminal_Write_Stop)
	testing.expect_value(t, stop.size, uint(size_of(ghostty.Terminal_Write_Stop)))
	ref: ghostty.Grid_Ref
	testing.expect_value(t, ghostty.grid_ref_cell(&ref, nil), INVALID)
	// A zeroed style is the default style; render cells rely on it when a cell has no styling.
	zero: ghostty.Style
	testing.expect(t, ghostty.style_is_default(&zero))
	style: ghostty.Style
	ghostty.style_default(&style)
	testing.expect(t, ghostty.style_is_default(&style))
	style.flags.bold = true
	testing.expect(t, !ghostty.style_is_default(&style))
	ghostty.free(nil, nil, 0)
}

@(test)
parser_ground_and_multi_get :: proc(t: ^testing.T) {
	terminal: ghostty.Terminal
	if !testing.expect_value(t, ghostty.terminal_new(nil, &terminal, 10, 3), SUCCESS) {
		return
	}
	defer ghostty.terminal_free(terminal)
	write(terminal, "\x1b[")
	stop := ghostty.sized(ghostty.Terminal_Write_Stop)
	result := ghostty.terminal_vt_write_until(terminal, raw_data(string("2;")), 2, {.Ground}, &stop)
	testing.expect_value(t, result, NONE)
	testing.expect_value(t, stop.consumed, 2)
	result = ghostty.terminal_vt_write_until(terminal, raw_data(string("3Hxyz")), 5, {.Ground}, &stop)
	testing.expect_value(t, result, SUCCESS)
	testing.expect_value(t, stop.consumed, 2)
	testing.expect_value(t, stop.reached, ghostty.Terminal_Boundaries{.Ground})
	expect_cursor(t, terminal, 2, 1)
	result = ghostty.terminal_vt_write_until(terminal, raw_data(string("xyz")), 3, {.Ground}, &stop)
	testing.expect_value(t, result, SUCCESS)
	testing.expect_value(t, stop.consumed, 0)
	cols, rows: u16
	keys := [3]ghostty.Terminal_Data{.Cols, .Rows, .Invalid}
	values := [3]rawptr{&cols, &rows, nil}
	written: uint
	testing.expect_value(t, ghostty.terminal_get_multi(terminal, 2, &keys[0], &values[0], &written), SUCCESS)
	testing.expect_value(t, cols, 10)
	testing.expect_value(t, rows, 3)
	testing.expect_value(t, written, 2)
	testing.expect_value(t, ghostty.terminal_get_multi(terminal, 3, &keys[0], &values[0], &written), INVALID)
	testing.expect_value(t, written, 2)
}
