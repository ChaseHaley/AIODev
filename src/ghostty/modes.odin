package ghostty

when ODIN_OS == .Windows {
	foreign import lib {"../../vendor/ghostty/ghostty-vt-static.lib", "system:ntdll.lib"}
}

Mode :: u16

Mode_Report_State :: enum i32 {
	Not_Recognized    = 0,
	Set               = 1,
	Reset             = 2,
	Permanently_Set   = 3,
	Permanently_Reset = 4,
}

MODE_KAM :: Mode(32770)
MODE_INSERT :: Mode(32772)
MODE_SRM :: Mode(32780)
MODE_LINEFEED :: Mode(32788)
MODE_DECCKM :: Mode(1)
MODE_132_COLUMN :: Mode(3)
MODE_SLOW_SCROLL :: Mode(4)
MODE_REVERSE_COLORS :: Mode(5)
MODE_ORIGIN :: Mode(6)
MODE_WRAPAROUND :: Mode(7)
MODE_AUTOREPEAT :: Mode(8)
MODE_X10_MOUSE :: Mode(9)
MODE_CURSOR_BLINKING :: Mode(12)
MODE_CURSOR_VISIBLE :: Mode(25)
MODE_ENABLE_MODE_3 :: Mode(40)
MODE_REVERSE_WRAP :: Mode(45)
MODE_ALT_SCREEN_LEGACY :: Mode(47)
MODE_KEYPAD_KEYS :: Mode(66)
MODE_BACKARROW_KEY_MODE :: Mode(67)
MODE_LEFT_RIGHT_MARGIN :: Mode(69)
MODE_NORMAL_MOUSE :: Mode(1000)
MODE_BUTTON_MOUSE :: Mode(1002)
MODE_ANY_MOUSE :: Mode(1003)
MODE_FOCUS_EVENT :: Mode(1004)
MODE_UTF8_MOUSE :: Mode(1005)
MODE_SGR_MOUSE :: Mode(1006)
MODE_ALT_SCROLL :: Mode(1007)
MODE_URXVT_MOUSE :: Mode(1015)
MODE_SGR_PIXELS_MOUSE :: Mode(1016)
MODE_NUMLOCK_KEYPAD :: Mode(1035)
MODE_ALT_ESC_PREFIX :: Mode(1036)
MODE_ALT_SENDS_ESC :: Mode(1039)
MODE_REVERSE_WRAP_EXT :: Mode(1045)
MODE_ALT_SCREEN :: Mode(1047)
MODE_SAVE_CURSOR :: Mode(1048)
MODE_ALT_SCREEN_SAVE :: Mode(1049)
MODE_BRACKETED_PASTE :: Mode(2004)
MODE_SYNC_OUTPUT :: Mode(2026)
MODE_GRAPHEME_CLUSTER :: Mode(2027)
MODE_COLOR_SCHEME_REPORT :: Mode(2031)
MODE_VISIBILITY_REPORT :: Mode(2033)
MODE_IN_BAND_RESIZE :: Mode(2048)
MODE_PASTE_EVENTS :: Mode(5522)

mode_new :: proc(value: u16, ansi: bool) -> Mode {
	return (value & 0x7fff) | (u16(ansi) << 15)
}

mode_value :: proc(mode: Mode) -> u16 {
	return mode & 0x7fff
}

mode_ansi :: proc(mode: Mode) -> bool {
	return mode >> 15 != 0
}

@(default_calling_convention = "c", link_prefix = "ghostty_")
foreign lib {
	@(require_results)
	mode_report_encode :: proc(mode: Mode, state: Mode_Report_State, buf: [^]u8, buf_len: uint, out_written: ^uint) -> Result ---
}
