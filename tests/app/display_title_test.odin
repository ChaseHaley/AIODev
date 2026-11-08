package app_test

import "core:strings"
import "core:testing"
import app "../../src"

@(test)
display_titles_strip_controls_and_cap_at_a_complete_utf8_rune :: proc(t: ^testing.T) {
	title := app.display_title("hello\n\t\x7f\u0085world 🧪")
	defer delete(title)
	testing.expect_value(t, title, "helloworld 🧪")
	long := strings.repeat("🧪", 300, context.temp_allocator)
	capped := app.display_title(long)
	defer delete(capped)
	testing.expect_value(t, len(capped), 1024)
}

@(test)
printable_text_keeps_display_replacements_but_not_terminal_command_replacements :: proc(t: ^testing.T) {
	raw := "a\x00\t\x1f\x7f\u0085\u009f\ufffd\xffb"
	title := app.display_title(raw)
	defer delete(title)
	command := app.printable_command(raw)
	defer delete(command)
	testing.expect_value(t, title, "a\ufffd\ufffdb")
	testing.expect_value(t, command, "ab")
	for limit in ([?]int{0, 1, 3, 4, 5}) {
		text := app.printable_text("🧪x", limit)
		defer delete(text)
		want := limit < 4 ? "" : (limit == 4 ? "🧪" : "🧪x")
		testing.expect_value(t, text, want)
	}
}
