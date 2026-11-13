package main

// Whether the main loop goes round again, and why it stopped. The procs below are its only writers.
App_Run :: enum u8 {
	Running,
	// A quit waits while the verify harness delivers its reply to the request that caused it.
	Draining,
	// The owner quit: a menu, the tray, or closing the last workspace.
	Quit,
	// The owner quits to start AIODev again, as after an update; main starts it once this one has let go.
	Restart,
	// The graphics device was lost and could not be recreated.
	Device_Failed,
}

app_running :: proc(app: ^App) -> bool {
	return app.run == .Running || app.run == .Draining
}

// A quit already being drained stays drained, so its reply still arrives.
app_quit :: proc(app: ^App) {
	if app.run == .Running {app.run = .Quit}
}

app_restart :: proc(app: ^App) {
	if app.run == .Running {app.run = .Restart}
}

// Nothing can draw without a device, so no reply is worth waiting for.
app_device_failed :: proc(app: ^App) {
	app.run = .Device_Failed
}

// Only the verify harness holds a quit open, so these exist only in its build.
when AIO_CONTROL {
	// Holds the owner's quit open; a failed device is not held.
	@(require_results)
	app_quit_hold :: proc(app: ^App) -> bool {
		if app.run != .Quit {return false}
		app.run = .Draining
		return true
	}

	app_quit_release :: proc(app: ^App) {
		if app.run == .Draining {app.run = .Quit}
	}
}
