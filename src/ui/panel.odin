package ui

import "aio:render"

// How a floating surface's border follows its rectangle.
Panel_Border :: enum {
	None,
	// A rectangle one scale larger than the surface, drawn behind it.
	Expanded,
	// A stroke on the surface's own rectangle, drawn over it.
	Stroked,
}

// The frame a floating surface draws before its content: shadow, border and surface. Offsets,
// softness and radius are in points at scale 1. The caller pushes its layer first and keeps its
// own content order, fade and clipping.
Panel :: struct {
	rect:     render.Rect,
	radius:   f32,
	scale:    f32,
	shadow_x: f32,
	shadow_y: f32,
	softness: f32,
	border:   Panel_Border,
}

panel_draw :: proc(list: ^render.Draw_List, panel: Panel, theme: Theme) -> render.Error {
	scale := panel.scale
	shadow := render.Rect_Instance {
		rect = {
			panel.rect.x + panel.shadow_x * scale,
			panel.rect.y + panel.shadow_y * scale,
			panel.rect.width,
			panel.rect.height,
		},
		color    = theme.shadow,
		radius   = panel.radius,
		softness = panel.softness * scale,
	}
	if render.push_rect(list, shadow) != .None {return .Out_Of_Memory}
	if panel.border == .Expanded {
		border := render.Rect_Instance {
			rect = {
				panel.rect.x - scale,
				panel.rect.y - scale,
				panel.rect.width + 2 * scale,
				panel.rect.height + 2 * scale,
			},
			color  = theme.border,
			radius = panel.radius + scale,
		}
		if render.push_rect(list, border) != .None {return .Out_Of_Memory}
	}
	surface := render.Rect_Instance {
		rect   = panel.rect,
		color  = theme.surface,
		radius = panel.radius,
	}
	if render.push_rect(list, surface) != .None {return .Out_Of_Memory}
	if panel.border == .Stroked {
		stroke := render.Rect_Instance {
			rect   = panel.rect,
			color  = theme.border,
			radius = panel.radius,
			stroke = scale,
		}
		if render.push_rect(list, stroke) != .None {return .Out_Of_Memory}
	}
	return .None
}
