package term

// Grid_Extent is a grid's pixel size and the padding left over on the surface's right and
// bottom edges. It is derived from the same Geometry as the cell conversions below.
Grid_Extent :: struct {
	width, height:                 u32,
	padding_right, padding_bottom: u32,
}

// grid_extent reports the grid's pixel size and the surface padding beyond its right and bottom
// edges. A grid larger than its surface reports no padding instead of wrapping around zero.
@(require_results)
grid_extent :: proc(g: Geometry) -> Grid_Extent {
	width := u32(g.columns) * g.cell_width
	height := u32(g.rows) * g.cell_height
	return {
		width = width,
		height = height,
		padding_right = g.surface_width - min(g.surface_width, g.padding_left + width),
		padding_bottom = g.surface_height - min(g.surface_height, g.padding_top + height),
	}
}

// cell_index places one surface axis coordinate in the grid. A cell owns the half-open interval
// from its own edge up to the next cell's edge, and the ratio truncates toward zero, so a point
// in the padding or beyond the grid clamps to the nearest cell and every surface point names a
// cell. The clamp lives here so the point and single-axis lookups cannot drift apart.
@(private, require_results)
cell_index :: proc(padding, cell: u32, value: f32, count: u16) -> int {
	return clamp(int((value - f32(padding)) / f32(cell)), 0, int(count) - 1)
}

// cell_column returns the viewport column containing surface x, clamped to the grid.
@(require_results)
cell_column :: proc(g: Geometry, x: f32) -> int {
	return cell_index(g.padding_left, g.cell_width, x, g.columns)
}

// cell_at returns the viewport cell containing the surface point, clamped to the grid.
@(require_results)
cell_at :: proc(g: Geometry, x, y: f32) -> (column, row: int) {
	column = cell_index(g.padding_left, g.cell_width, x, g.columns)
	row = cell_index(g.padding_top, g.cell_height, y, g.rows)
	return
}

// cell_center returns the surface pixel at the centre of a viewport cell, or false when the cell
// is outside the grid. This is the inverse of cell_at: the centre always maps back to its cell.
@(require_results)
cell_center :: proc(g: Geometry, column, row: int) -> (point: [2]i32, ok: bool) {
	if column < 0 || column >= int(g.columns) || row < 0 || row >= int(g.rows) {
		return {}, false
	}
	point = {
		i32(g.padding_left) + i32((f32(column) + 0.5) * f32(g.cell_width)),
		i32(g.padding_top) + i32((f32(row) + 0.5) * f32(g.cell_height)),
	}
	ok = true
	return
}
