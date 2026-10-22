package ghostty

when ODIN_OS == .Windows {
	foreign import lib {"../../vendor/ghostty/ghostty-vt-static.lib", "system:ntdll.lib"}
}

@(default_calling_convention = "c", link_prefix = "ghostty_")
foreign lib {
	// Width in cells (0, 1, or 2) from the table the terminal uses when mode 2027 is off.
	unicode_codepoint_width :: proc(cp: u32) -> u8 ---
	// Measures the first grapheme cluster with the terminal's mode 2027 rules; returns codepoints consumed.
	unicode_grapheme_width :: proc(cps: [^]u32, len: uint, width: ^u8) -> uint ---
}
