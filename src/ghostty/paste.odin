package ghostty

when ODIN_OS == .Windows {
	foreign import lib {"../../vendor/ghostty/ghostty-vt-static.lib", "system:ntdll.lib"}
}

Paste_Source :: enum i32 {
	Clipboard = 0,
	Text      = 1,
}

Paste :: struct {
	size:         uint,
	location:     Clipboard_Location,
	source:       Paste_Source,
	mimes:        ^String,
	mimes_len:    uint,
	reader:       Mime_Reader,
	allow_unsafe: bool,
}

@(default_calling_convention = "c", link_prefix = "ghostty_")
foreign lib {
	@(require_results)
	terminal_paste :: proc(terminal: Terminal, paste: ^Paste, out_written: ^bool) -> Result ---
	@(require_results)
	paste_is_safe :: proc(data: [^]u8, len: uint) -> bool ---
	@(require_results)
	paste_encode :: proc(data: [^]u8, data_len: uint, bracketed: bool, buf: [^]u8, buf_len: uint, out_written: ^uint) -> Result ---
}
