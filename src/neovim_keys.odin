package main

import "cosmos:input"
import "core:strings"
import "core:unicode/utf8"

// Room for the longest key a press names: "<C-S-A-D-PageDown>" or a few typed characters.
NEOVIM_KEY_MAX :: 64

// Neovim's name for a key that types no text of its own; "" for every other key.
@(private = "file")
neovim_key_name :: proc(key: input.Key) -> string {
	#partial switch key {
	case .Escape: return "Esc"
	case .Enter, .Numpad_Enter: return "CR"
	case .Tab: return "Tab"
	case .Backspace, .Numpad_Backspace: return "BS"
	case .Delete, .Numpad_Delete: return "Del"
	case .Insert, .Numpad_Insert: return "Insert"
	case .Home, .Numpad_Home: return "Home"
	case .End, .Numpad_End: return "End"
	case .Page_Up, .Numpad_Page_Up: return "PageUp"
	case .Page_Down, .Numpad_Page_Down: return "PageDown"
	case .Arrow_Up, .Numpad_Up: return "Up"
	case .Arrow_Down, .Numpad_Down: return "Down"
	case .Arrow_Left, .Numpad_Left: return "Left"
	case .Arrow_Right, .Numpad_Right: return "Right"
	case .Help: return "Help"
	}
	if key >= .F1 && key <= .F24 {
		@(static, rodata) names := [?]string {
			"F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12",
			"F13", "F14", "F15", "F16", "F17", "F18", "F19", "F20", "F21", "F22", "F23", "F24",
		}
		return names[int(key) - int(input.Key.F1)]
	}
	return ""
}

// A numpad key types its digit or sign while Num Lock is on, and moves the cursor while it is off.
@(private = "file")
neovim_numpad :: proc(key: input.Key) -> bool {
	return key >= .Numpad_0 && key <= .Numpad_Page_Down
}

// The name a character takes inside Neovim's <...> notation.
@(private = "file")
neovim_char_name :: proc(r: rune, buffer: []u8) -> string {
	switch r {
	case '<': return "lt"
	case '\\': return "Bslash"
	case '|': return "Bar"
	}
	encoded, width := utf8.encode_rune(r)
	if width > len(buffer) {return ""}
	copy(buffer, encoded[:width])
	return string(buffer[:width])
}

// Writes "<mods-name>" into `out`.
@(private = "file")
neovim_chord :: proc(out: ^strings.Builder, shift, ctrl, alt, super: bool, name: string) {
	strings.write_byte(out, '<')
	if ctrl {strings.write_string(out, "C-")}
	if shift {strings.write_string(out, "S-")}
	if alt {strings.write_string(out, "A-")}
	if super {strings.write_string(out, "D-")}
	strings.write_string(out, name)
	strings.write_byte(out, '>')
}

// What a key press sends to Neovim in its key notation, written into `buffer`; "" for a release, a lone
// modifier or a key Neovim has no name for. Text typed without Ctrl or Alt goes as itself. Windows
// reports AltGr as Ctrl with right Alt, and the character it types goes as text too.
@(require_results)
neovim_key_notation :: proc(e: input.Key_Event, buffer: []u8) -> string {
	if !e.pressed || input.is_modifier_key(e.key) {return ""}
	out := strings.builder_from_bytes(buffer)
	shift, ctrl := .Shift in e.modifiers, .Control in e.modifiers
	alt, super := .Alt in e.modifiers, .Super in e.modifiers
	if ctrl && .Right_Alt in e.modifiers {ctrl, alt = false, false}
	first, _ := utf8.decode_rune_in_string(e.text)
	printable := e.text != "" && first >= 0x20 && first != 0x7f
	if name := neovim_key_name(e.key); name != "" && !(neovim_numpad(e.key) && printable) {
		neovim_chord(&out, shift, ctrl, alt, super, name)
		return strings.to_string(out)
	}
	if e.key == .Space {
		if !ctrl && !alt && !super {return " "}
		neovim_chord(&out, shift, ctrl, alt, super, "Space")
		return strings.to_string(out)
	}
	if !ctrl && !alt && !super {
		if !printable {return ""}
		for r in e.text {
			if r == '<' {strings.write_string(&out, "<lt>")} else {strings.write_rune(&out, r)}
		}
		return strings.to_string(out)
	}
	// With Ctrl the key's own character names it and Shift stays a modifier; Alt alone keeps the shifted
	// character it typed. Ctrl+6 is Ctrl+^, alternate file, as terminals send it.
	base := e.unshifted
	if !ctrl && printable {base, shift = first, false}
	if base == 0 {base = first}
	if ctrl && base == '6' {base, shift = '^', false}
	if base < 0x20 || base == 0x7f {return ""}
	character: [8]u8
	name := neovim_char_name(base, character[:])
	if name == "" {return ""}
	neovim_chord(&out, shift, ctrl, alt, super, name)
	return strings.to_string(out)
}
