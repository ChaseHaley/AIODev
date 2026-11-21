package app_test

import app "../../src"
import "aio:input"
import "core:testing"

@(test)
neovim_key_notation_names_keys_as_neovim_reads_them :: proc(t: ^testing.T) {
	Case :: struct {
		key:       input.Key,
		modifiers: input.Modifiers,
		text:      string,
		unshifted: rune,
		want:      string,
	}
	cases := [?]Case {
		// Typed text goes as itself, '<' as <lt> so Neovim does not read it as a key name.
		{key = .A, text = "a", unshifted = 'a', want = "a"},
		{key = .A, modifiers = {.Shift}, text = "A", unshifted = 'a', want = "A"},
		{key = .Comma, modifiers = {.Shift}, text = "<", unshifted = ',', want = "<lt>"},
		{key = .Space, text = " ", unshifted = ' ', want = " "},
		// Ctrl names the key's own character and keeps Shift; Alt alone keeps the character it typed.
		{key = .A, modifiers = {.Control}, text = "\x01", unshifted = 'a', want = "<C-a>"},
		{key = .A, modifiers = {.Control, .Shift}, text = "\x01", unshifted = 'a', want = "<C-S-a>"},
		{key = .A, modifiers = {.Alt}, text = "a", unshifted = 'a', want = "<A-a>"},
		{key = .A, modifiers = {.Alt, .Shift}, text = "A", unshifted = 'a', want = "<A-A>"},
		{key = .Bracket_Left, modifiers = {.Control}, text = "\x1b", unshifted = '[', want = "<C-[>"},
		{key = .Backslash, modifiers = {.Control}, text = "\x1c", unshifted = '\\', want = "<C-Bslash>"},
		{key = .Digit_6, modifiers = {.Control}, unshifted = '6', want = "<C-^>"},
		{key = .Space, modifiers = {.Control}, text = " ", unshifted = ' ', want = "<C-Space>"},
		// AltGr is Ctrl with right Alt on Windows, and what it types is text.
		{key = .Q, modifiers = {.Control, .Alt, .Right_Alt}, text = "@", unshifted = 'q', want = "@"},
		// Keys without text of their own go by name, with every modifier.
		{key = .Enter, text = "\r", want = "<CR>"},
		{key = .Escape, text = "\x1b", want = "<Esc>"},
		{key = .Tab, modifiers = {.Shift}, text = "\t", want = "<S-Tab>"},
		{key = .Backspace, modifiers = {.Control}, text = "\x7f", want = "<C-BS>"},
		{key = .Arrow_Left, modifiers = {.Control, .Shift}, want = "<C-S-Left>"},
		{key = .Page_Down, want = "<PageDown>"},
		{key = .F5, modifiers = {.Alt}, want = "<A-F5>"},
		// A numpad key types its digit while Num Lock is on and moves the cursor while it is off.
		{key = .Numpad_7, text = "7", want = "7"},
		{key = .Numpad_Home, want = "<Home>"},
		{key = .Numpad_Enter, text = "\r", want = "<CR>"},
		// A lone modifier sends nothing.
		{key = .Shift_Left, modifiers = {.Shift}, want = ""},
	}
	for c in cases {
		event := input.Key_Event {
			key = c.key, modifiers = c.modifiers, pressed = true, text = c.text, unshifted = c.unshifted,
		}
		buffer: [app.NEOVIM_KEY_MAX]u8
		got := app.neovim_key_notation(event, buffer[:])
		testing.expectf(t, got == c.want, "%v %v %q: got %q, want %q", c.key, c.modifiers, c.text, got, c.want)
	}
	release := input.Key_Event{key = .A, text = "a", unshifted = 'a'}
	buffer: [app.NEOVIM_KEY_MAX]u8
	testing.expect_value(t, app.neovim_key_notation(release, buffer[:]), "")
}
