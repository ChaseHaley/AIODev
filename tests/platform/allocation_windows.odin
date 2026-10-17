package platform_test

import "base:runtime"
import p "aio:platform"
import "core:testing"

Fail_Allocator :: struct { backing: runtime.Allocator, remaining: int }
fail_allocation :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int,
	old_memory: rawptr, old_size: int, location := #caller_location) -> ([]u8, runtime.Allocator_Error) {
	state := cast(^Fail_Allocator)data
	if mode == .Alloc || mode == .Alloc_Non_Zeroed || mode == .Resize || mode == .Resize_Non_Zeroed {
		if state.remaining == 0 { return nil, .Out_Of_Memory }
		state.remaining -= 1
	}
	return state.backing.procedure(state.backing.data, mode, size, alignment, old_memory, old_size, location)
}

@(test)
allocation_failure_cleanup :: proc(t: ^testing.T) {
	for allowed in 0..<5 {
		state := Fail_Allocator{context.allocator, allowed}
		allocator := runtime.Allocator{fail_allocation, &state}
		platform: p.Platform
		testing.expect_value(t, p.init(&platform, "AIODev.Test.Allocation", allocator), p.Init_Result.Failed)
		testing.expect_value(t, p.destroy(&platform), p.Error.None)
	}
	state := Fail_Allocator{context.allocator, 5}
	allocator := runtime.Allocator{fail_allocation, &state}
	platform: p.Platform
	if !testing.expect_value(t, p.init(&platform, "AIODev.Test.Allocation", allocator), p.Init_Result.Primary) {
		return
	}
	defer testing.expect_value(t, p.destroy(&platform), p.Error.None)
	_, err := p.window_create(&platform, {hidden = true, width = 160, height = 100})
	testing.expect_value(t, err, p.Error.Out_Of_Memory)
	testing.expect(t, !p.clipboard_set_text(&platform, "x"))
	testing.expect_value(t, p.tray_set_menu(&platform, []p.Tray_Menu_Item{{id = 1}}), p.Error.Out_Of_Memory)
}
