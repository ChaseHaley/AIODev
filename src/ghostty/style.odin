package ghostty

when ODIN_OS == .Windows {
	foreign import lib {"../../vendor/ghostty/ghostty-vt-static.lib", "system:ntdll.lib"}
}

Style_Id :: u16

// GhosttyStyleColor stores its tag in a uint8_t, so the enum is byte-sized here.
Style_Color_Tag :: enum u8 {
	None    = 0,
	Palette = 1,
	Rgb     = 2,
}

Style_Color_Value :: struct #raw_union {
	palette: Color_Palette_Index,
	rgb:     Color_Rgb,
}

Style_Color :: struct {
	tag:   Style_Color_Tag,
	value: Style_Color_Value,
}

// GhosttyStyleFlags: one bit per GHOSTTY_STYLE_FLAG_* attribute, then the Sgr_Underline style in
// bits 8 to 10. The underline is a raw field because a signed enum would sign-extend the bits.
Style_Flags :: bit_field u16 {
	bold:          bool | 1,
	italic:        bool | 1,
	faint:         bool | 1,
	blink:         bool | 1,
	inverse:       bool | 1,
	invisible:     bool | 1,
	strikethrough: bool | 1,
	overline:      bool | 1,
	underline:     u8   | 3,
}

Style :: struct {
	fg_color:        Style_Color,
	bg_color:        Style_Color,
	underline_color: Style_Color,
	flags:           Style_Flags,
	reserved:        u16,
}

@(default_calling_convention = "c", link_prefix = "ghostty_")
foreign lib {
	style_default :: proc(style: ^Style) ---
	@(require_results)
	style_is_default :: proc(style: ^Style) -> bool ---
}
