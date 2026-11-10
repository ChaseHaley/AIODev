package term_view_test

import "base:runtime"
import "aio:render"
import "aio:caret"
import "aio:term_view"
import "core:slice"
import "core:testing"

@(private)
transition_cell :: proc(r: render.Rect) -> term_view.Cursor_Paint {
	return {head = r, tail = r, target = r, shape = .Block, color = {1, 1, 1, 1}, text_color = {0, 0, 0, 1}, stroke = 1}
}

@(test)
transition_retargets_the_last_draw_not_the_next_frame_sample :: proc(t: ^testing.T) {
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	clip := render.Rect{0, 0, 400, 200}
	from := transition_cell({0, 0, 10, 20})
	to := transition_cell({100, 40, 20, 20})
	effects := caret.Effects{preset = .Smooth, duration = 5 * PERIOD, movement = true}
	transition: term_view.Cursor_Transition
	term_view.cursor_transition_start(&transition, from, to, effects)
	testing.expect(t, term_view.cursor_transition_active(&transition))
	testing.expect_value(t, term_view.cursor_transition_paint(&transition).head, from.head)
	testing.expect_value(t, term_view.cursor_transition_paint(&transition).target, to.target)
	// Resuming does not consume a refresh or jump to the destination.
	testing.expect(t, !term_view.cursor_transition_animate(&transition, frame_at(0, resuming = true), true))
	testing.expect(t, term_view.cursor_transition_animate(&transition, frame_at(1), true))
	testing.expect_value(t, term_view.cursor_transition_paint(&transition).head, from.head)
	term_view.cursor_transition_draw(&transition, &list, clip)
	term_view.cursor_transition_commit(&transition)
	shown := term_view.cursor_transition_paint(&transition)
	testing.expect_value(t, shown.head, render.Rect{49, 20, 15, 20})
	// The scheduler can advance, but focus changes still depart from the pose on screen.
	testing.expect(t, term_view.cursor_transition_animate(&transition, frame_at(2), true))
	testing.expect_value(t, term_view.cursor_transition_paint(&transition).head, shown.head)
	to = transition_cell({0, 60, 10, 20})
	to.color = {0, 1, 0, 1}
	term_view.cursor_transition_start(&transition, shown, to, effects)
	testing.expect_value(t, term_view.cursor_transition_paint(&transition).color, to.color)
	testing.expect(t, term_view.cursor_transition_animate(&transition, frame_at(3), true))
	render.draw_list_reset(&list)
	term_view.cursor_transition_draw(&transition, &list, clip)
	term_view.cursor_transition_commit(&transition)
	testing.expect_value(t, term_view.cursor_transition_paint(&transition).head, render.Rect{25, 40, 13, 20})
	for n in 4 ..< 7 {term_view.cursor_transition_animate(&transition, frame_at(n), true)}
	testing.expect(t, term_view.cursor_transition_animate(&transition, frame_at(7), true))
	testing.expect(t, !term_view.cursor_transition_active(&transition))
	testing.expect(t, !term_view.cursor_transition_animate(&transition, frame_at(8), true))
	render.draw_list_reset(&list)
	term_view.cursor_transition_draw(&transition, &list, clip)
	term_view.cursor_transition_commit(&transition)
	testing.expect_value(t, term_view.cursor_transition_paint(&transition).head, to.target)
	testing.expect_value(t, list.error, render.Error.None)
}

@(test)
transition_uses_existing_no_movement_and_disabled_policies :: proc(t: ^testing.T) {
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	from := transition_cell({0, 0, 10, 20})
	to := transition_cell({100, 0, 10, 20})
	clip := render.Rect{0, 0, 200, 40}
	for preset in ([2]caret.Preset{.Smear, .Trail}) {
		transition: term_view.Cursor_Transition
		effects := caret.Effects{preset = preset, duration = 5 * PERIOD, strength = 1}
		testing.expect(t, caret.effects_active(effects))
		term_view.cursor_transition_start(&transition, from, to, effects)
		term_view.cursor_transition_animate(&transition, frame_at(0, resuming = true), true)
		render.draw_list_reset(&list)
		term_view.cursor_transition_draw(&transition, &list, clip)
		term_view.cursor_transition_commit(&transition)
		paint := term_view.cursor_transition_paint(&transition)
		testing.expect_value(t, paint.head, to.target)
		testing.expect_value(t, paint.tail, from.tail)
		testing.expect(t, term_view.cursor_transition_active(&transition))
		testing.expect(t, term_view.cursor_transition_animate(&transition, frame_at(1), false))
		testing.expect(t, !term_view.cursor_transition_active(&transition))
		testing.expect(t, !term_view.cursor_transition_animate(&transition, frame_at(2), true))
		render.draw_list_reset(&list)
		term_view.cursor_transition_draw(&transition, &list, clip)
		term_view.cursor_transition_commit(&transition)
		testing.expect_value(t, term_view.cursor_transition_paint(&transition).tail, to.target)
	}
	for preset in ([2]caret.Preset{.Off, .Smooth}) {
		effects := caret.Effects{preset = preset, duration = 5 * PERIOD}
		testing.expect(t, !caret.effects_active(effects))
		transition: term_view.Cursor_Transition
		term_view.cursor_transition_start(&transition, from, to, effects)
		testing.expect(t, !term_view.cursor_transition_active(&transition))
		render.draw_list_reset(&list)
		term_view.cursor_transition_draw(&transition, &list, clip)
		term_view.cursor_transition_commit(&transition)
		testing.expect_value(t, term_view.cursor_transition_paint(&transition).head, to.target)
	}
}

@(test)
cursor_capture_survives_suppression_and_unfocused_wide_cells :: proc(t: ^testing.T) {
	f, ok := headless_create(t)
	defer fixture_destroy(&f)
	if !ok {return}
	write(&f, "\u754cW\x1b[H")
	style := effects_style(&f, .Smooth)
	first, _ := render_frame(t, &f, style, frame_at(0))
	paint, captured := first.cursor.?
	testing.expect(t, captured)
	testing.expect_value(t, paint.target.width, 2 * f.metrics.cell_width)
	write(&f, "\x1b[1;10H")
	moving, _ := render_frame(t, &f, style, frame_at(1))
	paint, captured = moving.cursor.?
	testing.expect(t, captured)
	testing.expect(t, paint.head.x > 0 && paint.head.x < paint.target.x)
	style.cursor_suppressed = true
	suppressed, pixels := render_frame(t, &f, style, frame_at(2))
	pixels = slice.clone(pixels, context.temp_allocator)
	paint, captured = suppressed.cursor.?
	testing.expect(t, captured)
	testing.expect_value(t, paint.head, paint.target)
	testing.expect(t, !term_view.cursor_animating(&f.view))
	testing.expect_value(t, suppressed.cursor_blinking, first.cursor_blinking)
	style.cursor_suppressed = false
	style.cursor_phase_visible = false
	_, no_cursor := render_frame(t, &f, style, frame_at(3))
	testing.expect(t, slice.equal(pixels, no_cursor), "suppression must remove the body and destination foreground recoloring")
	write(&f, "\x1b[1;2H")
	style.cursor_phase_visible, style.focused = true, false
	unfocused, _ := render_frame(t, &f, style, frame_at(4))
	paint, captured = unfocused.cursor.?
	testing.expect(t, captured)
	testing.expect_value(t, paint.target, render.Rect{0, 0, 2 * f.metrics.cell_width, f.metrics.cell_height})
	write(&f, "\x1b[?25l")
	hidden, _ := render_frame(t, &f, style, frame_at(5))
	_, captured = hidden.cursor.?
	testing.expect(t, !captured)
}

@(test)
transition_is_visible_between_panes_not_just_at_its_destination :: proc(t: ^testing.T) {
	f, ok := headless_create(t)
	defer fixture_destroy(&f)
	if !ok {return}
	m := f.metrics
	from := transition_cell({0, 0, m.cell_width, m.cell_height})
	to := transition_cell({18 * m.cell_width, 2 * m.cell_height, m.cell_width, m.cell_height})
	transition: term_view.Cursor_Transition
	term_view.cursor_transition_start(&transition, from, to, effects_style(&f, .Smooth).cursor_effects)
	term_view.cursor_transition_animate(&transition, frame_at(1), true)
	render.draw_list_reset(&f.list)
	clip := render.Rect{0, 0, COLUMNS * m.cell_width, ROWS * m.cell_height}
	term_view.cursor_transition_draw(&transition, &f.list, clip)
	term_view.cursor_transition_commit(&transition)
	testing.expect_value(t, render.frame_render(f.device, f.surface, &f.list, {0, 0, 0, 1}), render.Error.None)
	pixels, err := render.surface_read_pixels(f.device, f.surface, context.temp_allocator)
	testing.expect_value(t, err, render.Error.None)
	paint := term_view.cursor_transition_paint(&transition)
	testing.expect(t, paint.head.x > 0 && paint.head.x + paint.head.width < to.target.x)
	testing.expect_value(t, cell_pixel(&f, pixels, 0, 0, paint.head.x + 1, paint.head.y + 1), [4]u8{255, 255, 255, 255})
	testing.expect_value(t, cell_pixel(&f, pixels, 18, 2, 1, 1), BLACK)
}

@(test)
transition_text_translates_source_clipping_and_glyph_uvs_without_mutation :: proc(t: ^testing.T) {
	source := render.draw_list_init()
	list := render.draw_list_init()
	defer render.draw_list_destroy(&source)
	defer render.draw_list_destroy(&list)
	testing.expect_value(t, render.push_layer(&source, {0, 0, 12, 20}), render.Error.None)
	glyph := render.Glyph_Instance{
		rect = {0, 0, 20, 20}, atlas = {100, 200, 40, 60}, color = {1, 0, 0, 1},
		flags = render.GLYPH_FADE, fade_start = 4, fade_end = 10,
	}
	testing.expect_value(t, render.push_glyph(&source, glyph), render.Error.None)
	paint := transition_cell({35, 15, 20, 20})
	transition: term_view.Cursor_Transition
	term_view.cursor_transition_start(&transition, paint, paint, {})
	term_view.cursor_transition_pane(&transition, &list, &source, {30, 10}, {0, 0, 100, 100}, 0)
	testing.expect_value(t, list.error, render.Error.None)
	if !testing.expect_value(t, len(list.glyphs), 1) {return}
	replayed := list.glyphs[0]
	testing.expect_value(t, replayed.rect, render.Rect{35, 15, 7, 15})
	testing.expect_value(t, replayed.atlas, render.Rect{110, 215, 14, 45})
	testing.expect_value(t, replayed.color, paint.text_color)
	testing.expect_value(t, replayed.fade_start, f32(34))
	testing.expect_value(t, replayed.fade_end, f32(40))
	testing.expect_value(t, source.glyphs[0], glyph)
	// Non-block transitions must not recolor the terminal's text.
	paint.shape = .Bar
	term_view.cursor_transition_start(&transition, paint, paint, {})
	render.draw_list_reset(&list)
	term_view.cursor_transition_pane(&transition, &list, &source, {}, {0, 0, 100, 100}, 0)
	testing.expect_value(t, len(list.glyphs), 0)
	testing.expect_value(t, len(list.rects), 0)
}

@(test)
transition_text_keeps_rounded_masks_and_blank_float_occlusion :: proc(t: ^testing.T) {
	f, ok := headless_create(t)
	defer fixture_destroy(&f)
	if !ok {return}
	write(&f, "WWWW\x1b[H")
	style := effects_style(&f, .Off)
	style.cursor_suppressed = true
	render_frame(t, &f, style)
	list := render.draw_list_init()
	blank := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	defer render.draw_list_destroy(&blank)
	m := f.metrics
	offset := [2]f32{2 * m.cell_width, m.cell_height}
	clip := render.Rect{offset.x, offset.y, 3 * m.cell_width, m.cell_height}
	paint := transition_cell(clip)
	transition: term_view.Cursor_Transition
	term_view.cursor_transition_start(&transition, paint, paint, {})
	// Text alone repaints only this pane's head intersection under its original mask.
	term_view.cursor_transition_pane(&transition, &list, &f.list, offset, clip, 8)
	testing.expect_value(t, render.frame_render(f.device, f.surface, &list, {0, 0, 0, 1}), render.Error.None)
	pixels, err := render.surface_read_pixels(f.device, f.surface, context.temp_allocator)
	testing.expect_value(t, err, render.Error.None)
	testing.expect_value(t, cell_pixel(&f, pixels, 2, 1, 0, 0), BLACK)
	testing.expect_value(t, cell_pixel(&f, pixels, 1, 1, m.cell_width - 1, m.cell_height / 2), BLACK)
	ink := false
	for y in 2 ..< int(m.cell_height) - 2 {
		for x in int(m.cell_width) ..< 2 * int(m.cell_width) {
			ink ||= cell_pixel(&f, pixels, 2, 1, f32(x), f32(y)) == BLACK
		}
	}
	testing.expect(t, ink, "translated glyphs remain readable inside the cursor")
	// An empty upper pane must erase the lower pane's replay, not let its text bleed through.
	upper := render.Rect{offset.x + m.cell_width, offset.y, m.cell_width, m.cell_height}
	term_view.cursor_transition_pane(&transition, &list, &blank, {}, upper, 0)
	testing.expect_value(t, render.frame_render(f.device, f.surface, &list, {0, 0, 0, 1}), render.Error.None)
	pixels, err = render.surface_read_pixels(f.device, f.surface, context.temp_allocator)
	testing.expect_value(t, err, render.Error.None)
	for y in 1 ..< int(m.cell_height) - 1 {
		for x in 1 ..< int(m.cell_width) - 1 {
			testing.expect_value(t, cell_pixel(&f, pixels, 3, 1, f32(x), f32(y)), [4]u8{255, 255, 255, 255})
		}
	}
}

@(test)
window_transitions_match_local_preset_pixels_and_frame_timing :: proc(t: ^testing.T) {
	f, ok := headless_create(t)
	defer fixture_destroy(&f)
	if !ok {return}
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	clip := render.Rect{0, 0, COLUMNS * f.metrics.cell_width, ROWS * f.metrics.cell_height}
	for preset in ([3]caret.Preset{.Smooth, .Smear, .Trail}) {
		for movement in ([2]bool{true, false}) {
			term_view.cursor_reset(&f.view)
			write(&f, "\x1b[H")
			style := effects_style(&f, preset, movement = movement, strength = 0.7)
			first, _ := render_frame(t, &f, style, frame_at(0))
			from, present := first.cursor.?
			if !testing.expect(t, present) {return}
			write(&f, "\x1b[3;15H")
			local, local_pixels := render_frame(t, &f, style, frame_at(1))
			local_pixels = slice.clone(local_pixels, context.temp_allocator)
			to, captured := local.cursor.?
			if !testing.expect(t, captured) {return}
			transition: term_view.Cursor_Transition
			term_view.cursor_transition_start(&transition, from, to, style.cursor_effects)
			term_view.cursor_transition_animate(&transition, frame_at(1), true)
			render.draw_list_reset(&list)
			term_view.cursor_transition_draw(&transition, &list, clip)
			term_view.cursor_transition_commit(&transition)
			testing.expect_value(t, render.frame_render(f.device, f.surface, &list, local.background), render.Error.None)
			pixels, err := render.surface_read_pixels(f.device, f.surface, context.temp_allocator)
			testing.expect_value(t, err, render.Error.None)
			testing.expect(t, slice.equal(pixels, local_pixels), "the window and local cursor share preset geometry and strength")
			term_view.cursor_animate(&f.view, frame_at(3), true)
			local, local_pixels = render_frame(t, &f, style, frame_at(3))
			local_pixels = slice.clone(local_pixels, context.temp_allocator)
			term_view.cursor_transition_animate(&transition, frame_at(3), true)
			render.draw_list_reset(&list)
			term_view.cursor_transition_draw(&transition, &list, clip)
			term_view.cursor_transition_commit(&transition)
			testing.expect_value(t, render.frame_render(f.device, f.surface, &list, local.background), render.Error.None)
			pixels, err = render.surface_read_pixels(f.device, f.surface, context.temp_allocator)
			testing.expect_value(t, err, render.Error.None)
			testing.expect(t, slice.equal(pixels, local_pixels), "later display frames must share the local easing and trail fade")
		}
	}
}

@(test)
transition_can_anchor_the_focus_frame_without_advancing_its_drawn_pose :: proc(t: ^testing.T) {
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	from := transition_cell({0, 0, 10, 20})
	to := transition_cell({100, 0, 10, 20})
	transition: term_view.Cursor_Transition
	term_view.cursor_transition_start(&transition, from, to, {preset = .Smooth, movement = true, duration = 5 * PERIOD})
	anchor := frame_at(0)
	anchor.period = 0
	testing.expect(t, !term_view.cursor_transition_animate(&transition, anchor, true))
	term_view.cursor_transition_draw(&transition, &list, {0, 0, 200, 40})
	term_view.cursor_transition_commit(&transition)
	testing.expect_value(t, term_view.cursor_transition_paint(&transition).head, from.head)
	// A late next display frame still settles against the focus frame, not its own first refresh.
	testing.expect(t, term_view.cursor_transition_animate(&transition, frame_at(8), true))
	testing.expect(t, !term_view.cursor_transition_active(&transition))
	render.draw_list_reset(&list)
	term_view.cursor_transition_draw(&transition, &list, {0, 0, 200, 40})
	term_view.cursor_transition_commit(&transition)
	testing.expect_value(t, term_view.cursor_transition_paint(&transition).head, to.target)
}

@(test)
transition_discards_a_rejected_frames_pose :: proc(t: ^testing.T) {
	f, ok := headless_create(t)
	defer fixture_destroy(&f)
	if !ok {return}
	from := transition_cell({0, 0, 10, 20})
	to := transition_cell({100, 0, 10, 20})
	transition: term_view.Cursor_Transition
	term_view.cursor_transition_start(&transition, from, to,
		{preset = .Smooth, duration = 5 * PERIOD, movement = true})
	build := render.frame_build_begin(&f.list, f.device)
	term_view.cursor_transition_animate(&transition, frame_at(1), true)
	term_view.cursor_transition_draw(&transition, &f.list, {0, 0, 160, 80})
	// The cursor body succeeded, but a later overlay cannot append its glyph.
	context.logger = {}
	f.list.glyphs.allocator = runtime.Allocator{procedure = construction_fail_allocation}
	testing.expect_value(t, render.push_glyph(&f.list, {}), render.Error.Out_Of_Memory)
	testing.expect_value(t, render.frame_build_finish(&build), render.Frame_Build_Result.Failed)
	testing.expect(t, term_view.cursor_transition_paint(&transition).head == from.head,
		"the next focus change must start at the last completed frame, not rejected drawing")
	f.list.glyphs.allocator = context.allocator
}
