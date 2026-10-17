package ghostty

when ODIN_OS == .Windows {
	foreign import lib {"../../vendor/ghostty/ghostty-vt-static.lib", "system:ntdll.lib"}
}

Color_Rgb :: struct {
	r: u8,
	g: u8,
	b: u8,
}

Color_Palette_Index :: u8

@(default_calling_convention="c", link_prefix="ghostty_")
foreign lib {
	color_palette_default :: proc(out: ^Color_Rgb) ---
}
