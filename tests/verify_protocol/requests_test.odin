package verify_protocol_test

import "base:runtime"
import "core:strings"
import "core:testing"
import "aio:verify_protocol"
import "aio:input"

fail_allocation :: proc(
	data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int,
	old_memory: rawptr, old_size: int, location: runtime.Source_Code_Location,
) -> ([]u8, runtime.Allocator_Error) {
	if mode == .Alloc || mode == .Alloc_Non_Zeroed || mode == .Resize || mode == .Resize_Non_Zeroed {
		return nil, .Out_Of_Memory
	}
	return nil, nil
}

failing_allocator :: proc() -> runtime.Allocator { return {fail_allocation, nil} }

@(test)
parse_commands :: proc(t: ^testing.T) {
	cases := [][]string{
		{"ping"}, {"state"}, {"screen"}, {"screen", "1"}, {"screen", "1:2"},
		{"cells", "2"}, {"cells", "2", "1:8"}, {"type", "hello\nworld"}, {"type", ""},
		{"key", "Ctrl+Shift+P", "Esc", "Enter"}, {"command", "app.reload_settings"},
		{"command", "pane.split", "--direction", "left", "--ratio", "0.25", "--focus", "false"},
		{"wait", "text", "hello"}, {"wait", "gone", "hello", "--timeout", "0"},
		{"wait", "idle"}, {"wait", "idle", "20", "--timeout", "500"},
		{"wait", "frame", "--timeout", "100"}, {"run", "echo hi"},
		{"run", "echo hi", "--timeout", "200", "--idle", "0"},
		{"expect", "text", "hi"}, {"expect", "no-text", "bye"},
		{"expect", "cursor", "2,3"}, {"expect", "state", "palette.query=a=b"},
		{"expect", "cell", "0,1", "underline=single", "fg=default", "bg=#00AAbb", "wide=false"},
		{"focus", "in"}, {"focus", "out"}, {"tray", "open"}, {"tray", "hide"}, {"tray", "quit"},
		{"resize", "1x1000"}, {"dpi", "48"}, {"dpi", "768"}, {"help"}, {"help", "screen"},
		{"mouse", "move", "1,2"}, {"mouse", "down", "1,2", "--button", "right"},
		{"mouse", "up", "1,2", "--button", "middle"}, {"mouse", "click", "1,2", "--button", "left"},
		{"mouse", "drag", "1,2", "3,4", "--px", "--mods", "Ctrl+Shift"},
		{"mouse", "wheel", "1,2", "-3", "--mods", "Alt+Win", "--px"},
		{"mouse", "move", "-2147483648,2147483647", "--screen"},
		{"mouse", "drag", "-100,20", "30,-40", "--screen", "--mods", "Ctrl"},
		{"mouse", "wheel", "-100,-20", "-3", "--screen"},
		{"window", "select", "18446744073709551615"}, {"window", "move", "-2147483648,2147483647"},
		{"window", "at", "-2147483648,2147483647"},
		{"capture"}, {"capture", "--out", "before.png"}, {"capture", "--cell", "0,0"},
		{"capture", "--cell", "0,0,10,2", "--out", "region.png"},
		{"capture", "--region", "0,0,120,32"},
		{"pixels"}, {"pixels", "--rows"}, {"pixels", "--columns"}, {"pixels", "--sample", "3,4"},
		{"pixels", "--cell", "1,2,3,4", "--rows"},
		{"diff", "before.png"}, {"draws"}, {"draws", "--kind", "rect"},
		{"draws", "--region", "1,2,3,4", "--kind", "glyph"},
		{"perf"}, {"perf", "--reset"}, {"vt", "record", "on"}, {"vt", "record", "off"},
	}
	for args in cases {
		r, err := verify_protocol.parse(args)
		testing.expect(t, err.advice == "", args[0])
		verify_protocol.request_destroy(&r)
	}
	r, err := verify_protocol.parse({"wait", "idle"})
	defer verify_protocol.request_destroy(&r)
	testing.expect_value(t, err.advice, "")
	w := r.(verify_protocol.Wait)
	testing.expect_value(t, w.idle_ms, 300)
	testing.expect_value(t, w.timeout_ms, 5000)
	run, run_error := verify_protocol.parse({"run", "x"})
	testing.expect_value(t, run_error.advice, "")
	testing.expect_value(t, run.(verify_protocol.Run).idle_ms, 300)
	testing.expect_value(t, run.(verify_protocol.Run).timeout_ms, 10000)
	m, mouse_error := verify_protocol.parse({"mouse", "click", "2,3"})
	testing.expect_value(t, mouse_error.advice, "")
	testing.expect_value(t, m.(verify_protocol.Mouse).button, input.Mouse_Button.Left)
	testing.expect_value(t, m.(verify_protocol.Mouse).position, verify_protocol.Position{2, 3})
	testing.expect(t, !m.(verify_protocol.Mouse).pixels)
	split, split_error := verify_protocol.parse({"command", "pane.split", "--direction", "up",
		"--ratio", "0.3", "--focus", "false"})
	testing.expect_value(t, split_error.advice, "")
	s := split.(verify_protocol.Command)
	testing.expect_value(t, s.ratio, f32(0.3))
	testing.expect(t, !s.focus)
}

@(test)
parse_errors :: proc(t: ^testing.T) {
	cases := [][]string{
		{}, {"nope"}, {"ping", "x"}, {"state", "x"}, {"help", "a", "b"},
		{"screen", "-1"}, {"screen", "2:1"}, {"screen", "1:"}, {"screen", "x"},
		{"screen", "1", "2"}, {"cells"}, {"cells", "x"}, {"cells", "0", "1"},
		{"type"}, {"type", "a", "b"}, {"command", ""}, {"focus", "bad"}, {"tray", "bad"},
		{"command", "pane.zoom", "--ratio", "0.5"}, {"command", "pane.split", "--ratio", "NaN"},
		{"command", "pane.split", "--ratio", "0"}, {"command", "pane.split", "--ratio", "1"},
		{"command", "pane.split", "--direction", "above"}, {"command", "pane.split", "--focus", "no"},
		{"command", "pane.split", "--ratio"}, {"command", "pane.split", "--bad", "1"},
		{"command", "pane.split", "--focus", "true", "--focus", "false"},
		{"resize", "0x2"}, {"resize", "2x0"}, {"resize", "1001x2"}, {"resize", "2,3"},
		{"dpi", "47"}, {"dpi", "769"}, {"dpi", "abc"}, {"dpi", "99999999999999999999"},
		{"key"}, {"key", "Ctrl+bogus"}, {"key", "A", "Ctrl+Ctrl+A"},
		{"key", "Physical+Ctrl+Z"}, {"key", "Leader+T"},
		{"wait"}, {"wait", "text"}, {"wait", "x"}, {"wait", "idle", "-1"},
		{"wait", "frame", "--timeout"}, {"wait", "frame", "--timeout", "-1"},
		{"wait", "frame", "--idle", "1"}, {"wait", "idle", "--bad", "1"},
		{"run"}, {"run", "x", "--timeout", "1", "--timeout", "2"},
		{"run", "x", "--idle", "1", "--idle", "2"},
		{"expect"}, {"expect", "bad", "x"}, {"expect", "text", "x", "y"},
		{"expect", "cursor", "-1,0"}, {"expect", "cursor", "1:2"},
		{"expect", "cursor", "0,0", "x"}, {"expect", "cell", "0,0"},
		{"expect", "cell", "0,0", "bad=true"}, {"expect", "cell", "0,0", "bold=yes"},
		{"expect", "cell", "0,0", "underline=bad"}, {"expect", "cell", "0,0", "fg=#gg0000"},
		{"expect", "cell", "0,0", "bg=#000"}, {"expect", "state", "=x"},
		{"expect", "state", "x"}, {"mouse"}, {"mouse", "bad", "0,0"},
		{"mouse", "move", "a,b"}, {"mouse", "drag", "0,0"}, {"mouse", "drag", "0,0", "x"},
		{"mouse", "wheel", "0,0", "no"}, {"mouse", "click", "0,0", "--button"},
		{"mouse", "click", "0,0", "--button", "back"},
		{"mouse", "click", "0,0", "--mods", "Ctrl+Q"},
		{"mouse", "click", "0,0", "--mods", "Ctrl+Ctrl"},
		{"mouse", "click", "0,0", "--bad", "x"},
		{"mouse", "click", "0,0", "--px", "--px"},
		{"mouse", "click", "0,0", "--button", "left", "--button", "right"},
		{"mouse", "click", "0,0", "--mods", "Alt", "--mods", "Ctrl"},
		{"window"}, {"window", "select"}, {"window", "select", "0"}, {"window", "select", "-1"},
		{"window", "select", "+1"}, {"window", "select", ""}, {"window", "select", "1", "2"},
		{"window", "select", "18446744073709551616"}, {"window", "bad", "1"},
		{"window", "move", "1"}, {"window", "move", "1,2,3"}, {"window", "move", "2147483648,0"},
		{"window", "move", "0,-2147483649"}, {"window", "move", "--1,2"},
		{"window", "at"}, {"window", "at", "1"}, {"window", "at", "1,2,3"}, {"window", "at", "1,2", "3"},
		{"window", "at", "2147483648,0"},
		{"mouse", "move", "-1,0"}, {"mouse", "move", "-1,0", "--px"},
		{"mouse", "drag", "0,0", "-1,0"}, {"mouse", "move", "2147483648,0", "--screen"},
		{"mouse", "move", "0,-2147483649", "--screen"},
		{"mouse", "move", "0,0", "--screen", "--screen"},
		{"mouse", "move", "0,0", "--px", "--screen"},
		{"mouse", "move", "0,0", "--screen", "--px"},
		{"capture", "--cell"}, {"capture", "--cell", "1"}, {"capture", "--cell", "1,2,0,1"},
		{"capture", "--cell", "-1,2"}, {"capture", "--cell", "1,2,3"},
		{"capture", "--region", "1,2,3"}, {"capture", "--region", "1,2,0,1"},
		{"capture", "--cell", "1,2", "--region", "0,0,1,1"},
		{"capture", "--out", ""}, {"capture", "--out", "a", "--out", "b"},
		{"capture", "--bad", "1"},
		{"pixels", "--sample", "1"}, {"pixels", "--sample", "-1,0"},
		{"pixels", "--rows", "--columns"}, {"pixels", "--rows", "--rows"},
		{"pixels", "--sample", "1,2", "--rows"}, {"pixels", "extra"},
		{"diff"}, {"diff", ""}, {"diff", "a", "b"},
		{"draws", "--kind", "bad"}, {"draws", "--kind"},
		{"draws", "--region", "0,0,0,1"},
		{"draws", "--region", "0,0,1,1", "--region", "1,1,1,1"},
		{"perf", "x"}, {"perf", "--reset", "x"}, {"perf", "--bad"},
		{"vt"}, {"vt", "record"}, {"vt", "record", "yes"}, {"vt", "other", "on"},
		{"vt", "record", "on", "x"},
	}
	for args in cases {
		r, err := verify_protocol.parse(args)
		testing.expect(t, err.advice != "")
		verify_protocol.request_destroy(&r)
	}
	r, err := verify_protocol.parse({"key", "A"}, failing_allocator())
	verify_protocol.request_destroy(&r)
	testing.expect(t, err.advice != "")
}

@(test)
help_verbs :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	testing.expect_value(t, verify_protocol.help(&b), verify_protocol.Error.None)
	testing.expect_value(t, strings.to_string(b), verify_protocol.HELP_OVERVIEW)
	for command in ([]string{"ping", "screen", "cells", "state", "wait", "expect", "type", "key",
		"run", "mouse", "focus", "resize", "dpi", "tray", "command", "window", "help", "capture",
		"pixels", "diff", "draws", "perf", "vt"}) {
		strings.builder_reset(&b)
		testing.expect_value(t, verify_protocol.help(&b, command), verify_protocol.Error.None)
		testing.expect(t, strings.has_prefix(strings.to_string(b), command))
	}
	testing.expect_value(t, verify_protocol.help(&b, "bad"), verify_protocol.Error.Invalid_Argument)
}

@(test)
window_requests_preserve_screen_coordinates_and_target_ids :: proc(t: ^testing.T) {
	r, err := verify_protocol.parse({"window", "select", "4294967297"})
	testing.expect_value(t, err.advice, "")
	testing.expect_value(t, r.(verify_protocol.Window_Select).id, u64(4294967297))
	r, err = verify_protocol.parse({"window", "move", "-1920,-240"})
	testing.expect_value(t, err.advice, "")
	testing.expect_value(t, r.(verify_protocol.Window_Move).position, verify_protocol.Position{-1920, -240})
	r, err = verify_protocol.parse({"window", "at", "-1920,-240"})
	testing.expect_value(t, err.advice, "")
	testing.expect_value(t, r.(verify_protocol.Window_At).position, verify_protocol.Position{-1920, -240})
	r, err = verify_protocol.parse({"mouse", "drag", "-1920,-240", "200,-300", "--screen"})
	testing.expect_value(t, err.advice, "")
	m := r.(verify_protocol.Mouse)
	testing.expect_value(t, m.position, verify_protocol.Position{-1920, -240})
	testing.expect_value(t, m.end, verify_protocol.Position{200, -300})
	testing.expect(t, m.screen && !m.pixels)
}

@(test)
evidence_requests_default_to_the_whole_window :: proc(t: ^testing.T) {
	capture, capture_error := verify_protocol.parse({"capture"})
	testing.expect_value(t, capture_error.advice, "")
	testing.expect_value(t, capture.(verify_protocol.Capture).region.kind, verify_protocol.Region_Kind.Window)
	testing.expect_value(t, capture.(verify_protocol.Capture).output, "")

	pixels, pixels_error := verify_protocol.parse({"pixels"})
	testing.expect_value(t, pixels_error.advice, "")
	testing.expect_value(t, pixels.(verify_protocol.Pixels).region.kind, verify_protocol.Region_Kind.Window)
	testing.expect(t, !pixels.(verify_protocol.Pixels).rows && !pixels.(verify_protocol.Pixels).columns)

	cell, cell_error := verify_protocol.parse({"capture", "--cell", "4,5"})
	testing.expect_value(t, cell_error.advice, "")
	region := cell.(verify_protocol.Capture).region
	testing.expect_value(t, region.kind, verify_protocol.Region_Kind.Cells)
	testing.expect_value(t, region.x, 4)
	testing.expect_value(t, region.y, 5)
	testing.expect_value(t, region.width, 1)
	testing.expect_value(t, region.height, 1)

	sample, sample_error := verify_protocol.parse({"pixels", "--sample", "2,3"})
	testing.expect_value(t, sample_error.advice, "")
	testing.expect_value(t, sample.(verify_protocol.Pixels).sample, verify_protocol.Position{2, 3})

	draws, draws_error := verify_protocol.parse({"draws", "--kind", "glyph"})
	testing.expect_value(t, draws_error.advice, "")
	testing.expect_value(t, draws.(verify_protocol.Draws).kind, verify_protocol.Draw_Kind.Glyph)

	vt, vt_error := verify_protocol.parse({"vt", "record", "on"})
	testing.expect_value(t, vt_error.advice, "")
	testing.expect(t, vt.(verify_protocol.Vt).recording)
}
