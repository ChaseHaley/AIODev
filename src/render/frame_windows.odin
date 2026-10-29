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
scissor :: proc(clip: Rect, s: ^Surface) -> d3d.RECT {
	width, height := f32(s.width), f32(s.height)
	return {
		left = i32(math.floor(clamp(clip.x, 0, width))),
		top = i32(math.floor(clamp(clip.y, 0, height))),
		right = i32(math.ceil(clamp(clip.x + clip.width, 0, width))),
		bottom = i32(math.ceil(clamp(clip.y + clip.height, 0, height))),
	}
}

@(require_results)
frame_render :: proc(d: ^Device, s: ^Surface, list: ^Draw_List, clear: Color) -> Error {
	if list.error != .None {return list.error}
	if list.atlas_generation != 0 && list.atlas_generation != atlas_generation(d) {
		return .Atlas_Invalidated
	}
	assert(s.owner == d)
	if err := instance_upload(d, &d.rects, list.rects[:]); err != .None {
		return err
	}
	if err := instance_upload(d, &d.glyphs, list.glyphs[:]); err != .None {
		return err
	}
	c := d.ctx
	c->OMSetRenderTargets(1, &s.target, nil)
	premultiplied := Color{clear.r * clear.a, clear.g * clear.a, clear.b * clear.a, clear.a}
	c->ClearRenderTargetView(s.target, &premultiplied)
	c->OMSetBlendState(d.blend, nil, max(u32))
	c->RSSetState(d.rasterizer)
	viewport := d3d.VIEWPORT {
		Width    = f32(s.width),
		Height   = f32(s.height),
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
	constants := Frame_Constants {
		gamma_ratios      = gamma_ratios(d.gamma.gamma),
		target_size       = {f32(s.width), f32(s.height)},
		enhanced_contrast = d.gamma.enhanced_contrast,
	}
	for layer in list.layers {
		clip := scissor(layer.clip, s)
		if clip.right <= clip.left || clip.bottom <= clip.top {
			continue
		}
		c->RSSetScissorRects(1, &clip)
		constants.round_clip, constants.clip_radius = layer.clip, layer.radius
		constants.rect_start, constants.glyph_start = u32(layer.rect_start), u32(layer.glyph_start)
		mapped: d3d.MAPPED_SUBRESOURCE
		if err := checked(d, c->Map(d.constants, 0, .WRITE_DISCARD, {}, &mapped), "Map constants");
		   err != .None {
			return err
		}
		mem.copy(mapped.pData, &constants, size_of(constants))
		c->Unmap(d.constants, 0)
		if layer.rect_count > 0 {
			c->VSSetShader(d.rect_vs, nil, 0)
			c->PSSetShader(d.rect_ps, nil, 0)
			c->DrawInstanced(6, u32(layer.rect_count), 0, 0)
		}
		if layer.glyph_count > 0 {
			c->VSSetShader(d.glyph_vs, nil, 0)
			c->PSSetShader(d.glyph_ps, nil, 0)
			c->DrawInstanced(6, u32(layer.glyph_count), 0, 0)
		}
	}
	if s.chain == nil {
		return .None
	}
	return checked(d, s.chain->Present(1, {}), "Present", .Surface_Failed)
}
