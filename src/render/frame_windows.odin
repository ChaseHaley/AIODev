package render

import "core:math"
import "core:mem"
import d3d "vendor:directx/d3d11"

@(private, require_results)
instance_upload :: proc(d: ^Device, buffer: ^Instance_Buffer, data: []$T) -> Error {
	if len(data) == 0 {
		return .None
	}
	if len(data) > buffer.capacity {
		capacity := max(256, buffer.capacity)
		for capacity < len(data) {
			capacity *= 2
		}
		desc := d3d.BUFFER_DESC {
			ByteWidth           = u32(capacity * size_of(T)),
			Usage               = .DYNAMIC,
			BindFlags           = {.SHADER_RESOURCE},
			CPUAccessFlags      = {.WRITE},
			MiscFlags           = {.BUFFER_STRUCTURED},
			StructureByteStride = size_of(T),
		}
		native: ^d3d.IBuffer
		if err := checked(
			d,
			d.native->CreateBuffer(&desc, nil, &native),
			"CreateBuffer instances",
		); err != .None {
			return err
		}
		view_desc := d3d.SHADER_RESOURCE_VIEW_DESC {
			ViewDimension = .BUFFER,
			Buffer = {NumElements = u32(capacity)},
		}
		view: ^d3d.IShaderResourceView
		hr := d.native->CreateShaderResourceView(native, &view_desc, &view)
		if err := checked(d, hr, "CreateShaderResourceView instances"); err != .None {
			release(native)
			return err
		}
		release(buffer.view)
		release(buffer.buffer)
		buffer^ = {
			buffer   = native,
			view     = view,
			capacity = capacity,
		}
	}
	mapped: d3d.MAPPED_SUBRESOURCE
	hr := d.ctx->Map(buffer.buffer, 0, .WRITE_DISCARD, {}, &mapped)
	if err := checked(d, hr, "Map instances"); err != .None {
		return err
	}
	mem.copy(mapped.pData, raw_data(data), len(data) * size_of(T))
	d.ctx->Unmap(buffer.buffer, 0)
	return .None
}

@(private)
scissor :: proc(clip: Rect, width, height: f32) -> d3d.RECT {
	return {
		left = i32(math.floor(clamp(clip.x, 0, width))),
		top = i32(math.floor(clamp(clip.y, 0, height))),
		right = i32(math.ceil(clamp(clip.x + clip.width, 0, width))),
		bottom = i32(math.ceil(clamp(clip.y + clip.height, 0, height))),
	}
}

@(require_results)
frame_render :: proc(d: ^Device, s: ^Surface, list: ^Draw_List, clear: Color) -> Error {
	assert(s.owner == d)
	d.image_frame += 1
	if err := list_draw(d, s.target, s.width, s.height, list, clear); err != .None {return err}
	images_evict(d)
	if s.chain == nil {
		s.rendered += 1
		return .None
	}
	return checked(d, s.chain->Present(1, {}), "Present", .Surface_Failed)
}

// Draws `list` into `target`, a width x height render target cleared to `clear` first.
@(private, require_results)
list_draw :: proc(
	d: ^Device,
	target: ^d3d.IRenderTargetView,
	width, height: i32,
	list: ^Draw_List,
	clear: Color,
) -> Error {
	if list.error != .None {return list.error}
	if list.atlas_generation != 0 && list.atlas_generation != atlas_generation(d) {
		return .Atlas_Invalidated
	}
	if err := instance_upload(d, &d.rects, list.rects[:]); err != .None {
		return err
	}
	if err := instance_upload(d, &d.glyphs, list.glyphs[:]); err != .None {
		return err
	}
	c := d.ctx
	target := target
	c->OMSetRenderTargets(1, &target, nil)
	premultiplied := Color{clear.r * clear.a, clear.g * clear.a, clear.b * clear.a, clear.a}
	c->ClearRenderTargetView(target, &premultiplied)
	c->OMSetBlendState(d.blend, nil, max(u32))
	c->RSSetState(d.rasterizer)
	viewport := d3d.VIEWPORT {
		Width    = f32(width),
		Height   = f32(height),
		MaxDepth = 1,
	}
	c->RSSetViewports(1, &viewport)
	c->IASetInputLayout(nil)
	c->IASetPrimitiveTopology(.TRIANGLELIST)
	c->VSSetConstantBuffers(0, 1, &d.constants)
	c->PSSetConstantBuffers(0, 1, &d.constants)
	views := [2]^d3d.IShaderResourceView{d.rects.view, d.glyphs.view}
	c->VSSetShaderResources(0, len(views), &views[0])
	atlases := [2]^d3d.IShaderResourceView{d.atlas.view, d.color_atlas.view}
	c->PSSetShaderResources(2, len(atlases), &atlases[0])
	c->PSSetSamplers(0, 1, &d.image_sampler)
	constants := Frame_Constants {
		gamma_ratios      = gamma_ratios(d.gamma.gamma),
		target_size       = {f32(width), f32(height)},
		enhanced_contrast = d.gamma.enhanced_contrast,
	}
	for layer in list.layers {
		clip := scissor(layer.clip, f32(width), f32(height))
		if clip.right <= clip.left || clip.bottom <= clip.top {
			continue
		}
		c->RSSetScissorRects(1, &clip)
		constants.round_clip, constants.clip_radius = layer.clip, layer.radius
		constants.rect_start, constants.glyph_start = u32(layer.rect_start), u32(layer.glyph_start)
		if err := constants_write(d, &constants); err != .None {
			return err
		}
		if layer.rect_count > 0 {
			c->VSSetShader(d.rect_vs, nil, 0)
			c->PSSetShader(d.rect_ps, nil, 0)
			c->DrawInstanced(6, u32(layer.rect_count), 0, 0)
		}
		for instance in list.images[layer.image_start:][:layer.image_count] {
			entry, known := &d.images[instance.key]
			if !known {continue}
			entry.last_used = d.image_frame
			if entry.view == nil || instance.dust.progress >= 1 {continue}
			constants.image_rect, constants.image_uv = instance.rect, instance.uv
			grains: u32
			if instance.dust.progress > 0 {
				// One instance per texel of the part shown; see dust_vs.
				uv := instance.uv
				first := [2]u32{u32(uv.x * f32(entry.width) + 0.5), u32(uv.y * f32(entry.height) + 0.5)}
				columns := u32(uv.width * f32(entry.width) + 0.5)
				rows := u32(uv.height * f32(entry.height) + 0.5)
				dust := instance.dust
				constants.dust = {dust.progress, dust.seed, dust.rise, dust.grain}
				constants.dust_ash = dust.ash
				constants.dust_grid = {first.x, first.y, columns, rows}
				grains = columns * rows
				if grains == 0 {continue}
			}
			if err := constants_write(d, &constants); err != .None {
				return err
			}
			if grains > 0 {
				c->VSSetShader(d.dust_vs, nil, 0)
				c->PSSetShader(d.dust_ps, nil, 0)
				c->VSSetShaderResources(4, 1, &entry.view)
				c->DrawInstanced(6, grains, 0, 0)
			} else {
				c->VSSetShader(d.image_vs, nil, 0)
				c->PSSetShader(d.image_ps, nil, 0)
				c->PSSetShaderResources(4, 1, &entry.view)
				c->DrawInstanced(6, 1, 0, 0)
			}
		}
		if layer.glyph_count > 0 {
			c->VSSetShader(d.glyph_vs, nil, 0)
			c->PSSetShader(d.glyph_ps, nil, 0)
			c->DrawInstanced(6, u32(layer.glyph_count), 0, 0)
		}
	}
	// A texture drawn from here may be the target of a later image_render, which cannot write a texture
	// still bound for reading.
	unbound: ^d3d.IShaderResourceView
	c->VSSetShaderResources(4, 1, &unbound)
	c->PSSetShaderResources(4, 1, &unbound)
	return .None
}

@(private, require_results)
constants_write :: proc(d: ^Device, constants: ^Frame_Constants) -> Error {
	mapped: d3d.MAPPED_SUBRESOURCE
	if err := checked(d, d.ctx->Map(d.constants, 0, .WRITE_DISCARD, {}, &mapped), "Map constants");
	   err != .None {
		return err
	}
	mem.copy(mapped.pData, constants, size_of(constants^))
	d.ctx->Unmap(d.constants, 0)
	return .None
}
