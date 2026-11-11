package render

import "base:runtime"
import "core:log"
import "core:strconv"
import "core:thread"
import win "core:sys/windows"
import d3d "vendor:directx/d3d11"
import compiler "vendor:directx/d3d_compiler"
import "vendor:directx/dxgi"

@(private)
ATLAS_INITIAL_SIZE :: 2048
@(private)
ATLAS_MAX_SIZE :: 4096
@(private)
COLOR_ATLAS_INITIAL_SIZE :: 1024

// Which rasterizer a device draws with. Auto prefers the GPU and falls back to WARP, Microsoft's
// software rasterizer. Tests that read pixels back ask for Warp, so their results do not depend on
// the machine's GPU.
Driver :: enum {
	Auto,
	Hardware,
	Warp,
}

// DXGI's adapter description is at most 128 UTF-16 units, each at most three UTF-8 bytes.
@(private)
ADAPTER_NAME_BYTES :: 128 * 3

Device :: struct {
	allocator:          runtime.Allocator,
	native:             ^d3d.IDevice,
	ctx:                ^d3d.IDeviceContext,
	factory:            ^dxgi.IFactory2,
	rect_vs, glyph_vs:  ^d3d.IVertexShader,
	rect_ps, glyph_ps:  ^d3d.IPixelShader,
	image_vs:           ^d3d.IVertexShader,
	image_ps:           ^d3d.IPixelShader,
	image_sampler:      ^d3d.ISamplerState,
	images:             map[u64]Image_Texture,
	image_bytes:        int,
	image_budget:       int,
	image_frame:        u64,
	image_epoch:        u64,
	blend:              ^d3d.IBlendState,
	rasterizer:         ^d3d.IRasterizerState,
	constants:          ^d3d.IBuffer,
	rects, glyphs:      Instance_Buffer,
	atlas, color_atlas: Atlas,
	generation:         u64,
	gamma:              Text_Gamma,
	// The driver the device was made with, never Auto, and the adapter's description.
	driver:             Driver,
	adapter_name:       [ADAPTER_NAME_BYTES]u8,
	adapter_length:     int,
	// The driver reported the device removed or reset. Nothing new can be made on it, so creation
	// refuses at once instead of calling, and logging, into a device that cannot recover.
	lost:               bool,
}

@(private)
Atlas :: struct {
	texture:                              ^d3d.ITexture2D,
	view:                                 ^d3d.IShaderResourceView,
	size, shelf_x, shelf_y, shelf_height: i32,
	color:                                bool,
}

@(private)
Instance_Buffer :: struct {
	buffer:   ^d3d.IBuffer,
	view:     ^d3d.IShaderResourceView,
	capacity: int,
}

@(private)
Frame_Constants :: struct {
	gamma_ratios:            [4]f32,
	target_size:             [2]f32,
	enhanced_contrast:       f32,
	rect_start, glyph_start: u32,
	_:                       [3]f32,
	round_clip:              Rect,
	clip_radius:             f32,
	_padding:                [3]f32,
	image_rect, image_uv:    Rect,
}

// Frame_Constants is draw.hlsl's `Frame` cbuffer. Constant-buffer packing never lets a vector cross
// a 16-byte register, so the explicit padding keeps round_clip and image_rect on register starts.
#assert(offset_of(Frame_Constants, rect_start) == 28 && offset_of(Frame_Constants, round_clip) == 48)
#assert(offset_of(Frame_Constants, image_rect) == 80 && size_of(Frame_Constants) == 112)

// The draw.hlsl names for the fill and glyph flag values, defined from the Odin constants.
@(private)
Shader_Constant :: struct {
	name:  cstring,
	value: u32,
}

@(private)
SHADER_CONSTANTS :: [?]Shader_Constant {
	{"RECT_FILL_HUE_WHEEL", RECT_FILL_HUE_WHEEL},
	{"RECT_FILL_VALUE_RAMP", RECT_FILL_VALUE_RAMP},
	{"RECT_FILL_RIM", RECT_FILL_RIM},
	{"RECT_FILL_SEGMENT", RECT_FILL_SEGMENT},
	{"RECT_FILL_ARC", RECT_FILL_ARC},
	{"GLYPH_COLOR", GLYPH_COLOR},
	{"GLYPH_FADE", GLYPH_FADE},
}

// Decimal macro text for each shader constant, plus the null entry that ends the macro list.
@(private)
Shader_Macros :: struct {
	digits: [len(SHADER_CONSTANTS)][11]u8,
	macros: [len(SHADER_CONSTANTS) + 1]compiler.SHADER_MACRO,
}

@(private)
shader_macros :: proc(m: ^Shader_Macros) {
	constants := SHADER_CONSTANTS
	for constant, i in constants {
		text := strconv.write_uint(m.digits[i][:10], u64(constant.value), 10)
		m.digits[i][len(text)] = 0
		m.macros[i] = {constant.name, cstring(&m.digits[i][0])}
	}
	m.macros[len(constants)] = {}
}

@(private)
release :: proc(p: ^$T) {
	if p != nil {
		(^win.IUnknown)(p)->Release()
	}
}

@(private, require_results)
checked :: proc(
	d: ^Device,
	hr: win.HRESULT,
	call: string,
	failure: Error = .Device_Failed,
) -> Error {
	if hr >= 0 {
		return .None
	}
	log.errorf("%s failed: HRESULT 0x%08x", call, u32(hr))
	switch hr {
	case dxgi.ERROR_DEVICE_REMOVED, dxgi.ERROR_DEVICE_RESET, dxgi.ERROR_DEVICE_HUNG:
		if d != nil {d.lost = true}
		return .Device_Lost
	}
	if d != nil && d.native != nil && d.native->GetDeviceRemovedReason() < 0 {
		d.lost = true
		return .Device_Lost
	}
	return failure
}

@(private, require_results)
compile_shader :: proc(entry, target: cstring) -> (^compiler.ID3DBlob, Error) {
	source :: #load("shaders/draw.hlsl", string)
	defines: Shader_Macros
	shader_macros(&defines)
	code, diagnostics: ^compiler.ID3DBlob
	hr := compiler.Compile(
		raw_data(source),
		len(source),
		"draw.hlsl",
		&defines.macros[0],
		nil,
		entry,
		target,
		0,
		0,
		&code,
		&diagnostics,
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

// The shaders device_create builds, by entry point and target.
@(private)
Shader_Entry :: enum {
	Rect_VS,
	Glyph_VS,
	Rect_PS,
	Glyph_PS,
	Image_VS,
	Image_PS,
}

@(private, rodata)
SHADER_ENTRIES := [Shader_Entry]struct {
	entry, target: cstring,
} {
	.Rect_VS  = {"rect_vs", "vs_5_0"},
	.Glyph_VS = {"glyph_vs", "vs_5_0"},
	.Rect_PS  = {"rect_ps", "ps_5_0"},
	.Glyph_PS = {"glyph_ps", "ps_5_0"},
	.Image_VS = {"image_vs", "vs_5_0"},
	.Image_PS = {"image_ps", "ps_5_0"},
}

// Compiled shaders. Compiling needs no device and takes about a third as long as the driver
// takes to create one, so device_create compiles on a thread of its own meanwhile.
@(private)
Shader_Code :: struct {
	blobs: [Shader_Entry]^compiler.ID3DBlob,
	err:   Error,
}

@(private)
shader_code_compile :: proc(code: ^Shader_Code) {
	for &blob, entry in code.blobs {
		blob, code.err = compile_shader(SHADER_ENTRIES[entry].entry, SHADER_ENTRIES[entry].target)
		if code.err != .None {return}
	}
}

// shader_code_compile on a thread of its own, whose temporary memory a logged failure may use.
@(private)
shader_code_thread :: proc(code: ^Shader_Code) {
	defer if context.temp_allocator.procedure == runtime.default_temp_allocator_proc {
		runtime.default_temp_allocator_destroy(cast(^runtime.Default_Temp_Allocator)context.temp_allocator.data)
	}
	shader_code_compile(code)
}

@(private)
shader_code_release :: proc(code: ^Shader_Code) {
	for blob in code.blobs {release(blob)}
	code.blobs = {}
}

@(private, require_results)
vertex_shader :: proc(d: ^Device, blob: ^compiler.ID3DBlob) -> (^d3d.IVertexShader, Error) {
	shader: ^d3d.IVertexShader
	hr := d.native->CreateVertexShader(
		blob->GetBufferPointer(),
		blob->GetBufferSize(),
		nil,
		&shader,
	)
	return shader, checked(d, hr, "CreateVertexShader")
}

@(private, require_results)
pixel_shader :: proc(d: ^Device, blob: ^compiler.ID3DBlob) -> (^d3d.IPixelShader, Error) {
	shader: ^d3d.IPixelShader
	hr := d.native->CreatePixelShader(
		blob->GetBufferPointer(),
		blob->GetBufferSize(),
		nil,
		&shader,
	)
	return shader, checked(d, hr, "CreatePixelShader")
}

@(private)
create_native_device :: proc(d: ^Device, choice: Driver) -> win.HRESULT {
	levels := [?]d3d.FEATURE_LEVEL{._11_0}
	order := [?]Driver{.Hardware, .Warp}
	tried := order[:]
	switch choice {
	case .Auto:
	case .Hardware:
		tried = order[:1]
	case .Warp:
		tried = order[1:]
	}
	hr: win.HRESULT
	for driver in tried {
		native: d3d.DRIVER_TYPE = driver == .Warp ? .WARP : .HARDWARE
		flags: d3d.CREATE_DEVICE_FLAGS = {.BGRA_SUPPORT}
		when ODIN_DEBUG {
			flags += {.DEBUG}
		}
		for {
			hr = d3d.CreateDevice(
				nil,
				native,
				nil,
				flags,
				raw_data(levels[:]),
				len(levels),
				d3d.SDK_VERSION,
				&d.native,
				nil,
				&d.ctx,
			)
			// The debug layer is optional; it is missing when the Graphics Tools feature is not installed.
			if hr != dxgi.ERROR_SDK_COMPONENT_MISSING || .DEBUG not_in flags {
				break
			}
			flags -= {.DEBUG}
		}
		if hr >= 0 {
			d.driver = driver
			return hr
		}
		log.warnf("D3D11CreateDevice (%v) failed: HRESULT 0x%08x", driver, u32(hr))
	}
	return hr
}

@(require_results)
device_create :: proc(driver: Driver, allocator := context.allocator) -> (^Device, Error) {
	d, allocation_error := new(Device, allocator)
	if allocation_error != nil {
		return nil, .Out_Of_Memory
	}
	d.allocator = allocator
	d.generation = 1
	d.gamma = DEFAULT_TEXT_GAMMA
	d.images.allocator = allocator
	d.image_budget = IMAGE_BUDGET_BYTES
	ok := false
	defer if !ok {
		device_destroy(d)
	}
	code: Shader_Code
	compiling := thread.create_and_start_with_poly_data(&code, shader_code_thread, context)
	defer {
		if compiling != nil {
			thread.join(compiling)
			thread.destroy(compiling)
		}
		shader_code_release(&code)
	}
	if err := checked(d, create_native_device(d, driver), "D3D11CreateDevice"); err != .None {
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
	description: dxgi.ADAPTER_DESC
	if err := checked(d, adapter->GetDesc(&description), "GetDesc IDXGIAdapter"); err != .None {
		return nil, err
	}
	name := description.Description[:]
	for unit, i in name {
		if unit == 0 {
			name = name[:i]
			break
		}
	}
	d.adapter_length = len(win.utf16_to_utf8_buf(d.adapter_name[:], name))
	log.infof("graphics device: %v driver on %s", d.driver, device_adapter(d))
	hr = adapter->GetParent(dxgi.IFactory2_UUID, (^rawptr)(&d.factory))
	if err := checked(d, hr, "GetParent IDXGIFactory2"); err != .None {
		return nil, err
	}
	if compiling != nil {
		thread.join(compiling)
		thread.destroy(compiling)
		compiling = nil
	} else {
		// Without a thread of their own, the shaders compile now.
		shader_code_compile(&code)
	}
	if code.err != .None {
		return nil, code.err
	}
	err: Error
	if d.rect_vs, err = vertex_shader(d, code.blobs[.Rect_VS]); err != .None {
		return nil, err
	}
	if d.glyph_vs, err = vertex_shader(d, code.blobs[.Glyph_VS]); err != .None {
		return nil, err
	}
	if d.rect_ps, err = pixel_shader(d, code.blobs[.Rect_PS]); err != .None {
		return nil, err
	}
	if d.glyph_ps, err = pixel_shader(d, code.blobs[.Glyph_PS]); err != .None {
		return nil, err
	}
	if d.image_vs, err = vertex_shader(d, code.blobs[.Image_VS]); err != .None {
		return nil, err
	}
	if d.image_ps, err = pixel_shader(d, code.blobs[.Image_PS]); err != .None {
		return nil, err
	}
	sampler := d3d.SAMPLER_DESC {
		Filter         = .MIN_MAG_MIP_LINEAR,
		AddressU       = .CLAMP,
		AddressV       = .CLAMP,
		AddressW       = .CLAMP,
		ComparisonFunc = .NEVER,
		MaxLOD         = d3d.FLOAT32_MAX,
	}
	if err = checked(d, d.native->CreateSamplerState(&sampler, &d.image_sampler), "CreateSamplerState");
	   err != .None {
		return nil, err
	}
	blend: d3d.BLEND_DESC
	blend.RenderTarget[0] = {
		BlendEnable           = true,
		SrcBlend              = .ONE,
		DestBlend             = .INV_SRC_ALPHA,
		BlendOp               = .ADD,
		SrcBlendAlpha         = .ONE,
		DestBlendAlpha        = .INV_SRC_ALPHA,
		BlendOpAlpha          = .ADD,
		RenderTargetWriteMask = u8(d3d.COLOR_WRITE_ENABLE_ALL),
	}
	if err = checked(d, d.native->CreateBlendState(&blend, &d.blend), "CreateBlendState");
	   err != .None {
		return nil, err
	}
	rasterizer := d3d.RASTERIZER_DESC {
		FillMode      = .SOLID,
		CullMode      = .NONE,
		ScissorEnable = true,
	}
	hr = d.native->CreateRasterizerState(&rasterizer, &d.rasterizer)
	if err = checked(d, hr, "CreateRasterizerState"); err != .None {
		return nil, err
	}
	constants := d3d.BUFFER_DESC {
		ByteWidth      = size_of(Frame_Constants),
		Usage          = .DYNAMIC,
		BindFlags      = {.CONSTANT_BUFFER},
		CPUAccessFlags = {.WRITE},
	}
	if err = checked(d, d.native->CreateBuffer(&constants, nil, &d.constants), "CreateBuffer");
	   err != .None {
		return nil, err
	}
	d.color_atlas.color = true
	if err = atlas_create(d, &d.atlas, ATLAS_INITIAL_SIZE); err != .None {
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
	atlas_destroy(&d.atlas)
	atlas_destroy(&d.color_atlas)
	release(d.constants)
	release(d.rasterizer)
	release(d.blend)
	release(d.rect_vs)
	release(d.glyph_vs)
	release(d.rect_ps)
	release(d.glyph_ps)
	images_destroy(d)
	release(d.image_sampler)
	release(d.image_vs)
	release(d.image_ps)
	release(d.factory)
	release(d.ctx)
	release(d.native)
	free(d, d.allocator)
}

// The driver the device was made with: Hardware or Warp, never Auto.
device_driver :: proc(d: ^Device) -> Driver {
	return d.driver
}

// The adapter's description, such as "Microsoft Basic Render Driver" for WARP.
device_adapter :: proc(d: ^Device) -> string {
	return string(d.adapter_name[:d.adapter_length])
}

set_text_gamma :: proc(d: ^Device, gamma: Text_Gamma) {
	d.gamma = {
		gamma             = clamp(gamma.gamma, MIN_TEXT_GAMMA, MAX_TEXT_GAMMA),
		enhanced_contrast = max(gamma.enhanced_contrast, 0),
	}
}

@(private, require_results)
atlas_create :: proc(d: ^Device, a: ^Atlas, size: i32) -> Error {
	desc := d3d.TEXTURE2D_DESC {
		Width = u32(size),
		Height = u32(size),
		MipLevels = 1,
		ArraySize = 1,
		Format = a.color ? .R8G8B8A8_UNORM : .R8_UNORM,
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
	if a.texture != nil {
		box := d3d.BOX {
			right  = u32(a.size),
			bottom = u32(a.size),
			back   = 1,
		}
		d.ctx->CopySubresourceRegion(texture, 0, 0, 0, 0, a.texture, 0, &box)
	}
	release(a.view)
	release(a.texture)
	a.texture, a.view, a.size = texture, view, size
	return .None
}

@(private)
atlas_destroy :: proc(a: ^Atlas) {
	release(a.view)
	release(a.texture)
	a.view, a.texture = nil, nil
}

@(private)
shelf_place :: proc(a: ^Atlas, width, height: i32) -> (x, y, shelf: i32, fits: bool) {
	x, y, shelf = a.shelf_x, a.shelf_y, a.shelf_height
	if x + width > a.size {
		x, y, shelf = 0, y + shelf, 0
	}
	return x, y, shelf, width <= a.size && y + height <= a.size
}

// Reserves space in the coverage atlas, or with color set in the RGBA atlas for color glyphs.
@(require_results)
atlas_reserve :: proc(d: ^Device, width, height: i32, color := false) -> (Atlas_Slot, bool) {
	assert(width > 0 && height > 0)
	a := color ? &d.color_atlas : &d.atlas
	if a.texture == nil && atlas_create(d, a, COLOR_ATLAS_INITIAL_SIZE) != .None {
		return {}, false
	}
	x, y, shelf, fits := shelf_place(a, width, height)
	if !fits {
		if a.size == ATLAS_MAX_SIZE || atlas_create(d, a, ATLAS_MAX_SIZE) != .None {
			return {}, false
		}
		x, y, shelf, fits = shelf_place(a, width, height)
		if !fits {
			return {}, false
		}
	}
	a.shelf_x, a.shelf_y, a.shelf_height = x + width, y, max(shelf, height)
	return {x, y, width, height, d.generation, color}, true
}

// Stride is in pixels: one byte each in the coverage atlas, four (RGBA) in the color atlas.
atlas_upload :: proc(d: ^Device, slot: Atlas_Slot, pixels: []u8, stride: int) {
	assert(slot.generation == d.generation, "atlas slot from a previous generation")
	texel := slot.color ? 4 : 1
	assert(
		stride >= int(slot.width) &&
		len(pixels) >= (stride * int(slot.height - 1) + int(slot.width)) * texel,
	)
	box := d3d.BOX {
		left   = u32(slot.x),
		top    = u32(slot.y),
		right  = u32(slot.x + slot.width),
		bottom = u32(slot.y + slot.height),
		back   = 1,
	}
	a := slot.color ? &d.color_atlas : &d.atlas
	d.ctx->UpdateSubresource(a.texture, 0, &box, raw_data(pixels), u32(stride * texel), 0)
}

// Empties both atlases; slots and entries from earlier generations are invalid.
atlas_reset :: proc(d: ^Device) {
	for a in ([]^Atlas{&d.atlas, &d.color_atlas}) {
		a.shelf_x, a.shelf_y, a.shelf_height = 0, 0, 0
	}
	d.generation += 1
}

atlas_generation :: proc(d: ^Device) -> u64 {
	return d.generation
}

// The one atlas protocol for glyphs and icons: `slot` keeps `pixels` resident in the current atlas
// generation, reserving and uploading again when it belongs to an earlier one. When the atlas is
// full it is reset and the result is .Atlas_Reset: `slot` is untouched, every earlier slot is
// stale, and the frame under construction must be rebuilt. Stride is in pixels, as for upload. A
// zero slot always uploads, because device generations start at 1.
@(require_results)
atlas_ensure :: proc(
	d: ^Device,
	slot: ^Atlas_Slot,
	width, height: i32,
	pixels: []u8,
	stride: int,
	color := false,
) -> (
	Rect,
	Build_Status,
) {
	if slot.generation != d.generation {
		reserved, ok := atlas_reserve(d, width, height, color)
		if !ok {
			atlas_reset(d)
			return {}, .Atlas_Reset
		}
		atlas_upload(d, reserved, pixels, stride)
		slot^ = reserved
	}
	return {f32(slot.x), f32(slot.y), f32(slot.width), f32(slot.height)}, .Ok
}
