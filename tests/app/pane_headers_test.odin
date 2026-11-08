package app_test

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
		kept := button == .Documents || button == .Split_Right || button == .Split_Down || button == .Close
		testing.expectf(t, (in_float.buttons[button].width > 0) == kept, "a floating header and %v", button)
	}
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
