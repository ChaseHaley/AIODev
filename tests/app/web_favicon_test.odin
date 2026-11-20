package app_test

import "core:os"
import "core:strings"
import "core:testing"
import app "../../src"
import "aio:layout"
import "aio:pixels"
import "aio:render"
import "aio:ui"

// A width x height PNG whose pixels are all opaque `colour`, written and read back through
// pixels.png_write; the caller deletes it.
@(private = "file")
solid_png :: proc(t: ^testing.T, width, height: int, colour: [4]u8) -> (bytes: []u8, ok: bool) {
	data := make([]u8, width * height * 4)
	defer delete(data)
	pixel := colour
	for i in 0 ..< width * height {copy(data[i * 4:][:4], pixel[:])}
	directory, directory_error := os.make_directory_temp("", "aio-favicon-*", context.allocator)
	if !testing.expect_value(t, directory_error, nil) {return}
	defer delete(directory)
	defer os.remove(directory)
	path := strings.concatenate({directory, "/favicon.png"})
	defer delete(path)
	defer os.remove(path)
	image := pixels.Image{width, height, width * 4, data}
	if !testing.expect_value(t, pixels.png_write(path, image), pixels.Error.None) {return}
	read_error: os.Error
	bytes, read_error = os.read_entire_file(path, context.allocator)
	return bytes, testing.expect_value(t, read_error, nil)
}

@(test)
web_favicon_keeps_a_small_png_as_it_is_and_empty_bytes_clear_it :: proc(t: ^testing.T) {
	state: app.App
	favicon: app.Web_Favicon
	defer app.web_favicon_destroy(&favicon)

	testing.expect(t, app.web_favicon_set(&state, &favicon, png_icon[:]))
	testing.expect_value(t, favicon.width, 2)
	testing.expect_value(t, favicon.height, 2)
	testing.expect_value(t, len(favicon.pixels), 2 * 2 * 4)

	testing.expect(t, app.web_favicon_set(&state, &favicon, nil), "empty bytes clear without failing")
	testing.expect_value(t, favicon.width, 0)
	testing.expect_value(t, len(favicon.pixels), 0)

	testing.expect(t, app.web_favicon_set(&state, &favicon, png_icon[:]))
	testing.expect(t, app.web_favicon_set(&state, &favicon, png_icon[:]), "a second favicon replaces the first")
	testing.expect_value(t, len(favicon.pixels), 2 * 2 * 4)
}

@(test)
web_favicon_averages_a_large_png_down_and_keeps_its_aspect :: proc(t: ^testing.T) {
	state: app.App
	favicon: app.Web_Favicon
	defer app.web_favicon_destroy(&favicon)
	bytes, ok := solid_png(t, 128, 64, {200, 100, 50, 255})
	if !ok {return}
	defer delete(bytes)

	testing.expect(t, app.web_favicon_set(&state, &favicon, bytes))
	testing.expect_value(t, favicon.width, 32)
	testing.expect_value(t, favicon.height, 16)
	if !testing.expect_value(t, len(favicon.pixels), 32 * 16 * 4) {return}
	testing.expect_value(t, [4]u8{favicon.pixels[0], favicon.pixels[1], favicon.pixels[2], favicon.pixels[3]}, [4]u8{200, 100, 50, 255})
	last := favicon.pixels[len(favicon.pixels) - 4:]
	testing.expect_value(t, [4]u8{last[0], last[1], last[2], last[3]}, [4]u8{200, 100, 50, 255})
}

@(test)
web_favicon_refuses_bytes_that_are_not_a_png_icon_and_drops_the_previous_icon :: proc(t: ^testing.T) {
	state: app.App
	favicon: app.Web_Favicon
	defer app.web_favicon_destroy(&favicon)
	testing.expect(t, app.web_favicon_set(&state, &favicon, png_icon[:]))

	garbage := [?]u8{1, 2, 3, 4, 5, 6, 7, 8}
	testing.expect(t, !app.web_favicon_set(&state, &favicon, garbage[:]))
	testing.expect_value(t, favicon.width, 0)

	testing.expect(t, app.web_favicon_set(&state, &favicon, png_icon[:]))
	oversized := make([]u8, app.WEB_FAVICON_MAX_BYTES + 1)
	defer delete(oversized)
	copy(oversized, png_icon[:])
	testing.expect(t, !app.web_favicon_set(&state, &favicon, oversized), "a favicon past the byte cap is refused")
	testing.expect_value(t, favicon.width, 0)
	testing.expect_value(t, len(favicon.pixels), 0)
}

@(test)
web_pane_badge_is_its_favicon_in_colour_else_the_globe :: proc(t: ^testing.T) {
	state: app.App
	device, device_error := render.device_create(.Warp)
	if !testing.expect_value(t, device_error, render.Error.None) {return}
	defer render.device_destroy(device)
	state.device = device
	defer app.web_app_destroy(&state.web_state)
	pane := app.web_pane_create(&state, "https://example.com/")
	if !testing.expect(t, pane != nil) {return}
	content := layout.Content{.Web, pane.id}

	badge, result := app.content_badge(&state, nil, content, 16)
	testing.expect_value(t, result, render.Build_Status.Ok)
	testing.expect_value(t, badge.icon, ui.Icon.Globe)
	testing.expect_value(t, badge.atlas.width, 0)

	testing.expect(t, app.web_favicon_set(&state, &pane.favicon, png_icon[:]))
	badge, result = app.content_badge(&state, nil, content, 16)
	testing.expect_value(t, result, render.Build_Status.Ok)
	testing.expect_value(t, badge.icon, ui.Icon.None)
	testing.expect_value(t, badge.glyph, "")
	testing.expect_value(t, badge.atlas.width, 2)
	testing.expect_value(t, badge.atlas.height, 2)

	testing.expect(t, app.web_favicon_set(&state, &pane.favicon, nil))
	badge, result = app.content_badge(&state, nil, content, 16)
	testing.expect_value(t, result, render.Build_Status.Ok)
	testing.expect_value(t, badge.icon, ui.Icon.Globe)
	testing.expect_value(t, badge.atlas.width, 0)

	// A web page that has closed, or content that is not a web page, falls back to its kind's icon.
	badge, _ = app.content_badge(&state, nil, {.Web, pane.id + 1}, 16)
	testing.expect_value(t, badge.icon, ui.Icon.Globe)
	badge, _ = app.content_badge(&state, nil, {.Markdown, 0}, 16)
	testing.expect_value(t, badge.icon, ui.Icon.Markdown)
}
