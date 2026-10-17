package term_test

import "core:reflect"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import "aio:ghostty"
import "aio:input"
import "aio:platform"
import "aio:term"

POWERSHELL :: "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe -NoProfile -Command "
SHIFT_PRESSED :: 0x10

Wakes :: struct {
	count: int,
}

on_wake :: proc(user: rawptr) {
	sync.atomic_add(&(^Wakes)(user).count, 1)
}

config :: proc(command: string) -> term.Config {
	return {
		command_line = command,
		working_directory = "C:\\Windows\\System32",
		geometry = {
			columns = 100,
			rows = 30,
			cell_width = 8,
			cell_height = 16,
			surface_width = 800,
			surface_height = 480,
		},
		scrollback_lines = 1000,
		colors = {foreground = {220, 220, 220}, background = {16, 16, 16}, cursor = {255, 255, 255}},
	}
}

start :: proc(t: ^testing.T, command: string, wakes: ^Wakes) -> ^term.Session {
	testing.set_fail_timeout(t, 60 * time.Second)
	s, err := term.create(config(command), {on_wake, wakes})
	testing.expect_value(t, err, term.Error.None)
	return s
}

screen_text :: proc(s: ^term.Session) -> string {
	term.select_all(s)
	text, _ := term.selection_text(s, context.temp_allocator)
	term.clear_selection(s)
	return text
}

Condition :: proc(s: ^term.Session, data: string) -> bool

await :: proc(t: ^testing.T, s: ^term.Session, condition: Condition, data: string) -> bool {
	deadline := time.tick_now()
	for time.tick_since(deadline) < 20 * time.Second {
		if condition(s, data) {
			return true
		}
		time.sleep(10 * time.Millisecond)
	}
	testing.expectf(t, false, "timed out waiting for %q; screen: %q", data, screen_text(s))
	return false
}

shows :: proc(s: ^term.Session, text: string) -> bool {
	return strings.contains(screen_text(s), text)
}

exited :: proc(s: ^term.Session, _: string) -> bool {
	return term.status(s).kind == .Exited
}

press_and_release :: proc(s: ^term.Session, event: platform.Key_Event) {
	down := event
	down.pressed = true
	term.send_key(s, down)
	up := event
	up.pressed = false
	up.text = ""
	up.native.char = 0
	term.send_key(s, up)
}

enter :: proc(modifiers: input.Modifiers, state: u32) -> platform.Key_Event {
	return {
		key = .Enter,
		modifiers = modifiers,
		text = "\r",
		native = {vk = 0x0d, scan_code = 0x1c, char = '\r', control_key_state = state, repeat_count = 1},
	}
}

@(test)
scanner_tracks_win32_input_mode :: proc(t: ^testing.T) {
	Case :: struct {
		chunks: []string,
		enabled, changed: bool,
	}
	cases := [?]Case{
		{{"\x1b[?9001h"}, true, true},
		{{"\x1b[?9001l"}, false, true},
		{{"\x1b[?90", "01h"}, true, true},
		{{"\x1b", "[", "?", "9001", "h"}, true, true},
		{{"\x1b[?1004;9001h"}, true, true},
		{{"\x1b[?9001;25l"}, false, true},
		{{"\x1b[?25h\x1b[?1004h"}, false, false},
		{{"\x1b[9001h"}, false, false},
		{{"\x1b[?9001h text \x1b[?9001l"}, false, true},
		{{"\x1b[?9001$p"}, false, false},
		{{"\x1b[?90\x1b[?9001h"}, true, true},
	}
	for c in cases {
		scanner: term.Mode_Scanner
		enabled, changed: bool
		for chunk in c.chunks {
			if e, ok := term.scan_win32_input_mode(&scanner, transmute([]u8)chunk); ok {
				enabled, changed = e, true
			}
		}
		matches := enabled == c.enabled && changed == c.changed
		testing.expectf(t, matches, "%q: got %v %v", c.chunks, enabled, changed)
	}
}

@(test)
input_types_mirror_libghostty :: proc(t: ^testing.T) {
	for key in input.Key {
		name, _ := reflect.enum_name_from_value(key)
		mirrored, ok := reflect.enum_from_name(ghostty.Key, name)
		testing.expectf(t, ok && i64(mirrored) == i64(key), "input.Key.%s has no matching ghostty.Key", name)
	}
	testing.expect_value(t, len(input.Key), len(ghostty.Key))
	pairs := [?]struct {
		modifier: input.Modifier,
		mod: ghostty.Mod,
	}{
		{.Shift, .Shift},
		{.Control, .Ctrl},
		{.Alt, .Alt},
		{.Super, .Super},
		{.Caps_Lock, .Caps_Lock},
		{.Num_Lock, .Num_Lock},
		{.Right_Shift, .Shift_Side},
		{.Right_Control, .Ctrl_Side},
		{.Right_Alt, .Alt_Side},
		{.Right_Super, .Super_Side},
	}
	for pair in pairs {
		testing.expect_value(t, transmute(u16)input.Modifiers{pair.modifier}, transmute(u16)ghostty.Mods{pair.mod})
	}
}

@(test)
output_and_exit_status :: proc(t: ^testing.T) {
	wakes: Wakes
	s := start(t, "cmd.exe /d /c \"echo AIO_SESSION_OUTPUT&exit /b 3\"", &wakes)
	if s == nil {
		return
	}
	defer term.destroy(s)
	if await(t, s, exited, "exit") {
		status := term.status(s)
		testing.expect_value(t, status.exit_code, 3)
	}
	testing.expect(t, await(t, s, shows, "AIO_SESSION_OUTPUT"))
	testing.expect(t, sync.atomic_load(&wakes.count) > 0)
	testing.expect(t, term.generation(s) > 0)
}

@(test)
failed_spawn_reports_message :: proc(t: ^testing.T) {
	wakes: Wakes
	context.logger = {}
	s := start(t, "aio_missing_program_5512.exe", &wakes)
	if s == nil {
		return
	}
	defer term.destroy(s)
	status := term.status(s)
	testing.expect_value(t, status.kind, term.Status_Kind.Failed)
	testing.expect(t, strings.has_prefix(status.message, "Could not start \"aio_missing_program_5512.exe\""))
}

@(test)
shift_enter_reaches_console_programs :: proc(t: ^testing.T) {
	wakes: Wakes
	script :: "\"[Console]::WriteLine('READY'); $k = [Console]::ReadKey($true); " +
		"[Console]::WriteLine('KEY:' + $k.Key + ':' + $k.Modifiers + ':' + [int]$k.KeyChar)\""
	s := start(t, POWERSHELL + script, &wakes)
	if s == nil {
		return
	}
	defer term.destroy(s)
	if !await(t, s, shows, "READY") {
		return
	}
	press_and_release(s, enter({.Shift}, SHIFT_PRESSED))
	testing.expect(t, await(t, s, shows, "KEY:Enter:Shift:13"))
}

@(test)
text_and_paste_round_trip :: proc(t: ^testing.T) {
	wakes: Wakes
	script :: "\"[Console]::WriteLine('READY'); $a = [Console]::ReadLine(); $b = [Console]::ReadLine(); " +
		"[Console]::WriteLine('GOT:' + $a + '|' + $b)\""
	s := start(t, POWERSHELL + script, &wakes)
	if s == nil {
		return
	}
	defer term.destroy(s)
	if !await(t, s, shows, "READY") {
		return
	}
	testing.expect(t, term.send_text(s, "h\u00e9llo"))
	press_and_release(s, enter({}, 0))
	testing.expect_value(t, term.paste(s, "second\r\n"), term.Paste_Result.Unsafe)
	testing.expect_value(t, term.paste(s, "sec"), term.Paste_Result.Sent)
	testing.expect_value(t, term.paste(s, "ond\x1b[201~\n", allow_unsafe = true), term.Paste_Result.Sent)
	testing.expect(t, await(t, s, shows, "GOT:h\u00e9llo|second [201~"))
}

@(test)
restart_and_destroy_while_running :: proc(t: ^testing.T) {
	wakes: Wakes
	s := start(t, "cmd.exe /d /c exit 9", &wakes)
	if s == nil {
		return
	}
	if await(t, s, exited, "exit") {
		testing.expect_value(t, term.status(s).exit_code, 9)
	}
	term.restart(s, config("cmd.exe /d /c \"echo AIO_RESTARTED&ping -n 30 127.0.0.1 > nul\""))
	testing.expect_value(t, term.status(s).kind, term.Status_Kind.Running)
	testing.expect(t, await(t, s, shows, "AIO_RESTARTED"))
	started := time.tick_now()
	term.destroy(s)
	testing.expect(t, time.tick_since(started) < 10 * time.Second)
}

@(test)
scrollback_selection_and_resize :: proc(t: ^testing.T) {
	wakes: Wakes
	s := start(t, "cmd.exe /d /c \"for /l %i in (1,1,80) do @echo LINE_%i\"", &wakes)
	if s == nil {
		return
	}
	defer term.destroy(s)
	if !await(t, s, exited, "exit") || !await(t, s, shows, "LINE_80") {
		return
	}
	testing.expect(t, !term.has_selection(s))
	term.select_all(s)
	testing.expect(t, term.has_selection(s))
	text, ok := term.selection_text(s, context.temp_allocator)
	testing.expect(t, ok && strings.contains(text, "LINE_1\n") && strings.contains(text, "LINE_80"))
	term.clear_selection(s)
	testing.expect(t, !term.has_selection(s))
	_, none := term.selection_text(s, context.temp_allocator)
	testing.expect(t, !none)
	before := term.generation(s)
	term.scroll(s, 3, {}, 10, 10)
	term.scroll_to_bottom(s)
	g := config("").geometry
	g.columns, g.surface_width = 60, 480
	term.resize(s, g)
	term.clear_scrollback(s)
	testing.expect(t, term.generation(s) > before)
}

@(test)
mouse_drag_selects_text :: proc(t: ^testing.T) {
	wakes: Wakes
	s := start(t, "cmd.exe /d /c \"echo DRAG_TARGET_TEXT&ping -n 30 127.0.0.1 > nul\"", &wakes)
	if s == nil {
		return
	}
	defer term.destroy(s)
	if !await(t, s, shows, "DRAG_TARGET_TEXT") {
		return
	}
	g := config("").geometry
	row := f32(g.cell_height) / 2
	term.selection_press(s, 1, row, 1_000)
	term.selection_drag(s, f32(g.cell_width) * 6 + 1, row)
	term.selection_release(s, f32(g.cell_width) * 6 + 1, row)
	text, selected := term.selection_text(s, context.temp_allocator)
	testing.expect(t, selected)
	testing.expect_value(t, text, "DRAG_T")
	term.selection_press(s, f32(g.cell_width) * 2, row, 2_000_000_000)
	term.selection_release(s, f32(g.cell_width) * 2, row)
	term.selection_press(s, f32(g.cell_width) * 2, row, 2_100_000_000)
	term.selection_release(s, f32(g.cell_width) * 2, row)
	word, word_selected := term.selection_text(s, context.temp_allocator)
	testing.expect(t, word_selected)
	testing.expect_value(t, word, "DRAG_TARGET_TEXT")
}

@(test)
ctrl_c_interrupts_the_foreground_program :: proc(t: ^testing.T) {
	LEFT_CTRL_PRESSED :: 0x08
	wakes: Wakes
	s := start(t, "cmd.exe /d /c ping -t 127.0.0.1", &wakes)
	if s == nil {
		return
	}
	defer term.destroy(s)
	if !await(t, s, shows, "Reply from") {
		return
	}
	press_and_release(s, {
		key = .C,
		modifiers = {.Control},
		text = "\x03",
		native = {vk = 'C', scan_code = 0x2e, char = 0x03, control_key_state = LEFT_CTRL_PRESSED, repeat_count = 1},
	})
	testing.expect(t, await(t, s, shows, "Control-C"))
}
