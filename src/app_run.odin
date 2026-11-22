package main

import "cosmos:platform"

// Whether the main loop goes round again, and why it stopped. The procs below are its only writers.
App_Run :: enum u8 {
	Running,
	// A quit waits while the verify harness delivers its reply to the request that caused it.
	Draining,
	// A restart waits the same way, then goes on as a Restart.
	Draining_Restart,
	// The owner quit: a menu, the tray, or closing the last workspace.
	Quit,
	// The owner quits to start AIODev again, as after an update; main starts it once this one has let go.
	Restart,
	// The graphics device was lost and could not be recreated.
	Device_Failed,
}

app_running :: proc(app: ^App) -> bool {
	return app.run == .Running || app.run == .Draining || app.run == .Draining_Restart
}

// A quit already being drained stays drained, so its reply still arrives.
app_quit :: proc(app: ^App) {
	if app.run == .Running {app.run = .Quit}
}

// Whoever asks, the restarted AIODev takes the foreground only when this one holds it now.
app_restart :: proc(app: ^App) {
	if app.run != .Running {return}
	platform.foreground_pass_on()
	app.run = .Restart
}

// Nothing can draw without a device, so no reply is worth waiting for.
app_device_failed :: proc(app: ^App) {
	app.run = .Device_Failed
}

// Only the verify harness holds a quit or restart open, so these exist only in its build.
when AIO_CONTROL {
	// Holds the owner's quit or restart open; a failed device is not held.
	@(require_results)
	app_quit_hold :: proc(app: ^App) -> bool {
		#partial switch app.run {
		case .Quit:
			app.run = .Draining
		case .Restart:
			app.run = .Draining_Restart
		case:
			return false
		}
		return true
	}

	app_quit_release :: proc(app: ^App) {
		#partial switch app.run {
		case .Draining:
			app.run = .Quit
		case .Draining_Restart:
			app.run = .Restart
		}
	}
}
