package term_test

import "aio:term"
import "core:testing"

@(test)
shell_mode_scanner_parses_bel_and_st :: proc(t: ^testing.T) {
	s: term.Shell_Mode_Scanner

	mode, changed := term.scan_shell_mode(&s, transmute([]u8)string("hello world"))
	testing.expect(t, !changed)
	testing.expect_value(t, mode, term.Shell_Mode.None)

	mode, changed = term.scan_shell_mode(&s, transmute([]u8)string("\x1b]7502;mode=normal\x07"))
	testing.expect(t, changed)
	testing.expect_value(t, mode, term.Shell_Mode.Normal)

	mode, changed = term.scan_shell_mode(&s, transmute([]u8)string("\x1b]7502;mode=v-line\x1b\\"))
	testing.expect(t, changed)
	testing.expect_value(t, mode, term.Shell_Mode.Visual_Line)

	mode, changed = term.scan_shell_mode(&s, transmute([]u8)string("\x1b]7502;mode=clear\x07"))
	testing.expect(t, changed)
	testing.expect_value(t, mode, term.Shell_Mode.None)
}

@(test)
shell_mode_scanner_handles_split_chunks_and_other_oscs :: proc(t: ^testing.T) {
	s: term.Shell_Mode_Scanner

	// Unrelated OSC should not trigger a change.
	_, changed := term.scan_shell_mode(&s, transmute([]u8)string("\x1b]0;Window Title\x07"))
	testing.expect(t, !changed)

	// Split across three chunks.
	mode: term.Shell_Mode
	_, changed = term.scan_shell_mode(&s, transmute([]u8)string("abc\x1b]75"))
	testing.expect(t, !changed)
	_, changed = term.scan_shell_mode(&s, transmute([]u8)string("02;mode=vis"))
	testing.expect(t, !changed)
	mode, changed = term.scan_shell_mode(&s, transmute([]u8)string("ual\x07tail"))
	testing.expect(t, changed)
	testing.expect_value(t, mode, term.Shell_Mode.Visual)

	// Unknown mode value is ignored.
	_, changed = term.scan_shell_mode(&s, transmute([]u8)string("\x1b]7502;mode=unknown\x07"))
	testing.expect(t, !changed)
}
