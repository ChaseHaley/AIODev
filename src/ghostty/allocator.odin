package ghostty

when ODIN_OS == .Windows {
	foreign import lib {"../../vendor/ghostty/ghostty-vt-static.lib", "system:ntdll.lib"}
}

Allocator_Vtable :: struct {
	alloc:  proc "c" (ctx: rawptr, len: uint, alignment: u8, ret_addr: uintptr) -> rawptr,
	resize: proc "c" (
		ctx: rawptr,
		memory: rawptr,
		memory_len: uint,
		alignment: u8,
		new_len: uint,
		ret_addr: uintptr,
	) -> bool,
	remap:  proc "c" (
		ctx: rawptr,
		memory: rawptr,
		memory_len: uint,
		alignment: u8,
		new_len: uint,
		ret_addr: uintptr,
	) -> rawptr,
	free:   proc "c" (
		ctx: rawptr,
		memory: rawptr,
		memory_len: uint,
		alignment: u8,
		ret_addr: uintptr,
	),
}

Allocator :: struct {
	ctx:    rawptr,
	vtable: ^Allocator_Vtable,
}

@(default_calling_convention = "c", link_prefix = "ghostty_")
foreign lib {
	@(require_results)
	alloc :: proc(allocator: ^Allocator, len: uint) -> [^]u8 ---
	free :: proc(allocator: ^Allocator, ptr: [^]u8, len: uint) ---
}
