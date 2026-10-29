package term_view_test

import "base:runtime"
import "core:testing"
import "aio:render"
import "aio:term_view"

@(private="file")
construction_fail_allocation :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int,
	old_memory: rawptr, old_size: int, location := #caller_location) -> ([]u8, runtime.Allocator_Error) {
	return nil, .Out_Of_Memory
}

@(test)
terminal_draw_failures_reach_frame_completion :: proc(t: ^testing.T) {
	f, ok := fixture_create(t, text_command("$e + '[41mRR' + $e + '[0mAB'"))
	defer fixture_destroy(&f)
	if !ok || !await_text(t, f.session, "RRAB") {return}
	context.logger = {}
	failing := runtime.Allocator{procedure = construction_fail_allocation}
	style := term_view.Style{family = f.family}
	for kind in 0 ..< 4 {
		render.draw_list_destroy(&f.list)
		f.list = render.draw_list_init()
		build := render.frame_build_begin(&f.list, f.device)
		switch kind {
		case 0: f.list.layers.allocator = failing
		case 1: f.list.rects.allocator = failing
		case 2: f.list.glyphs.allocator = failing
		case 3:
			delete(f.view.codepoints)
			f.view.codepoints = make([dynamic]u32, failing)
		}
		_ = render.push_layer(&f.list, {0, 0, 4096, 4096})
		_, _ = term_view.build(&f.view, f.session, f.fonts, &f.cache, &f.list, {}, f.metrics, style)
		testing.expect_value(t, render.frame_build_finish(&build), render.Frame_Build_Result.Failed)
		testing.expect_value(t, f.list.error, render.Error.Out_Of_Memory)
		testing.expect_value(t, len(f.list.layers) + len(f.list.rects) + len(f.list.glyphs), 0)
		f.list.layers.allocator, f.list.rects.allocator, f.list.glyphs.allocator = context.allocator, context.allocator, context.allocator
		f.view.codepoints.allocator = context.allocator
		build = render.frame_build_begin(&f.list, f.device)
		_ = render.push_layer(&f.list, {0, 0, 4096, 4096})
		_, _ = term_view.build(&f.view, f.session, f.fonts, &f.cache, &f.list, {}, f.metrics, style)
		testing.expect_value(t, render.frame_build_finish(&build), render.Frame_Build_Result.Ready)
		testing.expect(t, len(f.list.glyphs) > 0 && len(f.list.rects) > 0)
	}
}
