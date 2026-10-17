package ghostty

when ODIN_OS == .Windows {
	foreign import lib {"../../vendor/ghostty/ghostty-vt-static.lib", "system:ntdll.lib"}
}

Key_Encoder :: distinct rawptr

Kitty_Key_Flag :: enum u8 {
	Disambiguate,
	Report_Events,
	Report_Alternates,
	Report_All,
	Report_Associated,
}

Kitty_Key_Flags :: bit_set[Kitty_Key_Flag; u8]

Option_As_Alt :: enum i32 {
	False = 0,
	True = 1,
	Left = 2,
	Right = 3,
}

Key_Encoder_Option :: enum i32 {
	Cursor_Key_Application = 0,
	Keypad_Key_Application = 1,
	Ignore_Keypad_With_Numlock = 2,
	Alt_Esc_Prefix = 3,
	Modify_Other_Keys_State_2 = 4,
	Kitty_Flags = 5,
	Macos_Option_As_Alt = 6,
	Backarrow_Key_Mode = 7,
}

KITTY_KEY_ALL :: Kitty_Key_Flags{
	.Disambiguate,
	.Report_Events,
	.Report_Alternates,
	.Report_All,
	.Report_Associated,
}

@(default_calling_convention="c", link_prefix="ghostty_")
foreign lib {
	@(require_results)
	key_encoder_new :: proc(allocator: ^Allocator, encoder: ^Key_Encoder) -> Result ---
	key_encoder_free :: proc(encoder: Key_Encoder) ---
	key_encoder_setopt :: proc(encoder: Key_Encoder, option: Key_Encoder_Option, value: rawptr) ---
	key_encoder_setopt_from_terminal :: proc(encoder: Key_Encoder, terminal: Terminal) ---
	@(require_results)
	key_encoder_encode :: proc(
		encoder: Key_Encoder,
		event: Key_Event,
		out_buf: [^]u8,
		out_buf_size: uint,
		out_len: ^uint,
	) -> Result ---
}
