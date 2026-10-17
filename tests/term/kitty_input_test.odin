package term_test

import "core:testing"
import "aio:term"

@(test)
negotiated_kitty_shift_enter_reaches_raw_input :: proc(t: ^testing.T) {
	wakes: Wakes
	command :: "pwsh.exe -NoLogo -NoProfile -File \"" + #directory + "/kitty_input.ps1\""
	s := start(t, command, &wakes)
	if s == nil { return }
	defer term.destroy(s)
	if !await(t, s, shows, "KITTY_READY") { return }
	press_and_release(s, enter({.Shift}, SHIFT_PRESSED))
	testing.expect(t, await(t, s, shows, "RAW_HEX:"))
	testing.expectf(t, shows(s, "RAW_HEX:1B-5B-31-33-3B-32-75"), "%s", screen_text(s))
}
