package ghostty

when ODIN_OS == .Windows {
	foreign import lib {"../../vendor/ghostty/ghostty-vt-static.lib", "system:ntdll.lib"}
}

Color_Scheme :: enum i32 {
	Light = 0,
	Dark  = 1,
}

@(default_calling_convention = "c", link_prefix = "ghostty_")
foreign lib {
	@(require_results)
	color_scheme_report_encode :: proc(scheme: Color_Scheme, buf: [^]u8, buf_len: uint, out_written: ^uint) -> Result ---
}

Device_Attributes_Primary :: struct {
	conformance_level: u16,
	features:          [64]u16,
	num_features:      uint,
}

Device_Attributes_Secondary :: struct {
	device_type:      u16,
	firmware_version: u16,
	rom_cartridge:    u16,
}

Device_Attributes_Tertiary :: struct {
	unit_id: u32,
}

Device_Attributes :: struct {
	primary:   Device_Attributes_Primary,
	secondary: Device_Attributes_Secondary,
	tertiary:  Device_Attributes_Tertiary,
}
