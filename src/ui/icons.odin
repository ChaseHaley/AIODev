package ui

import "core:math"
import "aio:render"

// Interface icons are line drawings on a 16-unit grid with one stroke weight at every size.
Icon :: enum {
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
	Settings,
	Workspace,
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
	case .Layout_Top:
		pen_box(p, 1, 2, 14, 12, 2)
		pen_path(p, {1, 6}, {15, 6})
	case .Layout_Left:
		pen_box(p, 1, 2, 14, 12, 2)
		pen_path(p, {6, 2}, {6, 14})
	case .Layout_Right:
		pen_box(p, 1, 2, 14, 12, 2)
		pen_path(p, {10, 2}, {10, 14})
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
