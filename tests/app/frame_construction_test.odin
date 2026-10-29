package app_test

import "base:runtime"
import "core:testing"
import app "../../src"
import "aio:render"

@(private="file")
frame_fail_allocation :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int,
	old_memory: rawptr, old_size: int, location := #caller_location) -> ([]u8, runtime.Allocator_Error) {
	if mode == .Alloc || mode == .Alloc_Non_Zeroed || mode == .Resize || mode == .Resize_Non_Zeroed {
		return nil, .Out_Of_Memory
	}
	backing := cast(^runtime.Allocator)data
	return backing.procedure(backing.data, mode, size, alignment, old_memory, old_size, location)
}

@(test)
window_failed_frame_keeps_dirty_and_cache_recovers :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "frame-failure") {return}
	context.logger = {}
	s := &f.state
	w := s.windows[0]
	backing := context.allocator
	failing := runtime.Allocator{procedure = frame_fail_allocation, data = &backing}
	for kind in 0 ..< 3 {
		render.draw_list_destroy(&w.list)
		w.list = render.draw_list_init()
		switch kind {
		case 0: w.list.layers.allocator = failing
		case 1: w.list.rects.allocator = failing
		case 2: w.list.glyphs.allocator = failing
		}
		built, presented := s.perf.built, s.perf.presented
		w.dirty = true
		app.window_render(s, w)
		testing.expect(t, w.dirty)
		testing.expect_value(t, w.list.error, render.Error.Out_Of_Memory)
		testing.expect_value(t, s.perf.built, built)
		testing.expect_value(t, s.perf.presented, presented)
		testing.expect_value(t, len(w.list.layers) + len(w.list.rects) + len(w.list.glyphs), 0)
		w.list.layers.allocator, w.list.rects.allocator, w.list.glyphs.allocator = backing, backing, backing
		app.window_render(s, w)
		testing.expect(t, !w.dirty)
		testing.expect_value(t, s.perf.built, built + 1)
		testing.expect_value(t, s.perf.presented, presented + 1)
	}
	// A failed pane cache must poison the enclosing frame without becoming a valid cached snapshot.
	app.pane_split(s, w, .Right)
	testing.expect_value(t, len(w.panes), 2)
	cached := &w.views[0]
	render.draw_list_destroy(&cached.cache)
	cached.cache = render.draw_list_init(failing)
	cached.valid = false
	built, presented := s.perf.built, s.perf.presented
	w.dirty = true
	app.window_render(s, w)
	testing.expect(t, !cached.valid && w.dirty)
	testing.expect_value(t, s.perf.built, built)
	testing.expect_value(t, s.perf.presented, presented)
	testing.expect_value(t, w.list.error, render.Error.Out_Of_Memory)
	cached.cache.layers.allocator, cached.cache.rects.allocator, cached.cache.glyphs.allocator = backing, backing, backing
	app.window_render(s, w)
	testing.expect(t, cached.valid && !w.dirty)
	testing.expect_value(t, s.perf.built, built + 1)
	testing.expect_value(t, s.perf.presented, presented + 1)
}
