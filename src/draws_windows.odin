package main

import "aio:draws"
import "aio:render"
import "aio:verify_protocol"
import "core:fmt"
import "core:strings"

_ :: verify_protocol
_ :: draws
_ :: fmt
_ :: render
_ :: strings

// Draw-list evidence: report the selected window's last built frame in draw order.

when AIO_CONTROL {
	@(require_results)
	draws_read :: proc(
		app: ^App,
		out: ^strings.Builder,
		request: verify_protocol.Draws,
	) -> verify_protocol.Error {
		w := verify_window(app)
		if w == nil {return verify_protocol.explain(out, "window hidden; run tray open")}
		// draws.Kind mirrors verify_protocol.Draw_Kind, but map explicitly so a protocol reorder
		// fails here rather than silently relabelling the filter.
		kind: draws.Kind
		switch request.kind {
		case .All:
			kind = .All
		case .Rect:
			kind = .Rect
		case .Glyph:
			kind = .Glyph
		}
		filter := draws.Filter{kind = kind}
		if request.region.kind == .Pixels {
			region := render.Rect {
				x      = f32(request.region.x),
				y      = f32(request.region.y),
				width  = f32(request.region.width),
				height = f32(request.region.height),
			}
			if !draws.region_fits(region, int(w.width), int(w.height)) {
				return verify_protocol.explain(
					out,
					fmt.tprintf(
						"region %d,%d,%d,%d is outside the window client area %dx%d",
						request.region.x,
						request.region.y,
						request.region.width,
						request.region.height,
						w.width,
						w.height,
					),
				)
			}
			filter.bounded, filter.region = true, region
		}
		draws.format_report(out, &w.list, filter)
		return .None
	}
}
