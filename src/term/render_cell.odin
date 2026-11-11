package term

import "aio:ghostty"
import "base:runtime"

// A render-state cell read through one field list. A property libghostty reports as absent
// falls back to its zero value: no style, narrow width, a zero raw cell and no colour.
Render_Cell :: struct {
	raw:                    ghostty.Cell,
	style:                  ghostty.Style,
	width:                  ghostty.Cell_Wide,
	foreground, background: Maybe(ghostty.Color_Rgb),
	// Set by read_render_cell_after only: the raw cell's content, style and codepoint, decoded.
	decoded:                bool,
	content:                ghostty.Cell_Content_Tag,
	style_id:               u16,
	codepoint:              u32,
}

@(require_results)
read_render_cell :: proc(cells: ghostty.Render_State_Row_Cells) -> Render_Cell {
	cell := Render_Cell {
		width = .Narrow,
	}
	if ghostty.render_state_row_cells_get(cells, .Raw, &cell.raw) == .Success {
		width: ghostty.Cell_Wide
		if ghostty.cell_get(cell.raw, .Wide, &width) == .Success {
			cell.width = width
		}
	}
	read_render_cell_colors(cells, &cell)
	return cell
}

// read_render_cell for the cells of a row in order, which also decodes the raw cell. A text cell in
// the same style as `previous` takes its style and colours from it: they follow from the style
// alone, and resolving them cost several calls into libghostty per cell.
@(require_results)
read_render_cell_after :: proc(
	cells: ghostty.Render_State_Row_Cells,
	previous: ^Render_Cell,
) -> Render_Cell {
	cell := Render_Cell {
		width = .Narrow,
	}
	if ghostty.render_state_row_cells_get(cells, .Raw, &cell.raw) != .Success {
		read_render_cell_colors(cells, &cell)
		return cell
	}
	// Wide comes first, so a failure leaves the width read or still narrow, as read_render_cell does.
	keys := [?]ghostty.Cell_Data{.Wide, .Content_Tag, .Style_Id, .Codepoint}
	values := [len(keys)]rawptr{&cell.width, &cell.content, &cell.style_id, &cell.codepoint}
	cell.decoded = ghostty.cell_get_multi(cell.raw, len(keys), &keys[0], &values[0], nil) == .Success
	if cell.decoded && previous != nil && previous.decoded && cell.content == .Codepoint &&
	   previous.content == .Codepoint && cell.style_id == previous.style_id {
		cell.style = previous.style
		cell.foreground, cell.background = previous.foreground, previous.background
		return cell
	}
	read_render_cell_colors(cells, &cell)
	return cell
}

@(private)
read_render_cell_colors :: proc(cells: ghostty.Render_State_Row_Cells, cell: ^Render_Cell) {
	styled: bool
	if ghostty.render_state_row_cells_get(cells, .Has_Styling, &styled) == .Success && styled {
		if ghostty.render_state_row_cells_get(cells, .Style, &cell.style) != .Success {
			cell.style = {}
		}
	}
	foreground: ghostty.Color_Rgb
	if ghostty.render_state_row_cells_get(cells, .Fg_Color, &foreground) == .Success {
		cell.foreground = foreground
	}
	background: ghostty.Color_Rgb
	if ghostty.render_state_row_cells_get(cells, .Bg_Color, &background) == .Success {
		cell.background = background
	}
}

// Appends the selected cell's grapheme cluster to buffer and returns the new span, as
// codepoints for a u32 buffer or UTF-8 for a u8 buffer. An unreadable cell, and a spacer
// half, has no text.
@(require_results)
render_cell_graphemes :: proc(
	cells: ghostty.Render_State_Row_Cells,
	width: ghostty.Cell_Wide,
	buffer: ^[dynamic]$T,
) -> (
	[]T,
	Error,
) {
	#assert(T == u32 || T == u8)
	if width == .Spacer_Tail || width == .Spacer_Head {
		return nil, .None
	}
	when T == u32 {
		count: u32
		if ghostty.render_state_row_cells_get(cells, .Graphemes_Len, &count) != .Success {
			return nil, .None
		}
		start := len(buffer)
		if uint(count) > uint(max(int) - start) {
			return nil, .Out_Of_Memory
		}
		if runtime.resize(buffer, start + int(count)) != nil {
			return nil, .Out_Of_Memory
		}
		if count > 0 {
			graphemes := ghostty.Codepoint_Buffer{raw_data(buffer^[start:]), uint(count), 0}
			result := ghostty.render_state_row_cells_get(cells, .Graphemes_Buf, &graphemes)
			if result != .Success {
				return nil, .Terminal_Failed
			}
		}
		return buffer^[start:start + int(count)], .None
	} else {
		measured: ghostty.Buffer
		result := ghostty.render_state_row_cells_get(cells, .Graphemes_Utf8, &measured)
		if result == .Success {
			return buffer^[len(buffer):len(buffer)], .None
		}
		if result != .Out_Of_Space {
			return nil, .None
		}
		start := len(buffer)
		if measured.len > uint(max(int) - start) {
			return nil, .Out_Of_Memory
		}
		if runtime.resize(buffer, start + int(measured.len)) != nil {
			return nil, .Out_Of_Memory
		}
		measured.ptr, measured.cap = raw_data(buffer^[start:]), measured.len
		if ghostty.render_state_row_cells_get(cells, .Graphemes_Utf8, &measured) != .Success {
			return nil, .Terminal_Failed
		}
		return buffer^[start:start + int(measured.len)], .None
	}
}
