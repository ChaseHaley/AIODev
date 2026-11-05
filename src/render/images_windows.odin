package render

import "core:log"
import d3d "vendor:directx/d3d11"

// Textures for images a program put on the screen. They are keyed by a value the caller guarantees
// is never reused for different pixels, so a stale entry can only waste memory, never draw wrongly.
// Frames normally reference what they need, so anything left unreferenced for a while can go.

// GPU memory kept for images not drawn in the current frame. What is on screen is always kept.
IMAGE_BUDGET_BYTES :: 256 << 20
// How long an undrawn texture survives under budget, so scrolling back and forth does not reupload.
IMAGE_IDLE_FRAMES :: 60

@(private)
Image_Texture :: struct {
	texture:   ^d3d.ITexture2D,
	// Nil records a texture that could not be created, so a frame does not retry and log forever.
	view:      ^d3d.IShaderResourceView,
	bytes:     int,
	last_used: u64,
}

// image_known reports whether image_upload has settled this key, even if the upload failed.
@(require_results)
image_known :: proc(d: ^Device, key: u64) -> bool {
	return key in d.images
}

// image_epoch changes whenever a texture is evicted, so a retained draw list naming it can be rebuilt.
@(require_results)
image_epoch :: proc(d: ^Device) -> u64 {
	return d.image_epoch
}

// image_upload creates a texture from premultiplied RGBA. A failure is recorded and logged here
// rather than returned: one bad image must not stop the terminal drawing.
image_upload :: proc(d: ^Device, key: u64, width, height: int, pixels: []u8) {
	assert(len(pixels) == width * height * 4)
	entry := Image_Texture {
		last_used = d.image_frame,
	}
	if err := image_texture_create(d, &entry, width, height, pixels); err != .None {
		log.errorf("render: creating a %dx%d image texture failed: %v", width, height, err)
		image_release(&entry)
		entry = {
			last_used = d.image_frame,
		}
	}
	d.image_bytes += entry.bytes
	d.images[key] = entry
}

@(private, require_results)
image_texture_create :: proc(
	d: ^Device,
	entry: ^Image_Texture,
	width, height: int,
	pixels: []u8,
) -> Error {
	if width < 1 ||
	   height < 1 ||
	   width > d3d.REQ_TEXTURE2D_U_OR_V_DIMENSION ||
	   height > d3d.REQ_TEXTURE2D_U_OR_V_DIMENSION {
		return .Invalid_Argument
	}
	// A full mip chain keeps a large image from shimmering when placed small; drawn 1:1 it samples
	// the top level exactly.
	desc := d3d.TEXTURE2D_DESC {
		Width = u32(width),
		Height = u32(height),
		MipLevels = 0,
		ArraySize = 1,
		Format = .R8G8B8A8_UNORM,
		SampleDesc = {Count = 1},
		BindFlags = {.SHADER_RESOURCE, .RENDER_TARGET},
		MiscFlags = {.GENERATE_MIPS},
	}
	if err := checked(d, d.native->CreateTexture2D(&desc, nil, &entry.texture), "CreateTexture2D image");
	   err != .None {
		return err
	}
	hr := d.native->CreateShaderResourceView(entry.texture, nil, &entry.view)
	if err := checked(d, hr, "CreateShaderResourceView image"); err != .None {
		return err
	}
	d.ctx->UpdateSubresource(entry.texture, 0, nil, raw_data(pixels), u32(width * 4), 0)
	d.ctx->GenerateMips(entry.view)
	entry.bytes = len(pixels) * 4 / 3
	return .None
}

@(private)
image_release :: proc(entry: ^Image_Texture) {
	release(entry.view)
	release(entry.texture)
	entry.view, entry.texture = nil, nil
}

@(private)
images_destroy :: proc(d: ^Device) {
	for _, &entry in d.images {
		image_release(&entry)
	}
	delete(d.images)
}

// images_evict runs after each frame: the oldest undrawn texture goes first, while it has sat idle
// too long or the budget is exceeded. Anything the frame just drew is out of reach.
@(private)
images_evict :: proc(d: ^Device) {
	for {
		oldest_key, oldest, found := u64(0), max(u64), false
		for key, entry in d.images {
			if entry.last_used < d.image_frame && entry.last_used < oldest {
				oldest_key, oldest, found = key, entry.last_used, true
			}
		}
		if !found {return}
		if d.image_frame - oldest <= IMAGE_IDLE_FRAMES && d.image_bytes <= d.image_budget {return}
		entry := d.images[oldest_key]
		if entry.view != nil {d.image_epoch += 1}
		d.image_bytes -= entry.bytes
		image_release(&entry)
		delete_key(&d.images, oldest_key)
	}
}
