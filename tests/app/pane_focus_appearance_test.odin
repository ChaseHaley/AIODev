package app_test

import "core:strings"
import "core:testing"
import app "../../src"
import "aio:platform"
import "aio:render"

@(test)
pane_focus_appearance_follows_keyboard_focus_across_windows :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "pane-focus-appearance") {return}
	s := &f.state
	first, second := s.windows[0], s.windows[1]
	app.pane_split(s, first, .Right)
	app.pane_split(s, second, .Right)
	s.settings.pane.focus_border = 4
	s.settings.pane.unfocused_dim = 45
	for &entry in s.sessions {delete(entry.name); entry.name = strings.clone("Focus")}
	first_node, second_node := app.window_tree(first).focus, app.window_tree(second).focus
	for gap in ([?]int{0, 4}) {
		s.settings.pane.gap = gap
		app.window_relayout(s, first)
		app.window_relayout(s, second)
		for active in ([?]^app.Window{first, second, nil, first}) {
			for w in ([?]^app.Window{first, second}) {
				app.handle_event(s, platform.Focus_Event{w.id, false})
			}
			if active != nil {app.handle_event(s, platform.Focus_Event{active.id, true})}
			for w in ([?]^app.Window{first, second}) {
				if !testing.expect(t, app.window_build_frame(s, w)) {return}
				focus_outlines := 0
				for rect in w.list.rects {
					if rect.color == s.theme.pane_focus && rect.stroke > 0 {focus_outlines += 1}
				}
				testing.expect_value(t, focus_outlines, w == active ? 1 : 0)
				for pane in w.panes {
					focused := w == active && pane.node == app.window_tree(w).focus
					r := render.Rect{pane.rect.x, pane.rect.y, pane.rect.width, pane.rect.height}
					dimmed := false
					for rect in w.list.rects {
						if rect.rect == r && rect.color.a == 0.45 && rect.stroke == 0 {dimmed = true}
					}
					testing.expect_value(t, dimmed, !focused)
					header := app.pane_header_layout(w, pane)
					title_ink := focused ? s.theme.text : s.theme.muted
					title_found := false
					for glyph in w.list.glyphs {
						if glyph.rect.x >= header.title.x &&
						   glyph.rect.x < header.title.x + header.title.width &&
						   glyph.rect.y >= header.title.y &&
						   glyph.rect.y < header.title.y + header.title.height {
							title_found = true
							testing.expect_value(t, glyph.color, title_ink)
						}
					}
					testing.expect(t, title_found)
				}
			}
			testing.expect_value(t, app.window_tree(first).focus, first_node)
			testing.expect_value(t, app.window_tree(second).focus, second_node)
		}
	}
}
