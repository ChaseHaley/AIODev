package ghostty_test

import "core:testing"
import "aio:ghostty"

Effects :: struct {
	output: [1024]u8,
	len: int,
	overflow: bool,
	bells, titles, holds: int,
	held: bool,
	attributes_queries: int,
	paste_text: string,
	reader_calls: int,
	reader_fail: bool,
}

write_pty :: proc "c" (terminal: ghostty.Terminal, userdata: rawptr, data: [^]u8, length: uint) {
	effects := cast(^Effects)userdata
	if length > uint(len(effects.output) - effects.len) {
		effects.overflow = true
		return
	}
	copy(effects.output[effects.len:], data[:length])
	effects.len += int(length)
}

bell :: proc "c" (terminal: ghostty.Terminal, userdata: rawptr) {
	effects := cast(^Effects)userdata
	effects.bells += 1
}

title_changed :: proc "c" (terminal: ghostty.Terminal, userdata: rawptr) {
	effects := cast(^Effects)userdata
	effects.titles += 1
}

render_hold :: proc "c" (terminal: ghostty.Terminal, userdata: rawptr, held: bool) {
	effects := cast(^Effects)userdata
	effects.holds += 1
	effects.held = held
}

device_attributes :: proc "c" (
	terminal: ghostty.Terminal,
	userdata: rawptr,
	out_attrs: ^ghostty.Device_Attributes,
) -> bool {
	effects := cast(^Effects)userdata
	effects.attributes_queries += 1
	out_attrs^ = {}
	out_attrs.primary.conformance_level = 62
	out_attrs.primary.features[0] = 1
	out_attrs.primary.features[1] = 6
	out_attrs.primary.num_features = 2
	return true
}

read_mime :: proc "c" (userdata: rawptr, mime: ghostty.String, writer: ghostty.Writer) -> bool {
	effects := cast(^Effects)userdata
	effects.reader_calls += 1
	if effects.reader_fail {
		return false
	}
	s := effects.paste_text
	return writer.write(writer.userdata, raw_data(s), uint(len(s)))
}

@(test)
write_pty_and_effects :: proc(t: ^testing.T) {
	terminal: ghostty.Terminal
	if !testing.expect_value(t, ghostty.terminal_new(nil, &terminal, 12, 4), SUCCESS) {
		return
	}
	defer ghostty.terminal_free(terminal)
	effects: Effects
	testing.expect_value(t, ghostty.terminal_set(terminal, .Userdata, &effects), SUCCESS)
	write_callback: ghostty.Terminal_Write_Pty_Fn = write_pty
	bell_callback: ghostty.Terminal_Bell_Fn = bell
	title_callback: ghostty.Terminal_Title_Changed_Fn = title_changed
	hold_callback: ghostty.Terminal_Render_Hold_Fn = render_hold
	attributes_callback: ghostty.Terminal_Device_Attributes_Fn = device_attributes
	testing.expect_value(t, ghostty.terminal_set(terminal, .Write_Pty, rawptr(write_callback)), SUCCESS)
	testing.expect_value(t, ghostty.terminal_set(terminal, .Bell, rawptr(bell_callback)), SUCCESS)
	testing.expect_value(t, ghostty.terminal_set(terminal, .Title_Changed, rawptr(title_callback)), SUCCESS)
	testing.expect_value(t, ghostty.terminal_set(terminal, .Render_Hold, rawptr(hold_callback)), SUCCESS)
	result := ghostty.terminal_set(terminal, .Device_Attributes, rawptr(attributes_callback))
	testing.expect_value(t, result, SUCCESS)
	write(terminal, "\x1b[3;5H\x1b[6n")
	testing.expect_value(t, string(effects.output[:effects.len]), "\x1b[3;5R")
	effects.len = 0
	write(terminal, "\x1b[c")
	testing.expect_value(t, string(effects.output[:effects.len]), "\x1b[?62;1;6c")
	testing.expect_value(t, effects.attributes_queries, 1)
	write(terminal, "\x07\x1b]2;AIODev fixture\x07")
	testing.expect_value(t, effects.bells, 1)
	testing.expect_value(t, effects.titles, 1)
	title: ghostty.String
	testing.expect_value(t, ghostty.terminal_get(terminal, .Title, &title), SUCCESS)
	testing.expect_value(t, string(title.ptr[:title.len]), "AIODev fixture")
	write(terminal, "\x1b[?2026h\x1b[?2026h")
	testing.expect_value(t, effects.holds, 1)
	testing.expect(t, effects.held)
	write(terminal, "\x1b[?2026l\x1b[?2026l")
	testing.expect_value(t, effects.holds, 2)
	testing.expect(t, !effects.held)
	write(terminal, "\x1b[?2026h")
	testing.expect_value(t, ghostty.terminal_resize(terminal, 12, 4, 8, 16), SUCCESS)
	testing.expect_value(t, effects.holds, 4)
	testing.expect(t, !effects.held)
	testing.expect(t, !effects.overflow)
	effects.len = 0
	testing.expect_value(t, ghostty.terminal_set(terminal, .Write_Pty, nil), SUCCESS)
	write(terminal, "\x1b[6n")
	testing.expect_value(t, effects.len, 0)
}

@(test)
terminal_paste :: proc(t: ^testing.T) {
	terminal: ghostty.Terminal
	if !testing.expect_value(t, ghostty.terminal_new(nil, &terminal, 12, 4), SUCCESS) {
		return
	}
	defer ghostty.terminal_free(terminal)
	effects := Effects{paste_text = "a\nb"}
	testing.expect_value(t, ghostty.terminal_set(terminal, .Userdata, &effects), SUCCESS)
	callback: ghostty.Terminal_Write_Pty_Fn = write_pty
	testing.expect_value(t, ghostty.terminal_set(terminal, .Write_Pty, rawptr(callback)), SUCCESS)
	mime := ghostty.String{ptr = raw_data(string("text/plain")), len = 10}
	paste := ghostty.sized(ghostty.Paste)
	paste.mimes = &mime
	paste.mimes_len = 1
	paste.reader = {read = read_mime, userdata = &effects}
	written: bool
	testing.expect_value(t, ghostty.terminal_paste(terminal, &paste, &written), ghostty.Result.Rejected)
	testing.expect_value(t, effects.len, 0)
	testing.expect_value(t, effects.reader_calls, 1)
	write(terminal, "\x1b[?2004h")
	testing.expect_value(t, ghostty.terminal_paste(terminal, &paste, &written), SUCCESS)
	testing.expect(t, written)
	testing.expect_value(t, string(effects.output[:effects.len]), "\x1b[200~a\nb\x1b[201~")
	effects.len = 0
	write(terminal, "\x1b[?2004l")
	paste.allow_unsafe = true
	testing.expect_value(t, ghostty.terminal_paste(terminal, &paste, &written), SUCCESS)
	testing.expect_value(t, string(effects.output[:effects.len]), "a\rb")
	effects.len = 0
	effects.reader_fail = true
	testing.expect_value(t, ghostty.terminal_paste(terminal, &paste, &written), ghostty.Result.Io_Error)
	testing.expect_value(t, effects.len, 0)
	paste.reader.read = nil
	testing.expect_value(t, ghostty.terminal_paste(terminal, &paste, &written), INVALID)
	testing.expect(t, !effects.overflow)
}

