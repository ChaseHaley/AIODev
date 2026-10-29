package render_test

import "core:testing"
import "core:log"
import "core:strings"
import "base:runtime"
import "aio:render"

// All failure kinds cross the same completion seam used by windows and pane previews.
@(test)
frame_construction_rejects_failed_writes_and_recovers :: proc(t: ^testing.T) {
	context.logger = {}
	f, ok := fixture_create(t, 2, 2)
	if !ok {return}
	defer fixture_destroy(&f)
	failing := runtime.Allocator{procedure = failing_allocator}
	for kind in 0 ..< 5 {
		render.draw_list_reset(&f.list)
		testing.expect_value(t, render.frame_render(f.device, f.surface, &f.list, {0, 1, 0, 1}), render.Error.None)
		build := render.frame_build_begin(&f.list, f.device)
		source := render.draw_list_init()
		if kind == 0 {f.list.layers.allocator = failing}
		_ = render.push_layer(&f.list, {0, 0, 2, 2})
		if kind == 1 {f.list.rects.allocator = failing}
		_ = render.push_rect(&f.list, {rect = {0, 0, 2, 2}, color = {1, 0, 0, 1}})
		if kind == 2 {
			f.list.glyphs.allocator = failing
			_ = render.push_glyph(&f.list, {rect = {0, 0, 1, 1}})
		}
		if kind == 3 {
			_ = render.push_layer(&source, {0, 0, 2, 2})
			_ = render.push_glyph(&source, {rect = {0, 0, 1, 1}})
			f.list.glyphs.allocator = failing
			testing.expect_value(t, render.append_list(&f.list, &source), render.Error.Out_Of_Memory)
			// A reserve failure cannot copy a prefix of the cached list.
			testing.expect_value(t, len(f.list.layers), 1)
			testing.expect_value(t, len(f.list.rects), 1)
			testing.expect_value(t, source.error, render.Error.None)
		}
		if kind == 4 {
			source.layers.allocator = failing
			_ = render.push_layer(&source, {})
			testing.expect_value(t, render.append_list(&f.list, &source), render.Error.Out_Of_Memory)
		}
		testing.expect_value(t, render.frame_build_finish(&build), render.Frame_Build_Result.Failed)
		testing.expect_value(t, f.list.error, render.Error.Out_Of_Memory)
		testing.expect_value(t, len(f.list.layers) + len(f.list.rects) + len(f.list.glyphs), 0)
		// Later writes remain rejected even when no layer was successfully allocated.
		testing.expect_value(t, render.push_glyph(&f.list, {}), render.Error.Out_Of_Memory)
		testing.expect_value(t, render.frame_render(f.device, f.surface, &f.list, {1, 0, 0, 1}), render.Error.Out_Of_Memory)
		pixels, err := render.surface_read_pixels(f.device, f.surface, context.allocator)
		testing.expect_value(t, err, render.Error.None)
		expect_pixel(t, pixels, 2, 0, 0, {0, 255, 0, 255})
		delete(pixels)
		render.draw_list_destroy(&source)
		f.list.layers.allocator, f.list.rects.allocator, f.list.glyphs.allocator = context.allocator, context.allocator, context.allocator
		build = render.frame_build_begin(&f.list, f.device)
		_ = render.push_layer(&f.list, {0, 0, 2, 2})
		_ = render.push_rect(&f.list, {rect = {0, 0, 2, 2}, color = {0, 0, 1, 1}})
		testing.expect_value(t, render.frame_build_finish(&build), render.Frame_Build_Result.Ready)
		testing.expect_value(t, render.frame_render(f.device, f.surface, &f.list, {}), render.Error.None)
		pixels, err = render.surface_read_pixels(f.device, f.surface, context.allocator)
		testing.expect_value(t, err, render.Error.None)
		expect_pixel(t, pixels, 2, 0, 0, {255, 0, 0, 255})
		delete(pixels)
		// Fresh storage ensures each next case really reaches an allocation.
		render.draw_list_destroy(&f.list)
		f.list = render.draw_list_init()
	}
}

@(test)
frame_construction_bounds_atlas_retries_and_rejects_stale_content :: proc(t: ^testing.T) {
	context.logger = {}
	f, ok := fixture_create(t, 2, 2)
	if !ok {return}
	defer fixture_destroy(&f)
	testing.expect_value(t, render.frame_render(f.device, f.surface, &f.list, {0, 1, 0, 1}), render.Error.None)
	build := render.frame_build_begin(&f.list, f.device)
	for attempt in 0 ..< 2 {
		_ = render.push_layer(&f.list, {0, 0, 2, 2})
		_ = render.push_rect(&f.list, {rect = {0, 0, 2, 2}, color = {1, 0, 0, 1}})
		_ = render.push_glyph(&f.list, {rect = {0, 0, 1, 1}})
		render.atlas_reset(f.device)
		expected: render.Frame_Build_Result = attempt == 0 ? .Retry : .Failed
		testing.expect_value(t, render.frame_build_finish(&build), expected)
		testing.expect_value(t, len(f.list.layers) + len(f.list.rects) + len(f.list.glyphs), 0)
	}
	testing.expect_value(t, render.frame_render(f.device, f.surface, &f.list, {1, 0, 0, 1}), render.Error.Atlas_Invalidated)
	pixels, err := render.surface_read_pixels(f.device, f.surface, context.allocator)
	testing.expect_value(t, err, render.Error.None)
	expect_pixel(t, pixels, 2, 0, 0, {0, 255, 0, 255})
	delete(pixels)
	// A later frame may reset once and then finish with entirely fresh instances.
	build = render.frame_build_begin(&f.list, f.device)
	_ = render.push_layer(&f.list, {0, 0, 2, 2})
	_ = render.push_rect(&f.list, {rect = {0, 0, 2, 2}, color = {1, 0, 0, 1}})
	render.atlas_reset(f.device)
	testing.expect_value(t, render.frame_build_finish(&build), render.Frame_Build_Result.Retry)
	_ = render.push_layer(&f.list, {0, 0, 2, 2})
	_ = render.push_rect(&f.list, {rect = {0, 0, 2, 2}, color = {0, 0, 1, 1}})
	testing.expect_value(t, render.frame_build_finish(&build), render.Frame_Build_Result.Ready)
	testing.expect_value(t, render.frame_render(f.device, f.surface, &f.list, {}), render.Error.None)
	render.atlas_reset(f.device)
	testing.expect_value(t, render.frame_render(f.device, f.surface, &f.list, {1, 0, 0, 1}), render.Error.Atlas_Invalidated)
	pixels, err = render.surface_read_pixels(f.device, f.surface, context.allocator)
	testing.expect_value(t, err, render.Error.None)
	expect_pixel(t, pixels, 2, 0, 0, {255, 0, 0, 255})
	delete(pixels)
}


@(private="file")
Construction_Diagnostics :: struct {count: int, reason: bool}

@(private="file")
construction_log :: proc(data: rawptr, level: log.Level, text: string, options: log.Options,
	location := #caller_location) {
	if level == .Error && strings.contains(text, "constructing a frame failed") {
		diagnostics := cast(^Construction_Diagnostics)data
		diagnostics.count += 1
		diagnostics.reason = strings.contains(text, "Out_Of_Memory")
	}
}

@(test)
frame_construction_reports_once_until_healthy_completion :: proc(t: ^testing.T) {
	f, ok := fixture_create(t, 2, 2)
	if !ok {return}
	defer fixture_destroy(&f)
	diagnostics: Construction_Diagnostics
	logger := context.logger
	defer context.logger = logger
	context.logger = {procedure = construction_log, data = &diagnostics}
	f.list.layers.allocator = runtime.Allocator{procedure = failing_allocator}
	for _ in 0 ..< 3 {
		build := render.frame_build_begin(&f.list, f.device)
		_ = render.push_layer(&f.list, {})
		testing.expect_value(t, render.frame_build_finish(&build), render.Frame_Build_Result.Failed)
		testing.expect_value(t, diagnostics.count, 1)
		testing.expect(t, diagnostics.reason)
	}
	f.list.layers.allocator = context.allocator
	// Retrying a different failure still cannot flood the log before recovery.
	build := render.frame_build_begin(&f.list, f.device)
	render.atlas_reset(f.device)
	testing.expect_value(t, render.frame_build_finish(&build), render.Frame_Build_Result.Retry)
	render.atlas_reset(f.device)
	testing.expect_value(t, render.frame_build_finish(&build), render.Frame_Build_Result.Failed)
	testing.expect_value(t, diagnostics.count, 1)
	build = render.frame_build_begin(&f.list, f.device)
	_ = render.push_layer(&f.list, {0, 0, 2, 2})
	testing.expect_value(t, render.frame_build_finish(&build), render.Frame_Build_Result.Ready)
	testing.expect_value(t, diagnostics.count, 1)
	build = render.frame_build_begin(&f.list, f.device)
	_ = render.push_layer(&f.list, {})
	f.list.glyphs.allocator = runtime.Allocator{procedure = failing_allocator}
	_ = render.push_glyph(&f.list, {})
	testing.expect_value(t, render.frame_build_finish(&build), render.Frame_Build_Result.Failed)
	testing.expect_value(t, diagnostics.count, 2)
	testing.expect(t, diagnostics.reason)
}
