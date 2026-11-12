package ui

import "core:math"
import "aio:render"

// Interface icons are line drawings on a 16-unit grid with one stroke weight at every size. The zero
// value is None, so an icon field left unset draws nothing.
Icon :: enum {
	None,
	Close,
	Add,
	Chevron_Down,
	Chevron_Right,
	Arrow_Up,
	Arrow_Down,
	Split_Right,
	Split_Down,
	Zoom,
	Restore,
	Expand,
	Collapse,
	Layout_Top,
	Layout_Left,
	Layout_Right,
	More,
	More_Vertical,
	Eye,
	Eye_Off,
	Grip,
	Copy,
	Trash,
	Undo,
	Check,
	Info,
	Warning,
	Error,
	Success,
	Command,
	Search,
	Grid,
	Settings,
	Workspace,
	Window_Out,
	Window_In,
	Float_Pane,
	Terminal,
	View_Comfy,
	View_Dense,
	Markdown,
	Document,
	Folder,
	Globe,
	Link,
	Minimize,
	Keyboard,
}

ICON_STROKE :: f32(1.25)
// The icon in an icon button, and an indicator beside text or inside a tab, row or field.
ICON_BUTTON :: f32(16)
ICON_INDICATOR :: f32(12)

@(private = "file")
Icon_Pen :: struct {
	list:   ^render.Draw_List,
	origin: [2]f32,
	unit:   f32,
	width:  f32,
	ink:    render.Color,
}

// Stroke edges land on whole pixels, so straight lines stay sharp at every scale.
@(private = "file")
pen_point :: proc(p: Icon_Pen, x, y: f32) -> [2]f32 {
	half := p.width / 2
	return {
		math.round(p.origin.x + x * p.unit - half) + half,
		math.round(p.origin.y + y * p.unit - half) + half,
	}
}

@(private = "file")
pen_path :: proc(p: Icon_Pen, points: ..[2]f32) {
	for i in 1 ..< len(points) {
		a, b := points[i - 1], points[i]
		_ = render.push_segment(p.list, pen_point(p, a.x, a.y), pen_point(p, b.x, b.y), p.width, p.ink)
	}
}

@(private = "file")
pen_box :: proc(p: Icon_Pen, x, y, w, h, radius: f32) {
	a, b := pen_point(p, x, y), pen_point(p, x + w, y + h)
	half := p.width / 2
	draw_rect(
		p.list,
		{
			rect = {a.x - half, a.y - half, b.x - a.x + p.width, b.y - a.y + p.width},
			color = p.ink,
			radius = radius * p.unit + half,
			stroke = p.width,
		},
	)
}

@(private = "file")
pen_arc :: proc(p: Icon_Pen, cx, cy, radius, start, sweep: f32) {
	center := p.origin + [2]f32{cx, cy} * p.unit
	_ = render.push_arc(p.list, center, radius * p.unit, start, sweep, p.width, p.ink)
}

@(private = "file")
pen_dot :: proc(p: Icon_Pen, x, y: f32) {
	d := max(2, math.round(2 * p.unit))
	c := p.origin + [2]f32{x, y} * p.unit
	r := render.Rect{math.round(c.x - d / 2), math.round(c.y - d / 2), d, d}
	draw_rect(p.list, {rect = r, color = p.ink, radius = d / 2})
}

// Draws `icon` centred in `area` at `size` DIPs.
icon_draw :: proc(
	list: ^render.Draw_List,
	icon: Icon,
	area: render.Rect,
	ink: render.Color,
	size, scale: f32,
) {
	extent := size * scale
	p := Icon_Pen {
		list   = list,
		origin = {
			math.round(area.x + (area.width - extent) / 2),
			math.round(area.y + (area.height - extent) / 2),
		},
		unit   = extent / 16,
		width  = ICON_STROKE * scale,
		ink    = ink,
	}
	switch icon {
	case .None:
	case .Keyboard:
		pen_box(p, 1, 3.5, 14, 9, 2)
		for x in ([?]f32{4, 6.67, 9.33, 12}) {pen_dot(p, x, 6.5)}
		pen_path(p, {5, 9.5}, {11, 9.5})
	case .Minimize:
		pen_path(p, {3, 12}, {13, 12})
	case .Float_Pane:
		pen_path(p, {5, 5}, {5, 3}, {13, 3}, {13, 11}, {11, 11})
		pen_box(p, 3, 5, 8, 8, 1)
	case .Markdown:
		pen_box(p, 1, 3, 14, 10, 2)
		pen_path(p, {3.5, 10.5}, {3.5, 5.5}, {6, 8}, {8.5, 5.5}, {8.5, 10.5})
		pen_path(p, {11.5, 5.5}, {11.5, 10.5})
		pen_path(p, {10, 9}, {11.5, 10.5}, {13, 9})
	case .Document:
		pen_path(p, {3, 2}, {10, 2}, {13, 5}, {13, 14}, {3, 14}, {3, 2})
	case .Folder:
		pen_path(p, {2, 3.5}, {6, 3.5}, {8, 5.5}, {14, 5.5}, {14, 13}, {2, 13}, {2, 3.5})
	case .Globe:
		pen_arc(p, 8, 8, 6.5, 0, 2 * math.PI)
		pen_path(p, {1.5, 8}, {14.5, 8})
		pen_path(p, {8, 1.5}, {5.5, 4.5}, {4.5, 8}, {5.5, 11.5}, {8, 14.5})
		pen_path(p, {8, 1.5}, {10.5, 4.5}, {11.5, 8}, {10.5, 11.5}, {8, 14.5})
	case .Link:
		// Two chain links along the rising diagonal, each a stadium overlapping the other.
		for side in ([?]f32{-1, 1}) {
			c := [2]f32{8 + side * 2.3, 8 - side * 2.3}
			a, r := f32(1.8), f32(2.5)
			u, v := [2]f32{0.7071, -0.7071} * a, [2]f32{0.7071, 0.7071} * r
			pen_path(p, c - u + v, c + u + v)
			pen_path(p, c - u - v, c + u - v)
			e1, e2 := c - u, c + u
			pen_arc(p, e2.x, e2.y, r, -3 * math.PI / 4, math.PI)
			pen_arc(p, e1.x, e1.y, r, math.PI / 4, math.PI)
		}
	case .Close:
		pen_path(p, {4, 4}, {12, 12})
		pen_path(p, {12, 4}, {4, 12})
	case .Add:
		pen_path(p, {8, 3}, {8, 13})
		pen_path(p, {3, 8}, {13, 8})
	case .Chevron_Down:
		pen_path(p, {4, 6}, {8, 10}, {12, 6})
	case .Chevron_Right:
		pen_path(p, {6, 4}, {10, 8}, {6, 12})
	case .Arrow_Up:
		pen_path(p, {8, 13}, {8, 3})
		pen_path(p, {4, 7}, {8, 3}, {12, 7})
	case .Arrow_Down:
		pen_path(p, {8, 3}, {8, 13})
		pen_path(p, {4, 9}, {8, 13}, {12, 9})
	case .Split_Right:
		pen_box(p, 2, 2, 12, 12, 2)
		pen_path(p, {8, 2}, {8, 14})
	case .Split_Down:
		pen_box(p, 2, 2, 12, 12, 2)
		pen_path(p, {2, 8}, {14, 8})
	case .Zoom:
		pen_path(p, {2, 6}, {2, 2}, {6, 2})
		pen_path(p, {10, 2}, {14, 2}, {14, 6})
		pen_path(p, {14, 10}, {14, 14}, {10, 14})
		pen_path(p, {6, 14}, {2, 14}, {2, 10})
	case .Restore:
		pen_path(p, {6, 2}, {6, 6}, {2, 6})
		pen_path(p, {10, 2}, {10, 6}, {14, 6})
		pen_path(p, {14, 10}, {10, 10}, {10, 14})
		pen_path(p, {2, 10}, {6, 10}, {6, 14})
	case .Expand:
		pen_path(p, {9, 7}, {14, 2})
		pen_path(p, {10, 2}, {14, 2}, {14, 6})
		pen_path(p, {7, 9}, {2, 14})
		pen_path(p, {2, 10}, {2, 14}, {6, 14})
	case .Collapse:
		pen_path(p, {14, 2}, {9, 7})
		pen_path(p, {9, 4}, {9, 7}, {12, 7})
		pen_path(p, {2, 14}, {7, 9})
		pen_path(p, {7, 12}, {7, 9}, {4, 9})
	case .Layout_Top:
		pen_box(p, 1, 2, 14, 12, 2)
		pen_path(p, {1, 6}, {15, 6})
	case .Layout_Left:
		pen_box(p, 1, 2, 14, 12, 2)
		pen_path(p, {6, 2}, {6, 14})
	case .Layout_Right:
		pen_box(p, 1, 2, 14, 12, 2)
		pen_path(p, {10, 2}, {10, 14})
	case .Terminal:
		pen_box(p, 1, 2, 14, 12, 2)
		pen_path(p, {4, 5}, {7, 8}, {4, 11})
		pen_path(p, {8.5, 11}, {12, 11})
	case .View_Comfy:
		pen_box(p, 2, 2, 12, 5, 1)
		pen_box(p, 2, 9, 12, 5, 1)
	case .View_Dense:
		for y in ([?]f32{3, 6.5, 10, 13.5}) {pen_path(p, {2, y}, {14, y})}
	case .More:
		for x in ([?]f32{3, 8, 13}) {pen_dot(p, x, 8)}
	case .More_Vertical:
		for y in ([?]f32{3, 8, 13}) {pen_dot(p, 8, y)}
	case .Eye, .Eye_Off:
		pen_path(p, {1, 8}, {4, 4.5}, {8, 3.5}, {12, 4.5}, {15, 8})
		pen_path(p, {1, 8}, {4, 11.5}, {8, 12.5}, {12, 11.5}, {15, 8})
		pen_arc(p, 8, 8, 2, 0, 2 * math.PI)
		if icon == .Eye_Off {pen_path(p, {2, 2}, {14, 14})}
	case .Grip:
		for y in ([?]f32{4, 8, 12}) {
			pen_dot(p, 6, y)
			pen_dot(p, 10, y)
		}
	case .Copy:
		pen_box(p, 5, 5, 9, 9, 2)
		pen_path(p, {2, 11}, {2, 2}, {11, 2})
	case .Trash:
		pen_path(p, {2, 4}, {14, 4})
		pen_path(p, {6, 4}, {6, 2}, {10, 2}, {10, 4})
		pen_path(p, {4, 4}, {4.5, 14}, {11.5, 14}, {12, 4})
	case .Undo:
		pen_path(p, {5.5, 2.5}, {2, 6}, {5.5, 9.5})
		pen_path(p, {2, 6}, {10, 6})
		pen_arc(p, 10, 9.5, 3.5, -math.PI / 2, math.PI)
		pen_path(p, {10, 13}, {7, 13})
	case .Window_Out:
		pen_path(p, {7, 2}, {2, 2}, {2, 14}, {14, 14}, {14, 9})
		pen_path(p, {8, 8}, {14, 2})
		pen_path(p, {10, 2}, {14, 2}, {14, 6})
	case .Window_In:
		pen_path(p, {7, 2}, {2, 2}, {2, 14}, {14, 14}, {14, 9})
		pen_path(p, {14, 2}, {8, 8})
		pen_path(p, {8, 4}, {8, 8}, {12, 8})
	case .Check:
		pen_path(p, {3, 8.5}, {6.5, 12}, {13, 4.5})
	case .Info:
		pen_arc(p, 8, 8, 6.5, 0, 2 * math.PI)
		pen_path(p, {8, 7.5}, {8, 11.5})
		pen_dot(p, 8, 5)
	case .Warning:
		pen_path(p, {8, 2}, {14.5, 13.5}, {1.5, 13.5}, {8, 2})
		pen_path(p, {8, 6.5}, {8, 9.5})
		pen_dot(p, 8, 11.5)
	case .Error:
		pen_arc(p, 8, 8, 6.5, 0, 2 * math.PI)
		pen_path(p, {5.5, 5.5}, {10.5, 10.5})
		pen_path(p, {10.5, 5.5}, {5.5, 10.5})
	case .Success:
		pen_arc(p, 8, 8, 6.5, 0, 2 * math.PI)
		pen_path(p, {5, 8.5}, {7, 10.5}, {11, 6})
	case .Command:
		pen_path(p, {3, 4}, {7, 8}, {3, 12})
		pen_path(p, {8.5, 12}, {13, 12})
	case .Search:
		pen_arc(p, 6.5, 6.5, 4.5, 0, 2 * math.PI)
		pen_path(p, {10, 10}, {14, 14})
	case .Grid:
		for y in ([?]f32{2, 9}) {
			for x in ([?]f32{2, 9}) {pen_box(p, x, y, 5, 5, 1)}
		}
	case .Settings:
		pen_path(p, {2, 4.5}, {8, 4.5})
		pen_arc(p, 10, 4.5, 2, 0, 2 * math.PI)
		pen_path(p, {12, 4.5}, {14, 4.5})
		pen_path(p, {2, 11.5}, {4, 11.5})
		pen_arc(p, 6, 11.5, 2, 0, 2 * math.PI)
		pen_path(p, {8, 11.5}, {14, 11.5})
	case .Workspace:
		pen_path(p, {8, 2}, {14, 5.5}, {8, 9}, {2, 5.5}, {8, 2})
		pen_path(p, {2, 9}, {8, 12.5}, {14, 9})
	}
}
