package app_test

import "core:testing"
import app "../../src"
import "aio:layout"

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
