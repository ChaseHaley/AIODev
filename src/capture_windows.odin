package main

import "aio:draws"
import "aio:pixels"
import "aio:render"
import "aio:verify_protocol"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

_ :: draws
_ :: pixels
_ :: render
_ :: verify_protocol
_ :: fmt
_ :: os
_ :: filepath
_ :: strings

// Pixel evidence: render the last built frame offscreen, then write or compare its pixels.
// The renderer lives in capture_windows.odin so the verification protocol stays free of graphics.

when AIO_CONTROL {
	// evidence_region resolves a request region to client pixels. Cells go through verify_grid, the
	// mapping mouse cells use, so an address selects exactly the pixels the grid drew for them.
	@(require_results)
	evidence_region :: proc(
		app: ^App,
		w: ^Window,
		region: verify_protocol.Region,
	) -> (
		pixels.Rect,
		string,
	) {
		switch region.kind {
		case .Window:
			return {0, 0, int(w.width), int(w.height)}, ""
		case .Pixels:
			requested := pixels.Rect{region.x, region.y, region.width, region.height}
			if !pixels.rect_within(int(w.width), int(w.height), requested) {
				return {}, fmt.tprintf(
					"region %d,%d,%d,%d exceeds the %dx%d client area",
					region.x,
					region.y,
					region.width,
					region.height,
					w.width,
					w.height,
				)
			}
			return requested, ""
		case .Cells:
			box, complaint := verify_grid(app, w)
			if complaint != "" {return {}, complaint}
			if region.x + region.width > int(box.columns) ||
			   region.y + region.height > int(box.rows) {
				return {}, fmt.tprintf(
					"cells %d,%d,%d,%d exceed the %dx%d focused pane",
					region.x,
					region.y,
					region.width,
					region.height,
					box.columns,
					box.rows,
				)
			}
			first := verify_cell_corner(w, box, region.x, region.y)
			last := verify_cell_corner(w, box, region.x + region.width, region.y + region.height)
			requested := pixels.Rect{first.x, first.y, last.x - first.x, last.y - first.y}
			if !pixels.rect_within(int(w.width), int(w.height), requested) {
				return {}, "the cell region falls outside the window; use --region"
			}
			return requested, ""
		}
		unreachable()
	}

	// evidence_frame renders the window's last built draw list into a fresh offscreen surface
	// and copies the requested region out as RGBA. It never presents, resizes, or dirties the
	// window, so collecting evidence cannot change what the user sees.
	@(require_results)
	evidence_frame :: proc(
		app: ^App,
		w: ^Window,
		region: verify_protocol.Region,
		out: ^strings.Builder,
	) -> (
		pixels.Image,
		verify_protocol.Error,
	) {
		requested, complaint := evidence_region(app, w, region)
		if complaint != "" {return {}, verify_protocol.explain(out, complaint)}
		if app.device == nil {
			return {}, verify_protocol.explain(out, "the graphics device is unavailable; restart the instance")
		}
		if window_minimized(w) {
			return {}, verify_protocol.explain(out, "the window has no drawable area; restore it and retry")
		}
		surface, surface_error := render.surface_create_offscreen(app.device, w.width, w.height)
		if surface_error != .None {
			return {}, verify_protocol.explain(
				out,
				fmt.tprintf(
					"cannot create an offscreen surface (%v); restart the instance",
					surface_error,
				),
			)
		}
		defer render.surface_destroy(surface)
		if render_error := render.frame_render(app.device, surface, &w.list, app.theme.window);
		   render_error != .None {
			return {}, verify_protocol.explain(
				out,
				fmt.tprintf(
					"cannot render the frame offscreen (%v); retry after the next frame",
					render_error,
				),
			)
		}
		readback, read_error := render.surface_read_pixels(app.device, surface, context.allocator)
		if read_error != .None {
			return {}, verify_protocol.explain(
				out,
				fmt.tprintf(
					"cannot read the offscreen frame back (%v); retry after the next frame",
					read_error,
				),
			)
		}
		defer delete(readback)
		image, image_error := pixels.image_from_bgra(readback, int(w.width), requested)
		if image_error == .Out_Of_Memory {return {}, .Out_Of_Memory}
		if image_error != .None {
			return {}, verify_protocol.explain(out, "the region does not fit the rendered frame")
		}
		return image, .None
	}

	@(require_results)
	capture_read :: proc(
		app: ^App,
		out: ^strings.Builder,
		request: verify_protocol.Capture,
	) -> verify_protocol.Error {
		w := verify_window(app)
		if w == nil {return verify_protocol.explain(out, "no window to capture; run tray open")}
		image, err := evidence_frame(app, w, request.region, out)
		if err != .None {return err}
		defer pixels.image_destroy(&image)
		path := request.output
		if path == "" {
			if app.paths.captures == "" {
				return verify_protocol.explain(out, "no data directory for the default capture; pass --out <file.png>")
			}
			directory := app.paths.captures
			if mkdir_error := os.mkdir_all(directory); mkdir_error != nil {
				return verify_protocol.explain(
					out,
					fmt.tprintf("cannot create %s (%v); pass --out <file.png>", directory, mkdir_error),
				)
			}
			joined, join_error := filepath.join({directory, "capture.png"})
			if join_error != nil {return .Out_Of_Memory}
			path = joined
		}
		if request.output != "" {
			// An explicit --out may point into a directory the caller has not created yet; the
			// default path above already owns its captures directory.
			directory := filepath.dir(path)
			if directory != "" && directory != "." {
				if mkdir_error := os.mkdir_all(directory); mkdir_error != nil {
					return verify_protocol.explain(
						out,
						fmt.tprintf("cannot create %s (%v); check the path", directory, mkdir_error),
					)
				}
			}
		}
		if pixels.png_write(path, image) != .None {
			return verify_protocol.explain(
				out,
				fmt.tprintf("cannot write %s; check the directory and permissions", path),
			)
		}
		fmt.sbprintf(out, "ok; capture %s %dx%d", path, image.width, image.height)
		return .None
	}

	@(require_results)
	pixels_read :: proc(
		app: ^App,
		out: ^strings.Builder,
		request: verify_protocol.Pixels,
	) -> verify_protocol.Error {
		w := verify_window(app)
		if w == nil {return verify_protocol.explain(out, "no window to read; run tray open")}
		image, err := evidence_frame(app, w, request.region, out)
		if err != .None {return err}
		defer pixels.image_destroy(&image)
		if request.sampled {
			color, sample_error := pixels.sample(image, request.sample.x, request.sample.y)
			if sample_error != .None {
				return verify_protocol.explain(
					out,
					fmt.tprintf(
						"sample %d,%d is outside the %dx%d region",
						request.sample.x,
						request.sample.y,
						image.width,
						image.height,
					),
				)
			}
			fmt.sbprintf(
				out,
				"sample %d,%d %s",
				request.sample.x,
				request.sample.y,
				draws.format_rgba8(color),
			)
			return .None
		}
		lines := request.columns ? image.width : image.height
		for index in 0 ..< lines {
			line, profile_error := pixels.profile(image, index, request.columns)
			if profile_error != .None {return .System}
			if index > 0 {fmt.sbprintf(out, "\n")}
			fmt.sbprintf(
				out,
				"%d coverage=%.3f colors=%d color=%s",
				index,
				line.coverage,
				line.colors,
				draws.format_rgba8(line.dominant),
			)
		}
		return .None
	}

	@(require_results)
	pixels_diff :: proc(
		app: ^App,
		out: ^strings.Builder,
		request: verify_protocol.Diff,
	) -> verify_protocol.Error {
		w := verify_window(app)
		if w == nil {return verify_protocol.explain(out, "no window to compare; run tray open")}
		baseline, read_error := pixels.png_read(request.baseline)
		if read_error != .None {
			if read_error == .Out_Of_Memory {return .Out_Of_Memory}
			if read_error == .Not_An_Image {
				return verify_protocol.explain(
					out,
					fmt.tprintf(
						"%s is not an 8-bit RGB or RGBA PNG; capture a new baseline",
						request.baseline,
					),
				)
			}
			return verify_protocol.explain(
				out,
				fmt.tprintf(
					"cannot read baseline %s; capture one with capture --out",
					request.baseline,
				),
			)
		}
		defer pixels.image_destroy(&baseline)
		current, err := evidence_frame(app, w, {kind = .Window}, out)
		if err != .None {return err}
		defer pixels.image_destroy(&current)
		result, diff_error := pixels.diff(baseline, current)
		if diff_error != .None {
			if diff_error == .Out_Of_Memory {return .Out_Of_Memory}
			if diff_error != .Size_Mismatch {return .System}
			return verify_protocol.explain(
				out,
				fmt.tprintf(
					"baseline is %dx%d but the window is %dx%d; capture a fresh baseline",
					baseline.width,
					baseline.height,
					current.width,
					current.height,
				),
			)
		}
		if result.changed == 0 {
			fmt.sbprintf(out, "diff unchanged")
			return .None
		}
		fmt.sbprintf(out, "diff changed=%d boxes=", result.changed)
		for box, i in result.boxes[:result.count] {
			if i > 0 {fmt.sbprintf(out, ";")}
			fmt.sbprintf(out, "%d,%d,%d,%d", box.x, box.y, box.width, box.height)
		}
		return .None
	}
}
