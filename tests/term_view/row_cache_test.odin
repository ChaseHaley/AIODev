package term_view_test

import "core:testing"
import "aio:render"
import "aio:term"
import "aio:term_view"

// Builds the screen into `list` with `view`.
@(private = "file")
build_into :: proc(
	t: ^testing.T,
	f: ^Fixture,
	view: ^term_view.View,
	list: ^render.Draw_List,
	origin: [2]f32,
) {
	for _ in 0 ..< 2 {
		render.draw_list_reset(list)
		testing.expect_value(t, render.push_layer(list, {0, 0, 2000, 2000}), render.Error.None)
		_, result := term_view.build(view, f.session, f.fonts, &f.cache, list, origin, f.metrics, {family = f.family})
		if result == .Ok {break}
	}
}

// Builds the screen with f.view, which keeps its row cache across builds, and with a view that has
// never drawn before.
@(private = "file")
build_twice :: proc(t: ^testing.T, f: ^Fixture, out: ^render.Draw_List, origin := [2]f32{0, 0}) {
	build_into(t, f, &f.view, &f.list, origin)
	fresh: term_view.View
	if !testing.expect(t, term_view.create(&fresh)) {return}
	defer term_view.destroy(&fresh)
	build_into(t, f, &fresh, out, origin)
}

@(private = "file")
expect_same_draws :: proc(t: ^testing.T, cached, fresh: ^render.Draw_List) {
	testing.expect_value(t, len(cached.rects), len(fresh.rects))
	testing.expect_value(t, len(cached.glyphs), len(fresh.glyphs))
	for r, i in cached.rects {
		if i >= len(fresh.rects) {break}
		testing.expectf(t, r == fresh.rects[i], "rect %d: %v cached, %v fresh", i, r, fresh.rects[i])
	}
	for g, i in cached.glyphs {
		if i >= len(fresh.glyphs) {break}
		testing.expectf(t, g == fresh.glyphs[i], "glyph %d: %v cached, %v fresh", i, g, fresh.glyphs[i])
	}
	testing.expect_value(t, len(cached.layers), len(fresh.layers))
	for layer, i in cached.layers {
		if i >= len(fresh.layers) {break}
		testing.expect_value(t, layer, fresh.layers[i])
	}
}

// Rows the cache replays draw exactly what drawing them afresh does, after output scrolls the screen,
// rewrites a row in place, restyles text and selects some of it.
@(test)
row_cache_draws_what_a_fresh_build_draws :: proc(t: ^testing.T) {
	f, ok := headless_create(t, rows = 6)
	defer fixture_destroy(&f)
	if !ok {return}
	out := render.draw_list_init()
	defer render.draw_list_destroy(&out)

	steps := [?]string {
		"plain text\r\n\x1b[1mbold\x1b[0m \x1b[31mred\x1b[0m \x1b[4munder\x1b[24m\r\n" +
		"\x1b[44;33mcolored\x1b[0m row\r\nwide \u4e00\u4e01 cells\r\n",
		// Scroll by two rows: the cached rows move up.
		"next one\r\nnext two\r\n",
		// Rewrite the second row in place, in another style.
		"\x1b[2;1H\x1b[32mrewritten\x1b[0m\x1b[6;1H",
		// The same text in a new background on the third row.
		"\x1b[3;1H\x1b[45mcolored\x1b[0m row\x1b[6;1H",
		// The second row's text again, in yellow: only the style changes.
		"\x1b[2;1H\x1b[33mrewritten\x1b[0m\x1b[6;1H",
		"\r\nlast line\r\n",
	}
	for step, i in steps {
		term.replay_write(f.session, transmute([]u8)step)
		build_twice(t, &f, &out)
		expect_same_draws(t, &f.list, &out)
		// Scrolling by two rows leaves rows the cache can move.
		if i == 1 {testing.expect(t, term_view.row_cache_replays(&f.view) > 0)}
		if i == 2 {
			// A selection over cached rows repaints them.
			term.select_all(f.session)
			build_twice(t, &f, &out)
			expect_same_draws(t, &f.list, &out)
			term.clear_selection(f.session)
			// Rows drawn selected repaint without it, though no output rebuilt them.
			build_twice(t, &f, &out)
			expect_same_draws(t, &f.list, &out)
		}
	}
	// New default colours repaint every row, styled or not.
	term.set_colors(f.session, {foreground = {10, 200, 10}, background = {20, 20, 60}, cursor = {0, 255, 0}})
	build_twice(t, &f, &out)
	expect_same_draws(t, &f.list, &out)
	// Plain rows that scroll come back by their raw cells.
	term.replay_write(f.session, transmute([]u8)string("\r\nplain a\r\nplain b\r\nplain c\r\n"))
	build_twice(t, &f, &out)
	term.replay_write(f.session, transmute([]u8)string("plain d\r\n"))
	build_twice(t, &f, &out)
	expect_same_draws(t, &f.list, &out)
	// Drawing the unchanged screen again replays every row but the cursor's.
	before := term_view.row_cache_replays(&f.view)
	build_twice(t, &f, &out)
	expect_same_draws(t, &f.list, &out)
	testing.expect_value(t, term_view.row_cache_replays(&f.view) - before, 5)
}

// A resize rewraps the screen into rows with new ids. Rows whose content came out the same draw from
// the cache, plain or styled, as do the rows of a pane that moved; all draw what drawing them afresh
// does.
@(test)
row_cache_follows_content_across_resizes_and_moves :: proc(t: ^testing.T) {
	f, ok := headless_create(t, rows = 6)
	defer fixture_destroy(&f)
	if !ok {return}
	out := render.draw_list_init()
	defer render.draw_list_destroy(&out)
	text := "short\r\n\x1b[31mred short\x1b[0m\r\n" + "a line longer than twenty columns wraps\r\nlast"
	term.replay_write(f.session, transmute([]u8)text)
	build_twice(t, &f, &out)
	g := term.geometry(f.session)
	g.columns -= 3
	term.resize(f.session, g)
	before := term_view.row_cache_replays(&f.view)
	build_twice(t, &f, &out)
	expect_same_draws(t, &f.list, &out)
	testing.expect(t, term_view.row_cache_replays(&f.view) - before >= 2, "the short rows replay")
	before = term_view.row_cache_replays(&f.view)
	build_twice(t, &f, &out, {7, 3})
	expect_same_draws(t, &f.list, &out)
	testing.expect_value(t, term_view.row_cache_replays(&f.view) - before, 5)
}
