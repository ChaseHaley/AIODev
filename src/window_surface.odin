package main

import "aio:glyphs"
import "aio:platform"
import "aio:render"
import "core:log"

// Every window draws through its own surface on the app's one graphics device. A window whose
// surface is missing (nil) is blank, and its next frame creates the surface again; a resize waits for
// that. Only the procs here write app.device after startup and w.surface.

@(require_results)
window_surface_create :: proc(app: ^App, w: ^Window) -> render.Error {
	native := platform.window_native_handle(&app.platform, w.id)
	surface, err := render.surface_create(app.device, native, max(w.width, 1), max(w.height, 1))
	if err != .None {return err}
	w.surface = surface
	for &pane in w.views {pane.valid = false}
	w.dirty = true
	return .None
}

// The window keeps asking for a frame, which is what creates the surface again.
window_surface_release :: proc(w: ^Window) {
	if w.surface != nil {render.surface_destroy(w.surface)}
	w.surface = nil
	w.dirty = true
}

@(private)
window_surface_resize :: proc(app: ^App, w: ^Window, width, height: i32) {
	if w.surface == nil {return}
	if err := render.surface_resize(app.device, w.surface, width, height); err != .None {
		log.errorf("resizing the window surface failed: %v", err)
		if err == .Device_Lost {recover_device(app)}
	}
}

// Rebuilds every graphics object after the GPU was reset or removed; sessions are untouched. If no
// device can be made, the app quits, still holding the lost one so nothing points at freed memory.
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
		if surface_error := window_surface_create(app, w); surface_error != .None {
			log.errorf("recreating a window surface failed: %v", surface_error)
		}
	}
}
