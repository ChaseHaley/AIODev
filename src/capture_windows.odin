package main

import "aio:control"
import "aio:layout"
import "aio:pixels"
import "aio:render"
import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"

_ :: control
_ :: layout
_ :: pixels
_ :: render
_ :: fmt
_ :: math
_ :: os
_ :: filepath
_ :: strings

// Pixel evidence: render the last built frame offscreen, then write or compare its pixels.
// The renderer lives in capture_windows.odin so the control protocol stays free of graphics.

when AIO_CONTROL {
	// evidence_error writes the client-facing explanation. verify_read forwards a reply that
	// starts with "error: " verbatim, so every failure here names the next step.
	@(require_results)
	evidence_error :: proc(out: ^strings.Builder, text: string) -> control.Error {
		fmt.sbprintf(out, "error: %s", text)
		return .Invalid_Argument
	}

	@(require_results)
	color_text :: proc(color: [4]u8) -> string {
		return fmt.tprintf("#%02x%02x%02x%02x", color[0], color[1], color[2], color[3])
	}

	// evidence_region resolves a request region to client pixels. Cells go through the focused
	// pane's box, so an address selects exactly the pixels the grid drew for those cells.
	@(require_results)
	evidence_region :: proc(
		app: ^App,
		w: ^Window,
		region: control.Region,
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
			entry := focused_session(app, w)
			if entry == nil {
				return {}, "the selected window has no focused pane; address the region in pixels"
			}
			rect: layout.Rect
			visible := false
			for pane in w.panes {
				if pane.content.id != entry.id {continue}
				rect, visible = pane.rect, true
				break
			}
			if !visible {return {}, "the focused pane is not visible; select its tab or use --region"}
			box := pane_box(w.metrics, rect, pane_insets(app, w.scale, entry))
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
			// Cell edges are rounded, not the cell size, so adjacent cell regions meet exactly.
			left := int(math.round(box.origin.x + f32(region.x) * w.metrics.cell_width))
			top := int(math.round(box.origin.y + f32(region.y) * w.metrics.cell_height))
			right := int(
				math.round(box.origin.x + f32(region.x + region.width) * w.metrics.cell_width),
			)
			bottom := int(
				math.round(box.origin.y + f32(region.y + region.height) * w.metrics.cell_height),
			)
			requested := pixels.Rect{left, top, right - left, bottom - top}
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
		region: control.Region,
		out: ^strings.Builder,
	) -> (
		pixels.Image,
		control.Error,
	) {
		requested, complaint := evidence_region(app, w, region)
		if complaint != "" {return {}, evidence_error(out, complaint)}
		if app.device == nil {
			return {}, evidence_error(out, "the graphics device is unavailable; restart the instance")
		}
		if w.width <= 0 || w.height <= 0 {
			return {}, evidence_error(out, "the window has no drawable area; restore it and retry")
		}
		surface, surface_error := render.surface_create_offscreen(app.device, w.width, w.height)
		if surface_error != .None {
			return {}, evidence_error(
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
			return {}, evidence_error(
				out,
				fmt.tprintf(
					"cannot render the frame offscreen (%v); retry after the next frame",
					render_error,
				),
			)
		}
		readback, read_error := render.surface_read_pixels(app.device, surface, context.allocator)
		if read_error != .None {
			return {}, evidence_error(
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
			return {}, evidence_error(out, "the region does not fit the rendered frame")
		}
		return image, .None
	}

	@(require_results)
	capture_read :: proc(
		app: ^App,
		out: ^strings.Builder,
		request: control.Capture,
	) -> control.Error {
		w := verify_window(app)
		if w == nil {return evidence_error(out, "no window to capture; run tray open")}
		image, err := evidence_frame(app, w, request.region, out)
		if err != .None {return err}
		defer pixels.image_destroy(&image)
		path := request.output
		if path == "" {
			if app.options.data_dir == "" {
				return evidence_error(out, "no data directory for the default capture; pass --out <file.png>")
			}
			directory, join_error := filepath.join({app.options.data_dir, "captures"})
			if join_error != nil {return .Out_Of_Memory}
			if mkdir_error := os.mkdir_all(directory); mkdir_error != nil {
				return evidence_error(
					out,
					fmt.tprintf("cannot create %s (%v); pass --out <file.png>", directory, mkdir_error),
				)
			}
			path, join_error = filepath.join({directory, "capture.png"})
			if join_error != nil {return .Out_Of_Memory}
		}
		if request.output != "" {
			// An explicit --out may point into a directory the caller has not created yet; the
			// default path above already owns its captures directory.
			directory := filepath.dir(path)
			if directory != "" && directory != "." {
				if mkdir_error := os.mkdir_all(directory); mkdir_error != nil {
					return evidence_error(
						out,
						fmt.tprintf("cannot create %s (%v); check the path", directory, mkdir_error),
					)
				}
			}
		}
		if pixels.png_write(path, image) != .None {
			return evidence_error(
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
		request: control.Pixels,
	) -> control.Error {
		w := verify_window(app)
		if w == nil {return evidence_error(out, "no window to read; run tray open")}
		image, err := evidence_frame(app, w, request.region, out)
		if err != .None {return err}
		defer pixels.image_destroy(&image)
		if request.sampled {
			color, sample_error := pixels.sample(image, request.sample.x, request.sample.y)
			if sample_error != .None {
				return evidence_error(
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
				color_text(color),
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
				color_text(line.dominant),
			)
		}
		return .None
	}

	@(require_results)
	pixels_diff :: proc(
		app: ^App,
		out: ^strings.Builder,
		request: control.Diff,
	) -> control.Error {
		w := verify_window(app)
		if w == nil {return evidence_error(out, "no window to compare; run tray open")}
		baseline, read_error := pixels.png_read(request.baseline)
		if read_error != .None {
			if read_error == .Out_Of_Memory {return .Out_Of_Memory}
			if read_error == .Not_An_Image {
				return evidence_error(
					out,
					fmt.tprintf(
						"%s is not an 8-bit RGB or RGBA PNG; capture a new baseline",
						request.baseline,
					),
				)
			}
			return evidence_error(
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
			return evidence_error(
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
