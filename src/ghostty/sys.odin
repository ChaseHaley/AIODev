package ghostty

when ODIN_OS == .Windows {
	foreign import lib {"../../vendor/ghostty/ghostty-vt-static.lib", "system:ntdll.lib"}
}

Sys_Image :: struct {
	width:    u32,
	height:   u32,
	data:     [^]u8,
	data_len: uint,
}

Sys_Decode_Png_Fn :: proc "c" (
	userdata: rawptr,
	allocator: ^Allocator,
	data: [^]u8,
	data_len: uint,
	out: ^Sys_Image,
) -> bool

Sys_Option :: enum i32 {
	Userdata      = 0,
	Decode_Png    = 1,
	Log           = 2,
	Random_Secure = 3,
}

@(default_calling_convention = "c", link_prefix = "ghostty_")
foreign lib {
	@(require_results)
	sys_set :: proc(option: Sys_Option, value: rawptr) -> Result ---
}
