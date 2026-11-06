package main

import "aio:glyphs"
import "aio:platform"
import "aio:render"
import "core:log"

// Every window draws through its own surface on the app's one graphics device. A window whose
// surface is missing (nil) is blank until its next frame makes the surface again; a resize waits for
// that. Only the procs here write app.device after startup, w.surface and w.surface_failed.

@(require_results)
window_surface_create :: proc(app: ^App, w: ^Window) -> render.Error {
	native := platform.window_native_handle(&app.platform, w.id)
	surface, err := render.surface_create(app.device, native, max(w.width, 1), max(w.height, 1))
	if err != .None {return err}
	w.surface, w.surface_failed = surface, false
	for &pane in w.views {pane.valid = false}
	w.dirty = true
	return .None
}

// The window keeps asking for a frame, which is what makes the surface again.
window_surface_release :: proc(w: ^Window) {
	if w.surface != nil {render.surface_destroy(w.surface)}
	w.surface = nil
	w.dirty = true
}

// Whether the window can draw, making a missing surface first. A device lost again, as it can be
// while the driver is still resetting, starts another recovery. Any other failure is reported once
// and waits for a resize or a new device.
@(require_results)
window_surface_ready :: proc(app: ^App, w: ^Window) -> bool {
	if w.surface != nil {return true}
	if w.surface_failed || !app.running {return false}
	#partial switch err := window_surface_create(app, w); err {
	case .None:
		return true
	case .Device_Lost:
		recover_device(app)
		return w.surface != nil
	case:
		window_surface_failed(w, err)
	}
	return false
}

@(private)
window_surface_resize :: proc(app: ^App, w: ^Window, width, height: i32) {
	if w.surface == nil {
		w.surface_failed = false
		return
	}
	if err := render.surface_resize(app.device, w.surface, width, height); err != .None {
		log.errorf("resizing the window surface failed: %v", err)
		if err == .Device_Lost {recover_device(app)}
	}
}

// Rebuilds every graphics object after the GPU was reset or removed; sessions are untouched. If no
// device can be made, the app quits, still holding the lost one so nothing points at freed memory.
// A window whose surface the new device loses too is left for its next frame to recover again.
recover_device :: proc(app: ^App) {
	log.warn("the graphics device was lost; recreating it")
	for w in app.windows {window_surface_release(w)}
	device, err := render.device_create()
	if err != .None {
		log.errorf("recreating the graphics device failed: %v", err)
		app.running = false
		return
	}
	render.device_destroy(app.device)
	app.device = device
	apply_text_gamma(app)
	glyphs.reset_device(&app.cache, device)
	for w in app.windows {
		w.surface_failed = false
		surface_error := window_surface_create(app, w)
		if surface_error != .None && surface_error != .Device_Lost {window_surface_failed(w, surface_error)}
	}
}

@(private = "file")
window_surface_failed :: proc(w: ^Window, err: render.Error) {
	log.errorf("making the window surface failed: %v", err)
	w.surface_failed = true
}
