package aioctl_test

import "core:testing"
import "core:unicode/utf16"
import ctl "../../tools/aioctl"

@(test)
filtered_environment :: proc(t: ^testing.T) {
	for item in ([]struct { parent, expected: string, keep: bool }{
		{"A=x\x00NO_COLOR=1\x00Z=y\x00\x00", "A=x\x00Z=y\x00\x00", false},
		{"A=x\x00NO_COLOR=1\x00Z=y\x00\x00", "A=x\x00NO_COLOR=1\x00Z=y\x00\x00", true},
		{"no_color=\x00No_Color=1\x00Z=y\x00\x00", "Z=y\x00\x00", false},
		{"no_color=\x00Z=y\x00\x00", "no_color=\x00Z=y\x00\x00", true},
		{"=C:=C:\\repo\x00Z=y\x00\x00", "=C:=C:\\repo\x00Z=y\x00\x00", false},
		{"NO_COLOR=1\x00\x00", "\x00\x00", false},
		{"\x00\x00", "\x00\x00", false}, {"\x00\x00", "\x00\x00", true},
	}) {
		parent_buffer, expected_buffer: [512]u16
		n := utf16.encode_string(parent_buffer[:], item.parent)
		expected_n := utf16.encode_string(expected_buffer[:], item.expected)
		parent := parent_buffer[:n]
		original := parent_buffer
		out, ok := ctl.environment_block(parent, item.keep)
		defer delete(out)
		if !testing.expect(t, ok) { continue }
		if testing.expect_value(t, len(out), expected_n) {
			for unit, i in out { testing.expect_value(t, unit, expected_buffer[i]) }
		}
		for unit, i in parent { testing.expect_value(t, unit, original[i]) }
	}
}

@(test)
environment_errors :: proc(t: ^testing.T) {
	for parent in ([][]u16{nil, {0}, {'A', '=', 'x', 0}, {0, 0, 'x', 0, 0}}) {
		out, ok := ctl.environment_block(parent, false)
		defer delete(out)
		testing.expect(t, !ok)
	}
	out, ok := ctl.environment_block({0, 0}, false, {procedure = fail_allocation})
	defer delete(out)
	testing.expect(t, !ok)
}
