package term_view_test

import "core:testing"
import "aio:render"
import "aio:term"
import "aio:term_view"

// The hidden panes map's preview (D-089): each written cell is a bar in its text colour across the middle
// of the cell, over the background its cell carries, and a blank cell shows the terminal's background.
@(test)
blocks_draw_text_as_bars_over_cell_backgrounds :: proc(t: ^testing.T) {
	f, ok := fixture_create(t, text_command("$e + '[41mRR' + $e + '[0mA B' + $e + '[31mC' + $e + '[0m'"))
	defer fixture_destroy(&f)
	if !ok || !await_text(t, f.session, "RRA B") {return}
	g := term.geometry(f.session)
	area := render.Rect{0, 0, f32(g.surface_width), f32(g.surface_height)}
	cell := [2]f32{f.metrics.cell_width, f.metrics.cell_height}
	render.draw_list_reset(&f.list)
	testing.expect_value(t, render.push_layer(&f.list, area, 0), render.Error.None)
	grid := term_view.blocks_build(&f.view, f.session, &f.list, area, cell)
	testing.expect_value(t, grid, area)
	testing.expect_value(t, render.frame_render(f.device, f.surface, &f.list, {0, 0, 0, 1}), render.Error.None)
	pixels, err := render.surface_read_pixels(f.device, f.surface, context.temp_allocator)
	if !testing.expect_value(t, err, render.Error.None) {return}

	middle, edge := cell.y / 2, f32(1)
	white, black := [4]u8{255, 255, 255, 255}, [4]u8{0, 0, 0, 255}
	// Pixels read back as BGRA: palette red (200, 0, 0) reads {0, 0, 200}.
	red := [4]u8{0, 0, 200, 255}
	testing.expect_value(t, cell_pixel(&f, pixels, 0, 0, cell.x / 2, middle), white)
	testing.expect_value(t, cell_pixel(&f, pixels, 1, 0, cell.x / 2, edge), red)
	testing.expect_value(t, cell_pixel(&f, pixels, 2, 0, cell.x / 2, middle), white)
	testing.expect_value(t, cell_pixel(&f, pixels, 2, 0, cell.x / 2, edge), black)
	testing.expect_value(t, cell_pixel(&f, pixels, 3, 0, cell.x / 2, middle), black)
	testing.expect_value(t, cell_pixel(&f, pixels, 5, 0, cell.x / 2, middle), red)
	testing.expect_value(t, cell_pixel(&f, pixels, 10, 2, cell.x / 2, middle), black)
}
