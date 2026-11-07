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
