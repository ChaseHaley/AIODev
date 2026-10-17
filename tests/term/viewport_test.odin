package term_test

import "core:fmt"
import "core:testing"
import "aio:ghostty"
import "aio:platform"
import "aio:term"

cursor_in_viewport :: proc(t: ^testing.T, s: ^term.Session, state: ghostty.Render_State) -> bool {
	if !testing.expect(t, term.capture(s, state)) {
		return false
	}
	cursor := ghostty.sized(ghostty.Render_State_Cursor)
	testing.expect_value(t, ghostty.render_state_get(state, .Cursor, &cursor), ghostty.Result.Success)
	return cursor.viewport_has_value
}

@(test)
only_text_input_returns_to_live_screen :: proc(t: ^testing.T) {
	state: ghostty.Render_State
	if !testing.expect_value(t, ghostty.render_state_new(nil, &state), ghostty.Result.Success) {
		return
	}
	defer ghostty.render_state_free(state)
	modes := [?]string{"h", "l"}
	for mode in modes {
		wakes: Wakes
		script := fmt.tprintf(
			"%s%s%s",
			"\"1..90 | ForEach-Object { [Console]::WriteLine('LINE_' + $_) }; " +
			"[Console]::Write([char]27 + '[?9001",
			mode,
			"'); [Console]::WriteLine('SCROLL_READY'); " +
			"while ($true) { $null = [Console]::ReadKey($true) }\"",
		)
		s := start(t, fmt.tprintf("%s%s", POWERSHELL, script), &wakes)
		if s == nil {
			return
		}
		defer term.destroy(s)
		if !await(t, s, shows, "SCROLL_READY") {
			return
		}
		if !testing.expectf(t, term.status(s).kind == .Running, "%s", screen_text(s)) {
			return
		}
		term.scroll_viewport(s, -50)
		testing.expect(t, !cursor_in_viewport(t, s, state))
		keys := [?]platform.Key_Event{
			{key = .Arrow_Left, pressed = true, native = {vk = 0x25, scan_code = 0x4b}},
			{key = .F1, pressed = true, native = {vk = 0x70, scan_code = 0x3b}},
			{key = .Shift_Left, pressed = true, native = {vk = 0x10, scan_code = 0x2a}},
			{key = .Shift_Left, pressed = false, native = {vk = 0x10, scan_code = 0x2a}},
		}
		for key in keys {
			term.send_key(s, key)
			testing.expect(t, !cursor_in_viewport(t, s, state))
		}
		testing.expect(t, term.send_text(s, ""))
		testing.expect_value(t, term.paste(s, ""), term.Paste_Result.Sent)
		testing.expect(t, !cursor_in_viewport(t, s, state))
		text_keys := [?]platform.Key_Event{
			{key = .A, pressed = true, text = "a", native = {vk = 'A', scan_code = 0x1e}},
			{key = .Enter, pressed = true, text = "\r", native = {vk = 0x0d, scan_code = 0x1c}},
			{key = .Backspace, pressed = true, text = "\x08", native = {vk = 0x08, scan_code = 0x0e}},
			{key = .Tab, pressed = true, text = "\t", native = {vk = 0x09, scan_code = 0x0f}},
			{key = .A, pressed = true, text = "\x01", modifiers = {.Control}, native = {vk = 'A'}},
		}
		for key in text_keys {
			term.scroll_viewport(s, -50)
			testing.expect(t, !cursor_in_viewport(t, s, state))
			testing.expect(t, term.send_key(s, key))
			testing.expect(t, cursor_in_viewport(t, s, state))
		}
		term.scroll_viewport(s, -50)
		testing.expect(t, term.send_text(s, "text"))
		testing.expect(t, cursor_in_viewport(t, s, state))
		term.scroll_viewport(s, -50)
		testing.expect_value(t, term.paste(s, "paste"), term.Paste_Result.Sent)
		testing.expect(t, cursor_in_viewport(t, s, state))
	}
}
