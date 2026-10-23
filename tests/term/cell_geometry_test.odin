package term_test

import "aio:term"
import "core:testing"

// A geometry with an odd cell size so the centre rounding and the half-open cell edges cannot
// pass by coincidence.
@(private)
CELL_TEST_GEOMETRY :: term.Geometry {
	columns = 80,
	rows = 24,
	cell_width = 9,
	cell_height = 17,
	surface_width = 800,
	surface_height = 500,
	padding_left = 4,
	padding_top = 5,
}

@(test)
cell_at_places_points_and_clamps_to_the_grid :: proc(t: ^testing.T) {
	g := CELL_TEST_GEOMETRY
	column, row := term.cell_at(g, 4, 5)
	testing.expect_value(t, column, 0)
	testing.expect_value(t, row, 0)
	column, row = term.cell_at(g, 4 + 9 * 7 + 8, 5 + 17 * 3 + 16)
	testing.expect_value(t, column, 7)
	testing.expect_value(t, row, 3)
	column, row = term.cell_at(g, -100, -100)
	testing.expect_value(t, column, 0)
	testing.expect_value(t, row, 0)
	column, row = term.cell_at(g, 100_000, 100_000)
	testing.expect_value(t, column, 79)
	testing.expect_value(t, row, 23)
	testing.expect_value(t, term.cell_column(g, 4 + 9 * 12 + 4), 12)
}

// The centre of cell `(column, row)` is the midpoint of its half-open pixel interval, so the
// forward conversion must map it back to that cell.
@(test)
cell_center_returns_the_cell_midpoint_and_rejects_outside_cells :: proc(t: ^testing.T) {
	g := CELL_TEST_GEOMETRY
	point, ok := term.cell_center(g, 0, 0)
	testing.expect(t, ok)
	testing.expect_value(t, point, [2]i32{8, 13})
	point, ok = term.cell_center(g, 7, 3)
	testing.expect(t, ok)
	testing.expect_value(t, point, [2]i32{71, 64})
	point, ok = term.cell_center(g, 79, 23)
	testing.expect(t, ok)
	testing.expect_value(t, point, [2]i32{4 + 79 * 9 + 4, 5 + 23 * 17 + 8})
	_, ok = term.cell_center(g, -1, 0)
	testing.expect(t, !ok)
	_, ok = term.cell_center(g, 0, -1)
	testing.expect(t, !ok)
	_, ok = term.cell_center(g, 80, 0)
	testing.expect(t, !ok)
	_, ok = term.cell_center(g, 0, 24)
	testing.expect(t, !ok)
}

// A cell edge belongs to the cell that starts there; the inverse centre of that cell and the
// forward conversion at its edges must therefore agree across the whole grid.
@(test)
cell_at_and_cell_center_agree_at_cell_edges :: proc(t: ^testing.T) {
	g := CELL_TEST_GEOMETRY
	columns, rows := int(g.columns), int(g.rows)
	for column in 0 ..< columns {
		left := f32(g.padding_left) + f32(column) * f32(g.cell_width)
		testing.expect_value(t, term.cell_column(g, left), column)
		for row in 0 ..< rows {
			point, ok := term.cell_center(g, column, row)
			if !testing.expect(t, ok) {return}
			got_column, got_row := term.cell_at(g, f32(point.x), f32(point.y))
			testing.expect_value(t, got_column, column)
			testing.expect_value(t, got_row, row)
		}
	}
	for row in 0 ..< rows {
		top := f32(g.padding_top) + f32(row) * f32(g.cell_height)
		_, got_row := term.cell_at(g, 0, top)
		testing.expect_value(t, got_row, row)
	}
	last_column := f32(g.padding_left) + f32(g.columns) * f32(g.cell_width)
	testing.expect_value(t, term.cell_column(g, last_column), columns - 1)
	last_row := f32(g.padding_top) + f32(g.rows) * f32(g.cell_height)
	_, got_row := term.cell_at(g, 0, last_row)
	testing.expect_value(t, got_row, rows - 1)
}

@(test)
grid_extent_reports_the_grid_and_the_remaining_padding :: proc(t: ^testing.T) {
	g := CELL_TEST_GEOMETRY
	extent := term.grid_extent(g)
	testing.expect_value(t, extent.width, 720)
	testing.expect_value(t, extent.height, 408)
	testing.expect_value(t, extent.padding_right, 76)
	testing.expect_value(t, extent.padding_bottom, 87)
	// A grid larger than its surface reports no trailing padding instead of wrapping around zero.
	small := g
	small.surface_width, small.surface_height = 100, 20
	extent = term.grid_extent(small)
	testing.expect_value(t, extent.width, 720)
	testing.expect_value(t, extent.padding_right, 0)
	testing.expect_value(t, extent.padding_bottom, 0)
}
