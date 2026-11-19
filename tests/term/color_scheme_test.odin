package term_test

import "aio:term"
import "core:testing"

DARK :: term.Colors {
	foreground = {0xc0, 0xca, 0xf5},
	background = {0x24, 0x28, 0x3b},
}
LIGHT :: term.Colors {
	foreground = {0x37, 0x60, 0xbf},
	background = {0xe1, 0xe2, 0xe7},
	light      = true,
}

@(private)
headless_session :: proc(t: ^testing.T) -> ^term.Session {
	s, err := term.create_headless(
		{columns = 80, rows = 24, cell_width = 8, cell_height = 16, surface_width = 640, surface_height = 384},
		100,
	)
	testing.expect_value(t, err, term.Error.None)
	return s
}

@(private)
queued :: proc(s: ^term.Session) -> string {
	text := string(s.queue.pending[:])
	return text
}

@(test)
color_scheme_is_reported_when_colors_change_under_mode_2031 :: proc(t: ^testing.T) {
	s := headless_session(t)
	if s == nil {return}
	defer term.destroy(s)
	term.set_colors(s, DARK)
	testing.expect_value(t, queued(s), "")
	enable := "\x1b[?2031h"
	term.replay_write(s, transmute([]u8)enable)
	term.set_colors(s, LIGHT)
	testing.expect_value(t, queued(s), "\x1b[?997;2n")
	clear(&s.queue.pending)
	term.set_colors(s, LIGHT)
	testing.expect_value(t, queued(s), "")
	term.set_colors(s, DARK)
	testing.expect_value(t, queued(s), "\x1b[?997;1n")
	clear(&s.queue.pending)
	disable := "\x1b[?2031l"
	term.replay_write(s, transmute([]u8)disable)
	term.set_colors(s, LIGHT)
	testing.expect_value(t, queued(s), "")
}

@(test)
color_scheme_reports_when_only_the_palette_changes :: proc(t: ^testing.T) {
	s := headless_session(t)
	if s == nil {return}
	defer term.destroy(s)
	term.set_colors(s, DARK)
	enable := "\x1b[?2031h"
	term.replay_write(s, transmute([]u8)enable)
	other := DARK
	other.palette[1] = {0xff, 0x00, 0x00}
	term.set_colors(s, other)
	testing.expect_value(t, queued(s), "\x1b[?997;1n")
}

@(test)
color_scheme_query_answers_with_the_current_scheme :: proc(t: ^testing.T) {
	s := headless_session(t)
	if s == nil {return}
	defer term.destroy(s)
	query := "\x1b[?996n"
	term.set_colors(s, LIGHT)
	term.replay_write(s, transmute([]u8)query)
	testing.expect_value(t, queued(s), "\x1b[?997;2n")
	clear(&s.queue.pending)
	term.set_colors(s, DARK)
	term.replay_write(s, transmute([]u8)query)
	testing.expect_value(t, queued(s), "\x1b[?997;1n")
}
