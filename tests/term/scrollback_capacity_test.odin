package term_test

import "aio:term"
import "core:fmt"
import "core:testing"

@(test)
scrollback_preserves_output_below_configured_capacity :: proc(t: ^testing.T) {
	widths := [?]u16{80, 100, 160, 240}
	for columns in widths {
		s, err := term.create_headless(replay_geometry(columns, 24), 10_000)
		if !testing.expect_value(t, err, term.Error.None) {return}
		defer term.destroy(s)
		for batch in 0..<20 {
			for line in 1..=500 {
				term.replay_write(s, transmute([]u8)fmt.tprintf("%d\r\n", batch * 500 + line))
			}
			bar, ok := term.scrollbar(s)
			testing.expect(t, ok)
			expected := u64((batch + 1) * 500 + 1)
			if !testing.expectf(t, bar.total >= expected,
				"%d columns: wrote %d rows, retained %d", columns, expected, bar.total) {
				break
			}
		}
		for line in 1..=6000 {
			term.replay_write(s, transmute([]u8)fmt.tprintf("overflow_%d\r\n", line))
		}
		bar, _ := term.scrollbar(s)
		// Pruning drops whole pages; allow one page around the requested limit after overflow.
		testing.expectf(t, bar.total >= 9400 && bar.total <= 10_600,
			"%d columns: limit 10000, retained %d after overflow", columns, bar.total)
	}
}

@(test)
scrollback_capacity_survives_reconfigure_resize_and_reset :: proc(t: ^testing.T) {
	s, err := term.create_headless(replay_geometry(100, 24), 1000)
	if !testing.expect_value(t, err, term.Error.None) {return}
	defer term.destroy(s)
	term.configure(s, 10_000, .Block, false)
	term.resize(s, replay_geometry(240, 24))
	for line in 1..=3000 {
		term.replay_write(s, transmute([]u8)fmt.tprintf("retained_%d\r\n", line))
	}
	bar, _ := term.scrollbar(s)
	testing.expect_value(t, bar.total, u64(3001))
	term.configure(s, 1000, .Block, false)
	bar, _ = term.scrollbar(s)
	testing.expectf(t, bar.total >= 400 && bar.total <= 1600,
		"lowering limit to 1000 retained %d rows", bar.total)
	term.configure(s, 10_000, .Block, false)
	term.replay_write(s, transmute([]u8)string("\x1bc"))
	for line in 1..=3000 {
		term.replay_write(s, transmute([]u8)fmt.tprintf("after_reset_%d\r\n", line))
	}
	bar, _ = term.scrollbar(s)
	testing.expect_value(t, bar.total, u64(3001))
}
