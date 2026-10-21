package render

import "base:runtime"
import "core:log"
import "core:mem"
import win "core:sys/windows"
import d3d "vendor:directx/d3d11"
import "vendor:directx/dxgi"

@(private)
MAX_SURFACE_SIZE :: d3d.REQ_TEXTURE2D_U_OR_V_DIMENSION
@(private)
SWAP_CHAIN_BUFFERS :: 2

Surface :: struct {
	allocator:     runtime.Allocator,
	owner:         ^Device,
	texture:       ^d3d.ITexture2D,
	target:        ^d3d.IRenderTargetView,
	chain:         ^dxgi.ISwapChain2,
	waitable:      win.HANDLE,
	width, height: i32,
}

@(private)
valid_size :: proc(width, height: i32) -> bool {
	return width > 0 && height > 0 && width <= MAX_SURFACE_SIZE && height <= MAX_SURFACE_SIZE
}

@(require_results)
surface_present_count :: proc(s: ^Surface) -> (u32, Error) {
	if s == nil || s.chain == nil {return 0, .Invalid_Argument}
	count: u32
	err := checked(
		s.owner,
		s.chain->GetLastPresentCount(&count),
		"GetLastPresentCount",
		.Surface_Failed,
	)
	return count, err
}

@(require_results)
surface_create_offscreen :: proc(d: ^Device, width, height: i32) -> (^Surface, Error) {
	return surface_create(d, nil, width, height)
}

@(require_results)
surface_create :: proc(
	d: ^Device,
	native_window: rawptr,
	width, height: i32,
) -> (
	^Surface,
	Error,
) {
	if !valid_size(width, height) {
		return nil, .Invalid_Argument
	}
	s, allocation_error := new(Surface, d.allocator)
	if allocation_error != nil {
		return nil, .Out_Of_Memory
	}
	s.allocator, s.owner = d.allocator, d
	ok := false
	defer if !ok {
		surface_destroy(s)
	}
	if native_window != nil {
		if err := swap_chain_create(d, s, win.HWND(native_window), width, height); err != .None {
			return nil, err
		}
	}
	if err := surface_target_create(s, width, height); err != .None {
		return nil, err
	}
	ok = true
	return s, .None
}

@(private, require_results)
swap_chain_create :: proc(d: ^Device, s: ^Surface, window: win.HWND, width, height: i32) -> Error {
	desc := dxgi.SWAP_CHAIN_DESC1 {
		Width = u32(width),
		Height = u32(height),
		Format = .B8G8R8A8_UNORM,
		SampleDesc = {Count = 1},
		BufferUsage = {.RENDER_TARGET_OUTPUT},
		BufferCount = SWAP_CHAIN_BUFFERS,
		Scaling = .NONE,
		SwapEffect = .FLIP_DISCARD,
		AlphaMode = .IGNORE,
		Flags = {.FRAME_LATENCY_WAITABLE_OBJECT},
	}
	chain: ^dxgi.ISwapChain1
	hr := d.factory->CreateSwapChainForHwnd(d.native, window, &desc, nil, nil, &chain)
	if err := checked(d, hr, "CreateSwapChainForHwnd", .Surface_Failed); err != .None {
		return err
	}
	defer release(chain)
	hr = chain->QueryInterface(dxgi.ISwapChain2_UUID, (^rawptr)(&s.chain))
	if err := checked(d, hr, "QueryInterface IDXGISwapChain2", .Surface_Failed); err != .None {
		return err
	}
	hr = d.factory->MakeWindowAssociation(window, {.NO_ALT_ENTER})
	if err := checked(d, hr, "MakeWindowAssociation", .Surface_Failed); err != .None {
		return err
	}
	hr = s.chain->SetMaximumFrameLatency(1)
	if err := checked(d, hr, "SetMaximumFrameLatency", .Surface_Failed); err != .None {
		return err
	}
	s.waitable = s.chain->GetFrameLatencyWaitableObject()
	if s.waitable == nil {
		log.errorf("GetFrameLatencyWaitableObject failed: %d", win.GetLastError())
		return .Surface_Failed
	}
	return .None
}

@(private, require_results)
surface_target_create :: proc(s: ^Surface, width, height: i32) -> Error {
	d := s.owner
	texture: ^d3d.ITexture2D
	if s.chain != nil {
		hr := s.chain->GetBuffer(0, d3d.ITexture2D_UUID, (^rawptr)(&texture))
		if err := checked(d, hr, "GetBuffer", .Surface_Failed); err != .None {
			return err
		}
	} else {
		desc := d3d.TEXTURE2D_DESC {
			Width = u32(width),
			Height = u32(height),
			MipLevels = 1,
			ArraySize = 1,
			Format = .B8G8R8A8_UNORM,
			SampleDesc = {Count = 1},
			BindFlags = {.RENDER_TARGET},
		}
		hr := d.native->CreateTexture2D(&desc, nil, &texture)
		if err := checked(d, hr, "CreateTexture2D surface", .Surface_Failed); err != .None {
			return err
		}
	}
	target: ^d3d.IRenderTargetView
	hr := d.native->CreateRenderTargetView(texture, nil, &target)
	if err := checked(d, hr, "CreateRenderTargetView", .Surface_Failed); err != .None {
		release(texture)
		return err
	}
	release(s.target)
	release(s.texture)
	s.texture, s.target, s.width, s.height = texture, target, width, height
	return .None
}

@(require_results)
surface_resize :: proc(d: ^Device, s: ^Surface, width, height: i32) -> Error {
	assert(s.owner == d)
	if !valid_size(width, height) {
		return .Invalid_Argument
	}
	if width == s.width && height == s.height {
		return .None
	}
	release(s.target)
	release(s.texture)
	s.target, s.texture = nil, nil
	if s.chain != nil {
		// DXGI requires every reference to the back buffers to be gone, including deferred ones.
		d.ctx->ClearState()
		d.ctx->Flush()
		hr := s.chain->ResizeBuffers(
			SWAP_CHAIN_BUFFERS,
			u32(width),
			u32(height),
			.B8G8R8A8_UNORM,
			{.FRAME_LATENCY_WAITABLE_OBJECT},
		)
		if err := checked(d, hr, "ResizeBuffers", .Surface_Failed); err != .None {
			return err
		}
	}
	return surface_target_create(s, width, height)
}

surface_destroy :: proc(s: ^Surface) {
	if s.owner.ctx != nil {
		s.owner.ctx->ClearState()
	}
	release(s.target)
	release(s.texture)
	if s.waitable != nil && !win.CloseHandle(s.waitable) {
		log.errorf("CloseHandle frame latency waitable failed: %d", win.GetLastError())
	}
	release(s.chain)
	free(s, s.allocator)
}

@(require_results)
frame_wait :: proc(s: ^Surface, timeout_ms: u32) -> Error {
	if s.waitable == nil {
		return .None
	}
	switch win.WaitForSingleObject(s.waitable, timeout_ms) {
	case win.WAIT_OBJECT_0:
		return .None
	case win.WAIT_TIMEOUT:
		return .Timeout
	case:
		log.errorf("WaitForSingleObject frame latency failed: %d", win.GetLastError())
		return .Wait_Failed
	}
}

@(require_results)
surface_read_pixels :: proc(
	d: ^Device,
	s: ^Surface,
	allocator: runtime.Allocator,
) -> (
	[]u8,
	Error,
) {
	assert(s.owner == d)
	desc := d3d.TEXTURE2D_DESC {
		Width = u32(s.width),
		Height = u32(s.height),
		MipLevels = 1,
		ArraySize = 1,
		Format = .B8G8R8A8_UNORM,
		SampleDesc = {Count = 1},
		Usage = .STAGING,
		CPUAccessFlags = {.READ},
	}
	staging: ^d3d.ITexture2D
	hr := d.native->CreateTexture2D(&desc, nil, &staging)
	if err := checked(d, hr, "CreateTexture2D readback", .Surface_Failed); err != .None {
		return nil, err
	}
	defer release(staging)
	d.ctx->CopyResource(staging, s.texture)
	mapped: d3d.MAPPED_SUBRESOURCE
	hr = d.ctx->Map(staging, 0, .READ, {}, &mapped)
	if err := checked(d, hr, "Map readback", .Surface_Failed); err != .None {
		return nil, err
	}
	defer d.ctx->Unmap(staging, 0)
	row_bytes := int(s.width) * 4
	pixels, allocation_error := make([]u8, row_bytes * int(s.height), allocator)
	if allocation_error != nil {
		return nil, .Out_Of_Memory
	}
	source := ([^]u8)(mapped.pData)
	for y in 0 ..< int(s.height) {
		mem.copy(&pixels[y * row_bytes], &source[y * int(mapped.RowPitch)], row_bytes)
	}
	return pixels, .None
}
