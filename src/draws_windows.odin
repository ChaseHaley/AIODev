package main

import "aio:control"
import "aio:draws"
import "aio:render"
import "core:fmt"
import "core:strings"

_ :: control
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
		request: control.Draws,
	) -> control.Error {
		w := verify_window(app)
		if w == nil {
			fmt.sbprintf(out, "error: window hidden; run tray open")
			return .Invalid_Argument
		}
		// draws.Kind mirrors control.Draw_Kind so the adapter only has to relabel the value.
		filter := draws.Filter{kind = draws.Kind(request.kind)}
		if request.region.kind == .Pixels {
			region := render.Rect {
				x      = f32(request.region.x),
				y      = f32(request.region.y),
				width  = f32(request.region.width),
				height = f32(request.region.height),
			}
			if !draws.region_fits(region, int(w.width), int(w.height)) {
				fmt.sbprintf(
					out,
					"error: region %d,%d,%d,%d is outside the window client area %dx%d",
					request.region.x,
					request.region.y,
					request.region.width,
					request.region.height,
					w.width,
					w.height,
				)
				return .Invalid_Argument
			}
			filter.bounded, filter.region = true, region
		}
		draws.format_report(out, &w.list, filter)
		return .None
	}
}
