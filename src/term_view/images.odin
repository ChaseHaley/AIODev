package term_view

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
	for p in v.images.placements {
		if p.layer != layer {continue}
		image_width, image_height := f32(p.image_width), f32(p.image_height)
		_ = render.push_image(
			b.list,
			{
				// On whole pixels, so an image drawn at its own size samples texel centres exactly.
				rect = {
					math.round(b.origin.x + f32(p.column) * m.cell_width + f32(p.offset_x)),
					math.round(b.origin.y + f32(p.row) * m.cell_height + f32(p.offset_y)),
					f32(p.width),
					f32(p.height),
				},
				uv = {
					f32(p.source_x) / image_width,
					f32(p.source_y) / image_height,
					f32(p.source_width) / image_width,
					f32(p.source_height) / image_height,
				},
				key = p.generation,
			},
		)
	}
}

// Starts another layer with the current layer's clip, so what follows draws over what came before.
@(private)
images_next_layer :: proc(b: ^Builder) {
	current := b.list.layers[len(b.list.layers) - 1]
	_ = render.push_layer(b.list, current.clip, current.radius)
}
