package term_test

import "aio:input"
import "aio:term"
import "core:testing"

@(test)
mouse_motion_reports_the_held_button_instead_of_hover :: proc(t: ^testing.T) {
	s, err := term.create_headless({columns = 80, rows = 24, cell_width = 8, cell_height = 16,
		surface_width = 640, surface_height = 384}, 100)
	if !testing.expect_value(t, err, term.Error.None) {return}
	defer term.destroy(s)
	initial := "\x1b[?1003h\x1b[?1006h"
	term.replay_write(s, transmute([]u8)initial)
	for button, index in ([?]input.Mouse_Button{.Left, .Middle, .Right}) {
		clear(&s.queue.pending)
		term.send_mouse(s, .Motion, nil, {button}, {}, 28, 24)
		expected := [?]string{"\x1b[<32;4;2M", "\x1b[<33;4;2M", "\x1b[<34;4;2M"}
		testing.expect_value(t, string(s.queue.pending[:]), expected[index])
	}
	clear(&s.queue.pending)
	term.send_mouse(s, .Motion, nil, {}, {}, 36, 24)
	testing.expect_value(t, string(s.queue.pending[:]), "\x1b[<35;5;2M")
	clear(&s.queue.pending)
	term.send_mouse(s, .Motion, nil, {.Left}, {.Control}, 44, 24)
	testing.expect_value(t, string(s.queue.pending[:]), "\x1b[<48;6;2M")
}
