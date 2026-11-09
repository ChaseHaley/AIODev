package term_view

import "aio:ghostty"
import "aio:render"
import "aio:term"
import "core:math"

// Makes sure every placement's pixels have a texture. Reading them locks the session again, so this
// only happens for pixels the device has not seen.
@(private)
images_upload :: proc(v: ^View, session: ^term.Session, device: ^render.Device) {
	for p in v.images.placements {
		if render.image_known(device, p.generation) {continue}
		pixels, ok := term.image_pixels(session, p.image_id, p.generation)
		if !ok {continue}
		render.image_upload(device, p.generation, int(p.image_width), int(p.image_height), pixels)
		delete(pixels)
	}
}

@(private)
images_present :: proc(v: ^View, layer: term.Image_Layer) -> bool {
	for p in v.images.placements {
		if p.layer == layer {return true}
	}
	return false
}

// Pushes one z layer's placements, in z order, into the draw list's current layer.
@(private)
images_draw :: proc(v: ^View, b: ^Builder, layer: term.Image_Layer) {
	m := b.metrics
	// A pane's clip also covers its padding and header, which images must leave alone.
	cells := render.Rect {
		b.origin.x,
		b.origin.y,
		f32(b.columns) * m.cell_width,
		f32(b.rows) * m.cell_height,
	}
	for p in v.images.placements {
		if p.layer != layer {continue}
		image_width, image_height := f32(p.image_width), f32(p.image_height)
		// On whole pixels, so an image drawn at its own size samples texel centres exactly.
		placed := render.Rect {
			math.round(b.origin.x + f32(p.column) * m.cell_width + f32(p.offset_x)),
			math.round(b.origin.y + f32(p.row) * m.cell_height + f32(p.offset_y)),
			f32(p.width),
			f32(p.height),
		}
		uv := render.Rect {
			f32(p.source_x) / image_width,
			f32(p.source_y) / image_height,
			f32(p.source_width) / image_width,
			f32(p.source_height) / image_height,
		}
		if visible, visible_uv, ok := quad_clipped(placed, uv, cells); ok {
			_ = render.push_image(b.list, {rect = visible, uv = visible_uv, key = p.generation})
		}
	}
}

@(private, require_results)
quad_clipped :: proc(placed, uv, bounds: render.Rect) -> (render.Rect, render.Rect, bool) {
	left, top := max(placed.x, bounds.x), max(placed.y, bounds.y)
	right := min(placed.x + placed.width, bounds.x + bounds.width)
	bottom := min(placed.y + placed.height, bounds.y + bounds.height)
	if right <= left || bottom <= top {return {}, {}, false}
	scale_x, scale_y := uv.width / placed.width, uv.height / placed.height
	visible := render.Rect{left, top, right - left, bottom - top}
	visible_uv := render.Rect {
		uv.x + (left - placed.x) * scale_x,
		uv.y + (top - placed.y) * scale_y,
		visible.width * scale_x,
		visible.height * scale_y,
	}
	return visible, visible_uv, true
}

// A layer draws rects before images, and underlines, strikethroughs and the block cursor are rects
// that must stay above these images. So backgrounds get their own pass and the rest of the cells
// starts a new layer. Frames without below-text images never pay for the second row walk.
@(private)
images_draw_below_text :: proc(v: ^View, b: ^Builder) {
	for y := 0; ghostty.render_state_row_iterator_next(v.rows); y += 1 {
		row_paints(v, b, y)
		if b.list.error != .None {return}
		row_backgrounds(v, b, b.origin.y + f32(y) * b.metrics.cell_height)
	}
	images_draw(v, b, .Below_Text)
	images_next_layer(b)
	b.backgrounds_drawn = true
	if ghostty.render_state_get(v.state, .Row_Iterator, &v.rows) != .Success {
		b.list.error = .Construction_Failed
	}
}

// Starts another layer with the current layer's clip, so what follows draws over what came before.
@(private)
images_next_layer :: proc(b: ^Builder) {
	current := b.list.layers[len(b.list.layers) - 1]
	_ = render.push_layer(b.list, current.clip, current.radius)
}
