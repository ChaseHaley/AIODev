package main

import "cosmos:glyphs"
import "cosmos:host"
import "cosmos:platform"
import "cosmos:render"
import "core:log"

// Every window draws through its own host.Surface on the app's one graphics device. Only the procs here
// write app.device after startup and w.surface, and they recover a lost device, so callers only learn
// that a frame was not shown.

// Makes the window's surface; a failure other than device loss leaves it Failed.
@(require_results)
window_surface_create :: proc(app: ^App, w: ^Window) -> render.Error {
	native := platform.window_native_handle(&app.platform, w.id)
	err := host.surface_make(&w.surface, app.device, native, w.width, w.height)
	if err != .None {return err}
	for &pane in w.pane_views {pane.valid = false}
	w.dirty = true
	return .None
}

// The window keeps asking for a frame, which is what makes the surface again.
window_surface_release :: proc(w: ^Window) {
	host.surface_release(&w.surface)
	w.dirty = true
}

// Whether the window can draw, making a missing surface first. A device lost again, as it can be
// while the driver is still resetting, starts another recovery. Any other failure is reported once.
@(require_results)
window_surface_ready :: proc(app: ^App, w: ^Window) -> bool {
	switch _ in w.surface {
	case ^render.Surface:
		return true
	case host.Surface_Failed:
		return false
	case nil:
	}
	if !host.running(app.run) {return false}
	#partial switch window_surface_create(app, w) {
	case .None:
		return true
	case .Device_Lost:
		recover_device(app)
		return host.surface_get(w.surface) != nil
	}
	return false
}

@(private)
window_surface_resize :: proc(app: ^App, w: ^Window, width, height: i32) {
	sizing := platform.window_sizing(&app.platform, w.id)
	if host.surface_resize(&w.surface, app.device, width, height, sizing) == .Device_Lost {recover_device(app)}
}

// Gives back the room a drag left in the swap chain once the drag is over.
window_surface_settle :: proc(app: ^App, w: ^Window) {
	settled, err := host.surface_settle(&w.surface, app.device, platform.window_sizing(&app.platform, w.id))
	if err == .Device_Lost {recover_device(app)}
	if settled {w.dirty = true}
}

// Presents w's draw list.
window_surface_present :: proc(app: ^App, w: ^Window, background: render.Color) -> render.Error {
	err := web_window_present(app, w, background)
	if err == .Device_Lost {recover_device(app)}
	return err
}

// Rebuilds every graphics object after the GPU was reset or removed; sessions are untouched. If no
// device can be made, the app quits, still holding the lost one so nothing points at freed memory.
// A window whose surface the new device loses too is left for its next frame to recover again.
recover_device :: proc(app: ^App) {
	log.warn("the graphics device was lost; recreating it")
	web_device_lost(app)
	for w in app.windows {window_surface_release(w)}
	device, err := render.device_create(app.render_driver)
	if err != .None {
		log.errorf("recreating the graphics device failed: %v", err)
		host.device_failed(&app.run)
		return
	}
	render.device_destroy(app.device)
	app.device = device
	apply_text_gamma(app)
	glyphs.reset_device(&app.cache, device)
	for w in app.windows {_ = window_surface_create(app, w)}
}
