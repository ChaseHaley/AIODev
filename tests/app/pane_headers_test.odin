package app_test

import "core:fmt"
import "core:slice"
import "core:testing"
import app "../../src"
import "aio:layout"
import "aio:render"
import "aio:ui"

@(test)
pane_headers_in_a_float_keep_split_and_close_only :: proc(t: ^testing.T) {
	w := new(app.Window)
	defer free(w)
	w.scale, w.header_height = 1, 28
	tiled := layout.Pane_Rect{content = {.Terminal, 1}, rect = {0, 0, 480, 200}}
	floating := tiled
	floating.floating = true
	in_tile, in_float := app.pane_header_layout(w, tiled), app.pane_header_layout(w, floating)
	for button in app.Pane_Header_Button {
		testing.expectf(t, in_tile.buttons[button].width > 0, "a tiled header shows %v", button)
		kept := button == .Links || button == .Split_Right || button == .Split_Down || button == .Close
		testing.expectf(t, (in_float.buttons[button].width > 0) == kept, "a floating header and %v", button)
	}
}

// A header button's picture is the window as pressing the button leaves it: every pane where it ends up,
// and the chosen one where the button's pane, or the pane a split adds, lands. The pane is not focused yet,
// as pressing its header focuses it first.
@(test)
pane_header_previews_show_what_the_buttons_do :: proc(t: ^testing.T) {
	Case :: struct {
		button: app.Pane_Header_Button,
		action: app.Action,
	}
	cases := [?]Case {
		{.Split_Right, .Split_Right},
		{.Split_Down, .Split_Down},
		{.Zoom, .Zoom_Pane},
		{.Fill_Window, .Fill_Window_Pane},
		{.Dock, .Float_Pane},
		{.Linked_Window, .Linked_Window},
	}
	for c in cases {
		f: Palette_Fixture
		defer palette_fixture_destroy(t, &f)
		if !palette_fixture_create(t, &f, fmt.tprintf("header-preview-%v", c.button), second_window = false) {
			return
		}
		s, w := &f.state, f.state.windows[0]
		s.animations = false
		app.pane_split(s, w, .Right)
		if !testing.expect_value(t, len(w.panes), 2) {return}
		pane, other := w.panes[0], w.panes[1]
		card := app.pane_header_card(s, w, pane, c.button)
		preview, pictured := card.preview.?
		if !testing.expectf(t, pictured && card.description != "", "%v shows a picture", c.button) {continue}
		app.pane_focus(s, w, pane.node)
		app.run_action(s, w, c.action)
		if !testing.expectf(t, len(preview.panes) == len(w.panes), "%v: %d panes pictured, %d shown",
			c.button, len(preview.panes), len(w.panes)) {continue}
		for shown, i in w.panes {
			r := shown.rect
			testing.expectf(t, preview.panes[i] == render.Rect{r.x, r.y, r.width, r.height},
				"%v: pane %d pictured at %v, shown at %v", c.button, i, preview.panes[i], r)
		}
		switch c.button {
		case .Split_Right, .Split_Down:
			added := w.panes[preview.pane].content
			fresh := added != pane.content && added != other.content
			testing.expectf(t, fresh, "%v picks the new pane", c.button)
		case .Linked_Window:
			testing.expect_value(t, preview.pane, -1)
			testing.expect_value(t, preview.away, [2]f32{pane.rect.width, pane.rect.height})
		case .Links, .Zoom, .Fill_Window, .Dock, .Close:
			testing.expectf(t, w.panes[preview.pane].content == pane.content, "%v picks its pane", c.button)
		}
	}
}

// A button the window would refuse draws disabled, takes no press and says why in its tooltip card; it comes
// back once the refusal no longer holds.
@(test)
refused_header_buttons_are_disabled_and_say_why :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "header-refused", second_window = false) {return}
	s, w := &f.state, f.state.windows[0]
	s.animations = false
	if !testing.expect_value(t, len(w.panes), 1) {return}
	pane := w.panes[0]
	testing.expect_value(t, app.pane_header_refused(w, pane, .Dock), app.Pane_Header_Refusal.Last_Tiled)
	testing.expect_value(t, app.pane_header_refused(w, pane, .Linked_Window), app.Pane_Header_Refusal.Keeps_One)
	testing.expect_value(t, app.pane_header_refused(w, pane, .Split_Right), app.Pane_Header_Refusal.None)
	card := app.pane_header_card(s, w, pane, .Dock)
	testing.expect_value(t, card.description, app.PANE_HEADER_REFUSAL_TEXT[.Last_Tiled])
	testing.expect(t, card.preview == nil, "a refused button pictures nothing")
	notices := len(s.notices.items)
	gesture_click_header(s, w, .Dock, app.pane_header_layout(w, pane))
	gesture_click_header(s, w, .Linked_Window, app.pane_header_layout(w, pane))
	testing.expect_value(t, len(w.panes), 1)
	testing.expect(t, !w.panes[0].floating, "the disabled Float button floats nothing")
	testing.expect_value(t, len(s.windows), 1)
	testing.expect_value(t, len(s.notices.items), notices)

	// Too small to split: both split buttons are refused until the minimum allows them again.
	s.settings.pane.minimum_columns = 10_000
	app.window_relayout(s, w)
	testing.expect_value(t, app.pane_header_refused(w, pane, .Split_Right), app.Pane_Header_Refusal.Minimum)
	testing.expect_value(t, app.pane_header_refused(w, pane, .Split_Down), app.Pane_Header_Refusal.Minimum)
	gesture_click_header(s, w, .Split_Right, app.pane_header_layout(w, pane))
	testing.expect_value(t, len(w.panes), 1)
	s.settings.pane.minimum_columns = 0
	app.window_relayout(s, w)
	testing.expect_value(t, app.pane_header_refused(w, pane, .Split_Right), app.Pane_Header_Refusal.None)
	gesture_click_header(s, w, .Split_Right, app.pane_header_layout(w, pane))
	if !testing.expect_value(t, len(w.panes), 2) {return}
	// With a second tiled pane the first can float, and linking it leaves the other here.
	testing.expect_value(t, app.pane_header_refused(w, w.panes[0], .Dock), app.Pane_Header_Refusal.None)
	testing.expect_value(t, app.pane_header_refused(w, w.panes[0], .Linked_Window), app.Pane_Header_Refusal.None)
}

// The Settings pane's header shows the Settings icon the tab strip, rail and float capsules show,
// rather than a keycap.
@(test)
settings_pane_header_shows_the_settings_icon :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "settings-header", second_window = false) {return}
	s := &f.state
	w := app.editor_open(s, s.windows[0])
	if !testing.expect(t, w != nil) {return}
	app.window_render(s, w)
	pane: layout.Pane_Rect
	found := false
	for candidate in w.panes {
		if candidate.content.kind == .Settings {pane, found = candidate, true}
	}
	if !testing.expect(t, found, "the settings pane is laid out") {return}
	if !testing.expect(t, app.pane_header_row(w, pane), "the settings pane has a header") {return}
	badge := app.pane_header_layout(w, pane).badge
	area := render.Rect{0, 0, f32(w.width), f32(w.height)}
	render.draw_list_reset(&w.list)
	testing.expect_value(t, render.push_layer(&w.list, area), render.Error.None)
	testing.expect_value(t, app.pane_header_draw(s, w, pane, nil), render.Build_Status.Ok)
	for rect in w.list.rects {
		testing.expect(t, rect.rect != badge || rect.color != s.theme.selection, "no keycap behind the badge")
	}
	icon := render.draw_list_init()
	defer render.draw_list_destroy(&icon)
	testing.expect_value(t, render.push_layer(&icon, area), render.Error.None)
	ink := app.pane_shows_focus(w, pane) ? s.theme.text : s.theme.muted
	ui.icon_draw(&icon, .Settings, badge, ink, ui.ICON_BUTTON, w.scale)
	if !testing.expect(t, len(icon.rects) > 0) {return}
	drawn := false
	for start in 0 ..= len(w.list.rects) - len(icon.rects) {
		if slice.equal(w.list.rects[start:start + len(icon.rects)], icon.rects[:]) {drawn = true}
	}
	testing.expect(t, drawn, "the Settings icon is drawn in the badge")
}
