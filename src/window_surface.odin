package main

import "aio:glyphs"
import "aio:platform"
import "aio:render"
import "core:log"

// Every window draws through its own surface on the app's one graphics device. Only the procs here
// write app.device after startup and w.surface; readers use window_surface.

// No variant: the surface is missing, and the window's next frame makes it; a resize waits for that.
// Failed: making it failed for a reason other than device loss, so it waits for a resize or a new
// device instead of failing, and logging, on every frame.
Window_Surface :: union {
	^render.Surface,
	Surface_Failed,
}
Surface_Failed :: struct {}

// The surface the window draws on, or nil while it has none.
window_surface :: proc(w: ^Window) -> ^render.Surface {
	surface, _ := w.surface.(^render.Surface)
	return surface
}

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

// The window keeps asking for a frame, which is what makes the surface again.
window_surface_release :: proc(w: ^Window) {
	if surface := window_surface(w); surface != nil {render.surface_destroy(surface)}
	w.surface = nil
	w.dirty = true
}

// Whether the window can draw, making a missing surface first. A device lost again, as it can be
// while the driver is still resetting, starts another recovery. Any other failure is reported once.
@(require_results)
window_surface_ready :: proc(app: ^App, w: ^Window) -> bool {
	switch _ in w.surface {
	case ^render.Surface:
		return true
	case Surface_Failed:
		return false
	case nil:
	}
	if !app_running(app) {return false}
	#partial switch err := window_surface_create(app, w); err {
	case .None:
		return true
	case .Device_Lost:
		recover_device(app)
		return window_surface(w) != nil
	case:
		window_surface_failed(w, err)
	}
	return false
}

@(private)
window_surface_resize :: proc(app: ^App, w: ^Window, width, height: i32) {
	surface := window_surface(w)
	if surface == nil {
		// The new size may be one a failed surface can be made at.
		w.surface = nil
		return
	}
	if err := render.surface_resize(app.device, surface, width, height); err != .None {
		log.errorf("resizing the window surface failed: %v", err)
		if err == .Device_Lost {recover_device(app)}
	}
}

// Presents w's draw list. Any render call can lose the device; this module recovers it, here as for
// making and resizing a surface, so callers only learn that the frame was not shown.
window_surface_present :: proc(app: ^App, w: ^Window, background: render.Color) -> render.Error {
	err := render.frame_render(app.device, window_surface(w), &w.list, background)
	if err == .Device_Lost {recover_device(app)}
	return err
}

// Rebuilds every graphics object after the GPU was reset or removed; sessions are untouched. If no
// device can be made, the app quits, still holding the lost one so nothing points at freed memory.
// A window whose surface the new device loses too is left for its next frame to recover again.
recover_device :: proc(app: ^App) {
	log.warn("the graphics device was lost; recreating it")
	for w in app.windows {window_surface_release(w)}
	device, err := render.device_create(app.render_driver)
	if err != .None {
		log.errorf("recreating the graphics device failed: %v", err)
		app_device_failed(app)
		return
	}
	render.device_destroy(app.device)
	app.device = device
	apply_text_gamma(app)
	glyphs.reset_device(&app.cache, device)
	for w in app.windows {
		surface_error := window_surface_create(app, w)
		if surface_error != .None && surface_error != .Device_Lost {window_surface_failed(w, surface_error)}
	}
}

@(private = "file")
window_surface_failed :: proc(w: ^Window, err: render.Error) {
	log.errorf("making the window surface failed: %v", err)
	w.surface = Surface_Failed{}
}
