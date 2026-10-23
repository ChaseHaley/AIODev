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
}

@(require_results)
read_render_cell :: proc(cells: ghostty.Render_State_Row_Cells) -> Render_Cell {
	cell := Render_Cell {
		style = ghostty.sized(ghostty.Style),
		width = .Narrow,
	}
	if ghostty.render_state_row_cells_get(cells, .Raw, &cell.raw) == .Success {
		width: ghostty.Cell_Wide
		if ghostty.cell_get(cell.raw, .Wide, &width) == .Success {
			cell.width = width
		}
	}
	styled: bool
	if ghostty.render_state_row_cells_get(cells, .Has_Styling, &styled) == .Success && styled {
		if ghostty.render_state_row_cells_get(cells, .Style, &cell.style) != .Success {
			cell.style = ghostty.sized(ghostty.Style)
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
	return cell
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
			result :=
				ghostty.render_state_row_cells_get(cells, .Graphemes_Buf, raw_data(buffer^[start:]))
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
