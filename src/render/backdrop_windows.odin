package render

import "core:math"
import d3d "vendor:directx/d3d11"
import "vendor:directx/dxgi"

// Backdrop blur (Layer.blur): the target's pixels under a layer's clip, and as far around it as the blur
// reaches, are copied out, blurred across into a second texture, then blurred down back into the target
// inside the clip. The two textures grow to the largest region asked for and take the target's format,
// which the copy needs.
@(private)
Backdrop :: struct {
	source, pass:           ^d3d.ITexture2D,
	source_view, pass_view: ^d3d.IShaderResourceView,
	pass_target:            ^d3d.IRenderTargetView,
	width, height:          u32,
	format:                 dxgi.FORMAT,
}

// The largest standard deviation a blur takes, in pixels, which bounds its samples per pixel.
BACKDROP_BLUR_MAX :: f32(24)

@(private)
backdrop_release :: proc(b: ^Backdrop) {
	release(b.pass_target)
	release(b.pass_view)
	release(b.source_view)
	release(b.pass)
	release(b.source)
	b^ = {}
}

@(private, require_results)
backdrop_ensure :: proc(d: ^Device, format: dxgi.FORMAT, width, height: u32) -> Error {
	b := &d.backdrop
	if b.source != nil && b.format == format && b.width >= width && b.height >= height {return .None}
	grown_width, grown_height := width, height
	if b.source != nil && b.format == format {
		grown_width, grown_height = max(width, b.width), max(height, b.height)
	}
	backdrop_release(b)
	desc := d3d.TEXTURE2D_DESC {
		Width = grown_width,
		Height = grown_height,
		MipLevels = 1,
		ArraySize = 1,
		Format = format,
		SampleDesc = {Count = 1},
		BindFlags = {.SHADER_RESOURCE},
	}
	made := Backdrop {
		width  = grown_width,
		height = grown_height,
		format = format,
	}
	ok := false
	defer if !ok {backdrop_release(&made)}
	if err := checked(d, d.native->CreateTexture2D(&desc, nil, &made.source), "CreateTexture2D backdrop");
	   err != .None {return err}
	hr := d.native->CreateShaderResourceView(made.source, nil, &made.source_view)
	if err := checked(d, hr, "CreateShaderResourceView backdrop"); err != .None {return err}
	desc.BindFlags = {.SHADER_RESOURCE, .RENDER_TARGET}
	hr = d.native->CreateTexture2D(&desc, nil, &made.pass)
	if err := checked(d, hr, "CreateTexture2D backdrop pass"); err != .None {return err}
	hr = d.native->CreateShaderResourceView(made.pass, nil, &made.pass_view)
	if err := checked(d, hr, "CreateShaderResourceView backdrop pass"); err != .None {return err}
	hr = d.native->CreateRenderTargetView(made.pass, nil, &made.pass_target)
	if err := checked(d, hr, "CreateRenderTargetView backdrop pass"); err != .None {return err}
	ok = true
	b^ = made
	return .None
}

// Blurs `target`, a width x height render target, inside `layer`'s clip. It leaves `target` bound with a
// full viewport; the caller sets the scissor, shaders and constants of what it draws next.
@(private, require_results)
backdrop_blur :: proc(
	d: ^Device,
	target: ^d3d.IRenderTargetView,
	width, height: i32,
	layer: Layer,
	constants: Frame_Constants,
) -> Error {
	clip := scissor(layer.clip, f32(width), f32(height))
	if clip.right <= clip.left || clip.bottom <= clip.top {return .None}
	sigma := min(layer.blur, BACKDROP_BLUR_MAX)
	reach := i32(math.ceil(3 * sigma))
	region := d3d.BOX {
		left   = u32(max(clip.left - reach, 0)),
		top    = u32(max(clip.top - reach, 0)),
		right  = u32(min(clip.right + reach, width)),
		bottom = u32(min(clip.bottom + reach, height)),
		back   = 1,
	}
	region_width, region_height := region.right - region.left, region.bottom - region.top
	resource: ^d3d.IResource
	target->GetResource(&resource)
	defer release(resource)
	texture: ^d3d.ITexture2D
	hr := resource->QueryInterface(d3d.ITexture2D_UUID, (^rawptr)(&texture))
	if err := checked(d, hr, "QueryInterface ID3D11Texture2D backdrop"); err != .None {return err}
	desc: d3d.TEXTURE2D_DESC
	texture->GetDesc(&desc)
	release(texture)
	if err := backdrop_ensure(d, desc.Format, region_width, region_height); err != .None {return err}
	b := &d.backdrop
	c := d.ctx
	c->CopySubresourceRegion(b.source, 0, 0, 0, 0, resource, 0, &region)

	size := [2]f32{f32(b.width), f32(b.height)}
	k := constants
	// The texel centres of the region copied, as a rect.
	k.blur_limit = {
		0.5 / size.x,
		0.5 / size.y,
		(f32(region_width) - 1) / size.x,
		(f32(region_height) - 1) / size.y,
	}
	// Across, from the copy into the pass texture, over the whole region.
	k.target_size = size
	k.round_clip, k.clip_radius = {}, 0
	k.image_rect = {0, 0, f32(region_width), f32(region_height)}
	k.image_uv = {0, 0, f32(region_width) / size.x, f32(region_height) / size.y}
	k.blur = {1 / size.x, 0, sigma, 0}
	if err := constants_write(d, &k); err != .None {return err}
	pass := b.pass_target
	c->OMSetRenderTargets(1, &pass, nil)
	transparent := Color{}
	c->ClearRenderTargetView(pass, &transparent)
	viewport := d3d.VIEWPORT {
		Width    = size.x,
		Height   = size.y,
		MaxDepth = 1,
	}
	c->RSSetViewports(1, &viewport)
	whole := d3d.RECT{0, 0, i32(region_width), i32(region_height)}
	c->RSSetScissorRects(1, &whole)
	c->VSSetShader(d.image_vs, nil, 0)
	c->PSSetShader(d.blur_ps, nil, 0)
	c->PSSetShaderResources(4, 1, &b.source_view)
	c->DrawInstanced(6, 1, 0, 0)
	unbound: ^d3d.IShaderResourceView
	c->PSSetShaderResources(4, 1, &unbound)

	// Down, from the pass texture into the target, inside the clip.
	target := target
	c->OMSetRenderTargets(1, &target, nil)
	viewport = {
		Width    = f32(width),
		Height   = f32(height),
		MaxDepth = 1,
	}
	c->RSSetViewports(1, &viewport)
	c->RSSetScissorRects(1, &clip)
	clip_width, clip_height := f32(clip.right - clip.left), f32(clip.bottom - clip.top)
	k.target_size = {f32(width), f32(height)}
	k.round_clip, k.clip_radius = layer.clip, layer.radius
	k.image_rect = {f32(clip.left), f32(clip.top), clip_width, clip_height}
	k.image_uv = {
		f32(u32(clip.left) - region.left) / size.x,
		f32(u32(clip.top) - region.top) / size.y,
		clip_width / size.x,
		clip_height / size.y,
	}
	k.blur = {0, 1 / size.y, sigma, 0}
	if err := constants_write(d, &k); err != .None {return err}
	c->PSSetShaderResources(4, 1, &b.pass_view)
	c->DrawInstanced(6, 1, 0, 0)
	c->PSSetShaderResources(4, 1, &unbound)
	return .None
}
