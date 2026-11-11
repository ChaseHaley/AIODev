package ghostty

when ODIN_OS == .Windows {
	foreign import lib {"../../vendor/ghostty/ghostty-vt-static.lib", "system:ntdll.lib"}
}

Mouse_Encoder :: distinct rawptr

Mouse_Tracking_Mode :: enum i32 {
	None   = 0,
	X10    = 1,
	Normal = 2,
	Button = 3,
	Any    = 4,
}

Mouse_Format :: enum i32 {
	X10        = 0,
	Utf8       = 1,
	Sgr        = 2,
	Urxvt      = 3,
	Sgr_Pixels = 4,
}

Mouse_Encoder_Size :: struct {
	size:           uint,
	screen_width:   u32,
	screen_height:  u32,
	cell_width:     u32,
	cell_height:    u32,
	padding_top:    u32,
	padding_bottom: u32,
	padding_right:  u32,
	padding_left:   u32,
}

Mouse_Encoder_Option :: enum i32 {
	Invalid            = 0,
	Event              = 1,
	Format             = 2,
	Size               = 3,
	Any_Button_Pressed = 4,
	Track_Last_Cell    = 5,
}

@(default_calling_convention = "c", link_prefix = "ghostty_")
foreign lib {
	@(require_results)
	mouse_encoder_new :: proc(allocator: ^Allocator, encoder: ^Mouse_Encoder) -> Result ---
	mouse_encoder_free :: proc(encoder: Mouse_Encoder) ---
	@(require_results)
	mouse_encoder_set :: proc(encoder: Mouse_Encoder, option: Mouse_Encoder_Option, value: rawptr) -> Result ---
	@(require_results)
	mouse_encoder_set_from_terminal :: proc(encoder: Mouse_Encoder, terminal: Terminal) -> Result ---
	@(require_results)
	mouse_encoder_reset :: proc(encoder: Mouse_Encoder) -> Result ---
	@(require_results)
	mouse_encoder_encode :: proc(
		encoder: Mouse_Encoder,
		event: Mouse_Event,
		buf: [^]u8,
		buf_len: uint,
		out_written: ^uint,
	) -> Result ---
}
