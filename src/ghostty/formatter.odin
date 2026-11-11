package ghostty

when ODIN_OS == .Windows {
	foreign import lib {"../../vendor/ghostty/ghostty-vt-static.lib", "system:ntdll.lib"}
}

Formatter_Extra :: enum u32 {
	Palette,
	Modes,
	Scrolling_Region,
	Tabstops,
	Pwd,
	Keyboard,
	Cursor,
	Style,
	Hyperlink,
	Protection,
	Kitty_Keyboard,
	Charsets,
}

Formatter_Extras :: bit_set[Formatter_Extra;u32]

FORMATTER_EXTRAS_DEFAULT :: Formatter_Extras{.Palette, .Style, .Hyperlink}

Formatter_Option :: enum i32 {
	Invalid   = 0,
	Emit      = 1,
	Unwrap    = 2,
	Trim      = 3,
	Selection = 4,
	Extras    = 5,
}

@(default_calling_convention = "c", link_prefix = "ghostty_")
foreign lib {
	@(require_results)
	formatter_terminal_new :: proc(allocator: ^Allocator, formatter: ^Formatter, terminal: Terminal) -> Result ---
	@(require_results)
	formatter_set :: proc(formatter: Formatter, option: Formatter_Option, value: rawptr) -> Result ---
	@(require_results)
	formatter_get :: proc(formatter: Formatter, option: Formatter_Option, out: rawptr) -> Result ---
	@(require_results)
	formatter_format :: proc(formatter: Formatter, writer: Writer) -> Result ---
	@(require_results)
	formatter_format_buf :: proc(formatter: Formatter, buf: [^]u8, buf_len: uint, out_written: ^uint) -> Result ---
	@(require_results)
	formatter_format_alloc :: proc(formatter: Formatter, allocator: ^Allocator, out_ptr: ^[^]u8, out_len: ^uint) -> Result ---
	formatter_free :: proc(formatter: Formatter) ---
}
