package term_test

import "core:testing"
import "core:unicode/utf8"
import "aio:ghostty"
import "aio:term"
import fixtures "../fixtures"

@(test)
unicode_survives_conpty :: proc(t: ^testing.T) {
	cases, err := fixtures.unicode_cases()
	defer fixtures.unicode_cases_destroy(cases)
	if !testing.expect_value(t, err, "") { return }
	cfg := config("pwsh.exe -NoLogo -NoProfile -File \"" + #directory + "/unicode_output.ps1\"")
	cfg.geometry.rows = u16(len(cases) + 3)
	s, session_error := term.create(cfg, {})
	if !testing.expect_value(t, session_error, term.Error.None) { return }
	defer term.destroy(s)
	if !await(t, s, shows, "UNICODE_COMPLETE") { return }
	state: ghostty.Render_State
	if !testing.expect_value(t, ghostty.render_state_new(nil, &state), ghostty.Result.Success) { return }
	defer ghostty.render_state_free(state)
	if !testing.expect(t, term.capture(s, state)) { return }
	snapshot, snapshot_error := term.snapshot(state)
	defer term.snapshot_destroy(&snapshot)
	if !testing.expect_value(t, snapshot_error, term.Error.None) { return }
	highlights: [dynamic]term.Highlight
	defer delete(highlights)
	for c, row in cases {
		input := c.conpty != nil ? c.conpty : c.input
		g, ok := unicode_grid(t, input)
		if !ok { return }
		defer unicode_grid_destroy(&g)
		columns := cursor_x(&g)
		for x in 0..<columns {
			expected := term.snapshot_cell(&g.snapshot, x, 0)
			observed := term.snapshot_cell(&snapshot, x, row)
			testing.expectf(t, observed.text == expected.text && observed.width == expected.width,
				"%s at %d: ConPTY %q/%v, expected %q/%v", c.id, x,
				observed.text, observed.width, expected.text, expected.width)
		}
		testing.expectf(t, term.snapshot_cell(&snapshot, columns, row).text == "!",
			"%s: ConPTY changed cursor advance", c.id)
		text := utf8.runes_to_string(c.stored)
		defer delete(text)
		expected_text := c.conpty != nil ? string(c.conpty) : text
		x := f32(columns) * f32(cfg.geometry.cell_width)
		y := (f32(row) + 0.5) * f32(cfg.geometry.cell_height)
		term.clear_selection(s)
		term.selection_press(s, 1, y, i64(row + 1) * 1_000_000_000)
		term.selection_drag(s, x + 1, y)
		term.selection_release(s, x + 1, y)
		copied, selected := term.selection_text(s)
		defer delete(copied)
		testing.expectf(t, selected && copied == expected_text, "%s: selection copied %q", c.id, copied)
		term.search_set_needle(s, expected_text)
		summary := settle_search(t, s)
		testing.expectf(t, summary.total > 0, "%s: search found no match for %q", c.id, text)
		if !testing.expect(t, term.capture(s, state, &highlights)) { return }
		found := false
		for h in highlights {
			if h.row == row && h.first == 0 && h.last == columns - 1 { found = true }
		}
		testing.expectf(t, found, "%s: search did not highlight the entire cell span: %v", c.id, highlights[:])
	}
}
