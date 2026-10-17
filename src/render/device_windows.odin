package render

import "base:runtime"
import "core:log"
import win "core:sys/windows"
import d3d "vendor:directx/d3d11"
import compiler "vendor:directx/d3d_compiler"
import "vendor:directx/dxgi"

@(private) ATLAS_INITIAL_SIZE :: 2048
@(private) ATLAS_MAX_SIZE :: 4096

Device :: struct {
	allocator: runtime.Allocator,
	native: ^d3d.IDevice,
	ctx: ^d3d.IDeviceContext,
	factory: ^dxgi.IFactory2,
	rect_vs, glyph_vs: ^d3d.IVertexShader,
	rect_ps, glyph_ps: ^d3d.IPixelShader,
	blend: ^d3d.IBlendState,
	rasterizer: ^d3d.IRasterizerState,
	constants: ^d3d.IBuffer,
	rects, glyphs: Instance_Buffer,
	atlas: ^d3d.ITexture2D,
	atlas_view: ^d3d.IShaderResourceView,
	atlas_size, shelf_x, shelf_y, shelf_height: i32,
	generation: u64,
	gamma: Text_Gamma,
}

@(private)
Instance_Buffer :: struct {
	buffer: ^d3d.IBuffer,
	view: ^d3d.IShaderResourceView,
	capacity: int,
}

@(private)
Frame_Constants :: struct {
	gamma_ratios: [4]f32,
	target_size: [2]f32,
	enhanced_contrast: f32,
	rect_start, glyph_start: u32,
	_: [3]f32,
}

@(private)
release :: proc(p: ^$T) {
	if p != nil {
		(^win.IUnknown)(p)->Release()
	}
}

@(private, require_results)
checked :: proc(d: ^Device, hr: win.HRESULT, call: string, failure: Error = .Device_Failed) -> Error {
	if hr >= 0 {
		return .None
	}
	log.errorf("%s failed: HRESULT 0x%08x", call, u32(hr))
	switch hr {
	case dxgi.ERROR_DEVICE_REMOVED, dxgi.ERROR_DEVICE_RESET, dxgi.ERROR_DEVICE_HUNG:
		return .Device_Lost
	}
	if d != nil && d.native != nil && d.native->GetDeviceRemovedReason() < 0 {
		return .Device_Lost
	}
	return failure
}

@(private, require_results)
compile_shader :: proc(entry, target: cstring) -> (^compiler.ID3DBlob, Error) {
	source :: #load("shaders/draw.hlsl", string)
	code, diagnostics: ^compiler.ID3DBlob
	hr := compiler.Compile(
		raw_data(source), len(source), "draw.hlsl", nil, nil, entry, target, 0, 0, &code, &diagnostics,
	)
	defer release(diagnostics)
	if hr < 0 {
		if diagnostics != nil {
			text := ([^]u8)(diagnostics->GetBufferPointer())[:diagnostics->GetBufferSize()]
			log.errorf("D3DCompile %s: %s", entry, string(text))
		}
		release(code)
		return nil, checked(nil, hr, "D3DCompile", .Shader_Failed)
	}
	return code, .None
}

@(private, require_results)
vertex_shader :: proc(d: ^Device, entry: cstring) -> (^d3d.IVertexShader, Error) {
	blob, err := compile_shader(entry, "vs_5_0")
	if err != .None {
		return nil, err
	}
	defer release(blob)
	shader: ^d3d.IVertexShader
	hr := d.native->CreateVertexShader(blob->GetBufferPointer(), blob->GetBufferSize(), nil, &shader)
	return shader, checked(d, hr, "CreateVertexShader")
}

@(private, require_results)
pixel_shader :: proc(d: ^Device, entry: cstring) -> (^d3d.IPixelShader, Error) {
	blob, err := compile_shader(entry, "ps_5_0")
	if err != .None {
		return nil, err
	}
	defer release(blob)
	shader: ^d3d.IPixelShader
	hr := d.native->CreatePixelShader(blob->GetBufferPointer(), blob->GetBufferSize(), nil, &shader)
	return shader, checked(d, hr, "CreatePixelShader")
}

@(private)
create_native_device :: proc(d: ^Device) -> win.HRESULT {
	levels := [?]d3d.FEATURE_LEVEL{._11_0}
	hr: win.HRESULT
	for driver in ([?]d3d.DRIVER_TYPE{.HARDWARE, .WARP}) {
		flags: d3d.CREATE_DEVICE_FLAGS = {.BGRA_SUPPORT}
		when ODIN_DEBUG {
			flags += {.DEBUG}
		}
		for {
			hr = d3d.CreateDevice(
				nil, driver, nil, flags, raw_data(levels[:]), len(levels), d3d.SDK_VERSION,
				&d.native, nil, &d.ctx,
			)
			// The debug layer is optional; it is missing when the Graphics Tools feature is not installed.
			if hr != dxgi.ERROR_SDK_COMPONENT_MISSING || .DEBUG not_in flags {
				break
			}
			flags -= {.DEBUG}
		}
		if hr >= 0 {
			return hr
		}
		log.warnf("D3D11CreateDevice (%v) failed: HRESULT 0x%08x", driver, u32(hr))
	}
	return hr
}

@(require_results)
device_create :: proc(allocator := context.allocator) -> (^Device, Error) {
	d, allocation_error := new(Device, allocator)
	if allocation_error != nil {
		return nil, .Out_Of_Memory
	}
	d.allocator = allocator
	d.generation = 1
	d.gamma = DEFAULT_TEXT_GAMMA
	ok := false
	defer if !ok {
		device_destroy(d)
	}
	if err := checked(d, create_native_device(d), "D3D11CreateDevice"); err != .None {
		return nil, err
	}
	dxgi_device: ^dxgi.IDevice
	hr := d.native->QueryInterface(dxgi.IDevice_UUID, (^rawptr)(&dxgi_device))
	if err := checked(d, hr, "QueryInterface IDXGIDevice"); err != .None {
		return nil, err
	}
	defer release(dxgi_device)
	adapter: ^dxgi.IAdapter
	if err := checked(d, dxgi_device->GetAdapter(&adapter), "GetAdapter"); err != .None {
		return nil, err
	}
	defer release(adapter)
	hr = adapter->GetParent(dxgi.IFactory2_UUID, (^rawptr)(&d.factory))
	if err := checked(d, hr, "GetParent IDXGIFactory2"); err != .None {
		return nil, err
	}
	err: Error
	if d.rect_vs, err = vertex_shader(d, "rect_vs"); err != .None {
		return nil, err
	}
	if d.glyph_vs, err = vertex_shader(d, "glyph_vs"); err != .None {
		return nil, err
	}
	if d.rect_ps, err = pixel_shader(d, "rect_ps"); err != .None {
		return nil, err
	}
	if d.glyph_ps, err = pixel_shader(d, "glyph_ps"); err != .None {
		return nil, err
	}
	blend: d3d.BLEND_DESC
	blend.RenderTarget[0] = {
		BlendEnable = true,
		SrcBlend = .ONE,
		DestBlend = .INV_SRC_ALPHA,
		BlendOp = .ADD,
		SrcBlendAlpha = .ONE,
		DestBlendAlpha = .INV_SRC_ALPHA,
		BlendOpAlpha = .ADD,
		RenderTargetWriteMask = u8(d3d.COLOR_WRITE_ENABLE_ALL),
	}
	if err = checked(d, d.native->CreateBlendState(&blend, &d.blend), "CreateBlendState"); err != .None {
		return nil, err
	}
	rasterizer := d3d.RASTERIZER_DESC{FillMode = .SOLID, CullMode = .NONE, ScissorEnable = true}
	hr = d.native->CreateRasterizerState(&rasterizer, &d.rasterizer)
	if err = checked(d, hr, "CreateRasterizerState"); err != .None {
		return nil, err
	}
	constants := d3d.BUFFER_DESC{
		ByteWidth = size_of(Frame_Constants),
		Usage = .DYNAMIC,
		BindFlags = {.CONSTANT_BUFFER},
		CPUAccessFlags = {.WRITE},
	}
	if err = checked(d, d.native->CreateBuffer(&constants, nil, &d.constants), "CreateBuffer"); err != .None {
		return nil, err
	}
	if err = atlas_create(d, ATLAS_INITIAL_SIZE); err != .None {
		return nil, err
	}
	ok = true
	return d, .None
}

device_destroy :: proc(d: ^Device) {
	if d.ctx != nil {
		d.ctx->ClearState()
	}
	release(d.rects.view)
	release(d.rects.buffer)
	release(d.glyphs.view)
	release(d.glyphs.buffer)
	release(d.atlas_view)
	release(d.atlas)
	release(d.constants)
	release(d.rasterizer)
	release(d.blend)
	release(d.rect_vs)
	release(d.glyph_vs)
	release(d.rect_ps)
	release(d.glyph_ps)
	release(d.factory)
	release(d.ctx)
	release(d.native)
	free(d, d.allocator)
}

set_text_gamma :: proc(d: ^Device, gamma: Text_Gamma) {
	d.gamma = {gamma = clamp(gamma.gamma, 1, 2.2), enhanced_contrast = max(gamma.enhanced_contrast, 0)}
}

@(private, require_results)
atlas_create :: proc(d: ^Device, size: i32) -> Error {
	desc := d3d.TEXTURE2D_DESC{
		Width = u32(size),
		Height = u32(size),
		MipLevels = 1,
		ArraySize = 1,
		Format = .R8_UNORM,
		SampleDesc = {Count = 1},
		BindFlags = {.SHADER_RESOURCE},
	}
	texture: ^d3d.ITexture2D
	hr := d.native->CreateTexture2D(&desc, nil, &texture)
	if err := checked(d, hr, "CreateTexture2D atlas"); err != .None {
		return err
	}
	view: ^d3d.IShaderResourceView
	hr = d.native->CreateShaderResourceView(texture, nil, &view)
	if err := checked(d, hr, "CreateShaderResourceView atlas"); err != .None {
		release(texture)
		return err
	}
	if d.atlas != nil {
		box := d3d.BOX{right = u32(d.atlas_size), bottom = u32(d.atlas_size), back = 1}
		d.ctx->CopySubresourceRegion(texture, 0, 0, 0, 0, d.atlas, 0, &box)
	}
	release(d.atlas_view)
	release(d.atlas)
	d.atlas, d.atlas_view, d.atlas_size = texture, view, size
	return .None
}

@(private)
shelf_place :: proc(d: ^Device, width, height: i32) -> (x, y, shelf: i32, fits: bool) {
	x, y, shelf = d.shelf_x, d.shelf_y, d.shelf_height
	if x + width > d.atlas_size {
		x, y, shelf = 0, y + shelf, 0
	}
	return x, y, shelf, width <= d.atlas_size && y + height <= d.atlas_size
}

@(require_results)
atlas_reserve :: proc(d: ^Device, width, height: i32) -> (Atlas_Slot, bool) {
	assert(width > 0 && height > 0)
	x, y, shelf, fits := shelf_place(d, width, height)
	if !fits {
		if d.atlas_size == ATLAS_MAX_SIZE || atlas_create(d, ATLAS_MAX_SIZE) != .None {
			return {}, false
		}
		x, y, shelf, fits = shelf_place(d, width, height)
		if !fits {
			return {}, false
		}
	}
	d.shelf_x, d.shelf_y, d.shelf_height = x + width, y, max(shelf, height)
	return {x, y, width, height, d.generation}, true
}

atlas_upload :: proc(d: ^Device, slot: Atlas_Slot, pixels: []u8, stride: int) {
	assert(slot.generation == d.generation, "atlas slot from a previous generation")
	assert(stride >= int(slot.width) && len(pixels) >= stride * int(slot.height - 1) + int(slot.width))
	box := d3d.BOX{
		left = u32(slot.x),
		top = u32(slot.y),
		right = u32(slot.x + slot.width),
		bottom = u32(slot.y + slot.height),
		back = 1,
	}
	d.ctx->UpdateSubresource(d.atlas, 0, &box, raw_data(pixels), u32(stride), 0)
}

atlas_reset :: proc(d: ^Device) {
	d.shelf_x, d.shelf_y, d.shelf_height = 0, 0, 0
	d.generation += 1
}

atlas_generation :: proc(d: ^Device) -> u64 {
	return d.generation
}
