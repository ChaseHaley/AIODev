package ghostty

when ODIN_OS == .Windows {
	foreign import lib {"../../vendor/ghostty/ghostty-vt-static.lib", "system:ntdll.lib"}
}

Focus_Event :: enum i32 {
	Gained = 0,
	Lost   = 1,
}

@(default_calling_convention = "c", link_prefix = "ghostty_")
foreign lib {
	@(require_results)
	focus_encode :: proc(event: Focus_Event, buf: [^]u8, buf_len: uint, out_written: ^uint) -> Result ---
}
