package draws

import "aio:render"
import "core:fmt"
import "core:math"
import "core:strings"

// Draw-list evidence formatting. The control adapter owns the window and the request; this package
// owns what a report says so the filtering and text rules can be tested without a device.

// Kind suppresses one kind of instance line. All lists rects and glyphs.
Kind :: enum u8 {
	All,
	Rect,
	Glyph,
}

// Filter selects the instances a report lists. An unbounded filter prints summaries only; a bounded
// one adds the instances intersecting region.
Filter :: struct {
	bounded: bool,
	region:  render.Rect,
	kind:    Kind,
}

// region_fits reports whether a client-pixel rectangle lies inside a width by height client area.
// The grammar already rejects empty sizes, so a region that does not fit is a caller mistake.
@(require_results)
region_fits :: proc(region: render.Rect, width, height: int) -> bool {
	if region.width <= 0 || region.height <= 0 {return false}
	return region.x >= 0 &&
	       region.y >= 0 &&
	       region.x + region.width <= f32(width) &&
	       region.y + region.height <= f32(height)
}

// format_report writes the summary lines and, when the filter is bounded, one line per intersecting
// instance. Instances follow frame_render: layers in order, and within a layer every rect before
// every glyph. An instance's number is its index in that list array, which is its draw order.
format_report :: proc(out: ^strings.Builder, list: ^render.Draw_List, filter: Filter) {
	fmt.sbprintf(
		out,
		"draws layers=%d rects=%d glyphs=%d\n",
		len(list.layers),
		len(list.rects),
		len(list.glyphs),
	)
	for layer, number in list.layers {
		fmt.sbprintf(
			out,
			"layer %d clip=%d,%d,%d,%d rects=%d glyphs=%d\n",
			number,
			rounded(layer.clip.x),
			rounded(layer.clip.y),
			rounded(layer.clip.width),
			rounded(layer.clip.height),
			layer.rect_count,
			layer.glyph_count,
		)
		if !filter.bounded {continue}
		if filter.kind != .Glyph {write_rects(out, list, layer, filter.region)}
		if filter.kind != .Rect {write_glyphs(out, list, layer, filter.region)}
	}
}

// format_color writes a color as the #rrggbbaa text the grammar documents. Channels reach the list
// as 0..1 f32, so clamp before rounding keeps a stray value printable instead of overflowing a byte.
@(require_results)
format_color :: proc(color: render.Color) -> string {
	return fmt.tprintf(
		"#%02x%02x%02x%02x",
		channel(color.r),
		channel(color.g),
		channel(color.b),
		channel(color.a),
	)
}

@(private, require_results)
channel :: proc(v: f32) -> int {
	return int(math.round(clamp(v, 0, 1) * 255))
}

// rounded turns f32 geometry into the integer client pixels the report prints.
@(private, require_results)
rounded :: proc(v: f32) -> int {
	return int(math.round(v))
}

// intersects uses strict overlap, so an instance that merely touches the region edge stays outside.
@(private, require_results)
intersects :: proc(a, b: render.Rect) -> bool {
	return a.x < b.x + b.width &&
	       b.x < a.x + a.width &&
	       a.y < b.y + b.height &&
	       b.y < a.y + a.height
}

// owned_range bounds a layer's instance range to the list that exists. A cached list is appended
// whole, so this only guards a report against a layer that outlived its instances.
@(private, require_results)
owned_range :: proc(start, count, length: int) -> (first, last: int) {
	first = clamp(start, 0, length)
	return first, clamp(start + count, first, length)
}

@(private)
write_rects :: proc(
	out: ^strings.Builder,
	list: ^render.Draw_List,
	layer: render.Layer,
	region: render.Rect,
) {
	first, last := owned_range(layer.rect_start, layer.rect_count, len(list.rects))
	for i in first ..< last {
		instance := list.rects[i]
		if !intersects(instance.rect, region) {continue}
		fmt.sbprintf(
			out,
			"rect %d %d,%d %dx%d %s radius=%g\n",
			i,
			rounded(instance.rect.x),
			rounded(instance.rect.y),
			rounded(instance.rect.width),
			rounded(instance.rect.height),
			format_color(instance.color),
			instance.radius,
		)
	}
}

@(private)
write_glyphs :: proc(
	out: ^strings.Builder,
	list: ^render.Draw_List,
	layer: render.Layer,
	region: render.Rect,
) {
	first, last := owned_range(layer.glyph_start, layer.glyph_count, len(list.glyphs))
	for i in first ..< last {
		instance := list.glyphs[i]
		if !intersects(instance.rect, region) {continue}
		fmt.sbprintf(
			out,
			"glyph %d %d,%d %dx%d %s flags=%d\n",
			i,
			rounded(instance.rect.x),
			rounded(instance.rect.y),
			rounded(instance.rect.width),
			rounded(instance.rect.height),
			format_color(instance.color),
			instance.flags,
		)
	}
}
