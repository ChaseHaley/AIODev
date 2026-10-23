package draws_test

import "aio:draws"
import "aio:render"
import "core:strings"
import "core:testing"

// The fixture pushes layers and instances through the same calls build_frame uses, so a report is
// exercised against the draw order the renderer actually sees.

layer :: proc(t: ^testing.T, list: ^render.Draw_List, clip: render.Rect) {
	testing.expect_value(t, render.push_layer(list, clip), render.Error.None)
}

rect :: proc(
	t: ^testing.T,
	list: ^render.Draw_List,
	r: render.Rect,
	color: render.Color,
	radius: f32,
) {
	instance := render.Rect_Instance {
		rect   = r,
		color  = color,
		radius = radius,
	}
	testing.expect_value(t, render.push_rect(list, instance), render.Error.None)
}

glyph :: proc(t: ^testing.T, list: ^render.Draw_List, r: render.Rect, color: render.Color, flags: u32) {
	instance := render.Glyph_Instance {
		rect  = r,
		color = color,
		flags = flags,
	}
	testing.expect_value(t, render.push_glyph(list, instance), render.Error.None)
}

report :: proc(list: ^render.Draw_List, filter: draws.Filter) -> string {
	out := strings.builder_make(context.temp_allocator)
	draws.format_report(&out, list, filter)
	return strings.to_string(out)
}

// rows splits a report into its printed lines, ignoring the trailing newline of the last one.
rows :: proc(text: string) -> []string {
	trimmed := strings.trim_right(text, "\n")
	if trimmed == "" {return nil}
	return strings.split(trimmed, "\n", context.temp_allocator)
}

expect_rows :: proc(t: ^testing.T, text: string, expected: []string) {
	actual := rows(text)
	if !testing.expect_value(t, len(actual), len(expected)) {return}
	for row, i in actual {
		testing.expect_value(t, row, expected[i])
	}
}

@(test)
summary_lists_layers_only :: proc(t: ^testing.T) {
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	layer(t, &list, {0, 0, 100, 100})
	rect(t, &list, {0, 0, 10, 10}, {1, 1, 1, 1}, 0)
	glyph(t, &list, {0, 0, 8, 8}, {1, 1, 1, 1}, 1)
	layer(t, &list, {0, 100, 100, 50})
	expect_rows(
		t,
		report(&list, {}),
		{
			"draws layers=2 rects=1 glyphs=1",
			"layer 0 clip=0,0,100,100 rects=1 glyphs=1",
			"layer 1 clip=0,100,100,50 rects=0 glyphs=0",
		},
	)
}

@(test)
instances_follow_draw_order_across_layers :: proc(t: ^testing.T) {
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	layer(t, &list, {0, 0, 100, 100})
	rect(t, &list, {10.4, 20.6, 30, 40}, {1, 0, 0, 1}, 2.5)
	glyph(t, &list, {5, 6, 7, 8}, {0, 0.5, 0.25, 1}, 3)
	layer(t, &list, {0, 0, 100, 100})
	rect(t, &list, {1, 2, 3, 4}, {0, 0, 0, 1}, 0)
	glyph(t, &list, {9, 10, 11, 12}, {1, 1, 1, 1}, 0)
	filter := draws.Filter {
		bounded = true,
		region  = {0, 0, 100, 100},
	}
	expect_rows(
		t,
		report(&list, filter),
		{
			"draws layers=2 rects=2 glyphs=2",
			"layer 0 clip=0,0,100,100 rects=1 glyphs=1",
			"rect 0 10,21 30x40 #ff0000ff radius=2.5",
			"glyph 0 5,6 7x8 #008040ff flags=3",
			"layer 1 clip=0,0,100,100 rects=1 glyphs=1",
			"rect 1 1,2 3x4 #000000ff radius=0",
			"glyph 1 9,10 11x12 #ffffffff flags=0",
		},
	)
}

@(test)
region_filters_instances_by_strict_intersection :: proc(t: ^testing.T) {
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	layer(t, &list, {0, 0, 100, 100})
	rect(t, &list, {0, 0, 10, 10}, {1, 1, 1, 1}, 0)
	rect(t, &list, {50, 50, 10, 10}, {1, 1, 1, 1}, 0)
	// These only touch the region edges, so they stay outside it.
	rect(t, &list, {55, 45, 10, 10}, {1, 1, 1, 1}, 0)
	rect(t, &list, {40, 45, 5, 10}, {1, 1, 1, 1}, 0)
	glyph(t, &list, {48, 48, 4, 4}, {1, 1, 1, 1}, 1)
	filter := draws.Filter {
		bounded = true,
		region  = {45, 45, 10, 10},
	}
	expect_rows(
		t,
		report(&list, filter),
		{
			"draws layers=1 rects=4 glyphs=1",
			"layer 0 clip=0,0,100,100 rects=4 glyphs=1",
			"rect 1 50,50 10x10 #ffffffff radius=0",
			"glyph 0 48,48 4x4 #ffffffff flags=1",
		},
	)
}

@(test)
kind_suppresses_the_other_instance_lines :: proc(t: ^testing.T) {
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	layer(t, &list, {0, 0, 100, 100})
	rect(t, &list, {0, 0, 10, 10}, {1, 1, 1, 1}, 0)
	glyph(t, &list, {0, 0, 8, 8}, {1, 1, 1, 1}, 2)
	region := render.Rect{0, 0, 100, 100}
	expect_rows(
		t,
		report(&list, draws.Filter{bounded = true, region = region, kind = .Rect}),
		{
			"draws layers=1 rects=1 glyphs=1",
			"layer 0 clip=0,0,100,100 rects=1 glyphs=1",
			"rect 0 0,0 10x10 #ffffffff radius=0",
		},
	)
	expect_rows(
		t,
		report(&list, draws.Filter{bounded = true, region = region, kind = .Glyph}),
		{
			"draws layers=1 rects=1 glyphs=1",
			"layer 0 clip=0,0,100,100 rects=1 glyphs=1",
			"glyph 0 0,0 8x8 #ffffffff flags=2",
		},
	)
}

@(test)
colors_round_and_clamp_to_bytes :: proc(t: ^testing.T) {
	testing.expect_value(t, draws.format_color({1, 0, 0, 1}), "#ff0000ff")
	testing.expect_value(t, draws.format_color({0, 0.5, 0.25, 0.5}), "#00804080")
	testing.expect_value(t, draws.format_color({1.5, -1, 0.002, 1}), "#ff0001ff")
}

@(test)
empty_list_reports_zero_counts :: proc(t: ^testing.T) {
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	testing.expect_value(t, report(&list, {}), "draws layers=0 rects=0 glyphs=0\n")
	filter := draws.Filter {
		bounded = true,
		region  = {0, 0, 4, 4},
	}
	testing.expect_value(t, report(&list, filter), "draws layers=0 rects=0 glyphs=0\n")
}

@(test)
region_must_fit_the_client_area :: proc(t: ^testing.T) {
	testing.expect(t, draws.region_fits({0, 0, 100, 100}, 100, 100))
	testing.expect(t, draws.region_fits({99, 99, 1, 1}, 100, 100))
	testing.expect(t, !draws.region_fits({90, 90, 11, 11}, 100, 100))
	testing.expect(t, !draws.region_fits({100, 0, 1, 1}, 100, 100))
	testing.expect(t, !draws.region_fits({-1, 0, 10, 10}, 100, 100))
	testing.expect(t, !draws.region_fits({0, 0, 0, 10}, 100, 100))
}
