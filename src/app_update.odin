package main

import "aio:cli_protocol"
import "aio:platform"
import "aio:ui"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// Update AIODev (WORK-414). update.ps1, installed beside aiodev.exe, installs the latest release over the
// running AIODev, which keeps running its old files; once it reports a newer build installed, AIODev asks
// to restart into it. A build that is not installed has no update.ps1 beside it and does not update.
App_Update :: struct {
	// The updater while it runs; nil otherwise.
	run: ^platform.Program_Run,
	// The updater's log, whose last line is the message it leaves for the user.
	log: string,
}

// The question asked once a newer AIODev is installed, with the updater's message.
Update_Restart :: struct {
	message: string,
}

// update.ps1's exit codes; any other is a failure.
@(private = "file")
UPDATE_INSTALLED :: 0
@(private = "file")
UPDATE_CURRENT :: 3
@(private = "file")
UPDATE_SCRIPT :: "update.ps1"
@(private = "file")
UPDATE_LOG :: "update.log"

app_update_start :: proc(app: ^App) {
	if app.update.run != nil {
		notify(app, .Info, "AIODev is already updating.")
		return
	}
	executable, executable_error := os.get_executable_path(context.temp_allocator)
	if executable_error != nil {
		notify(app, .Error, "Could not find AIODev's folder to update it.")
		return
	}
	directory := filepath.dir(executable)
	script, _ := filepath.join({directory, UPDATE_SCRIPT}, context.temp_allocator)
	if !os.exists(script) {
		notify(app, .Info, "Only an installed AIODev updates itself. Install it with the line in the README.")
		return
	}
	system_root, found := os.lookup_env("SystemRoot", context.temp_allocator)
	if !found || app.paths.logs == "" || os.mkdir_all(app.paths.logs) != nil {
		notify(app, .Error, "Could not start the update.")
		return
	}
	log_path, join_error := filepath.join({app.paths.logs, UPDATE_LOG})
	if join_error != nil {
		notify(app, .Error, "Could not start the update.")
		return
	}
	line := strings.builder_make(context.temp_allocator)
	// By path, so no other powershell.exe is found first. Windows PowerShell's default policy refuses
	// every script file, so this one run bypasses it; the user's policy is unchanged.
	argument_write(&line, fmt.tprintf(`%s\System32\WindowsPowerShell\v1.0\powershell.exe`, system_root))
	strings.write_string(&line, " -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ")
	argument_write(&line, script)
	strings.write_string(&line, " -Log ")
	argument_write(&line, log_path)
	if cli_protocol.BUILD_VERSION != "" {
		fmt.sbprintf(&line, " -RunningVersion %s", cli_protocol.BUILD_VERSION)
	}
	run := platform.program_run_start(&app.platform, strings.to_string(line), directory)
	if run == nil {
		delete(log_path)
		notify(app, .Error, "Could not start the update.")
		return
	}
	app.update = {run, log_path}
	key := u32(Notice_Key.Update)
	ui.notices_put(&app.notices, key, .Info, "Updating AIODev…", 0, app.animations, clock_now(&app.clock))
	mark_all_dirty(app)
}

// Acts on the updater's result once it exits; a finished updater wakes the loop itself.
app_update_tick :: proc(app: ^App) {
	if app.update.run == nil {return}
	code, finished := platform.program_run_finished(app.update.run)
	if !finished {return}
	message := update_message(app.update.log)
	app_update_destroy(app)
	ui.notices_clear(&app.notices, u32(Notice_Key.Update), app.animations)
	mark_all_dirty(app)
	switch code {
	case UPDATE_INSTALLED:
		w := window_focused_or_recent(app)
		owned, clone_error := strings.clone(message)
		if w == nil || clone_error != nil || !gesture_cancel(app, w) {
			delete(owned)
			notify(app, .Info, fmt.tprintf("%s Quit and reopen AIODev to start it.", message))
			return
		}
		confirmation_ask(app, w, Update_Restart{owned}, extended = true)
	case UPDATE_CURRENT:
		notify(app, .Info, message)
	case:
		notify(app, .Error, fmt.tprintf("Could not update AIODev: %s", message))
	}
}

// Stops waiting on a running updater, which finishes on its own.
app_update_destroy :: proc(app: ^App) {
	if app.update.run != nil {platform.program_run_destroy(app.update.run)}
	delete(app.update.log)
	app.update = {}
}

// The last line the updater wrote to its log; temporary.
@(private = "file")
update_message :: proc(log_path: string) -> string {
	data, err := os.read_entire_file(log_path, context.temp_allocator)
	if err == nil {
		lines := strings.split_lines(strings.trim_space(string(data)), context.temp_allocator)
		if len(lines) > 0 && lines[len(lines) - 1] != "" {return strings.trim_space(lines[len(lines) - 1])}
	}
	return fmt.tprintf("the updater left no message in %s.", log_path)
}

update_restart_text :: proc(restart: Update_Restart) -> Confirmation_Text {
	return {
		title = "Restart AIODev?",
		body = restart.message,
		note = "Programs running in panes end; your layout and agent conversations come back.",
		label = "Restart",
	}
}

@(private)
update_restart_finish :: proc(app: ^App, accepted: bool) {
	if accepted {
		// The answer was just given here, so this process may still pass the foreground on.
		platform.foreground_pass_on()
		app_restart(app)
		return
	}
	// aio only talks to the aiodev.exe beside it, and this process's image now lies under .replaced.
	notify(app, .Info, "The new AIODev starts when you quit and reopen AIODev; until then aio cannot reach it.")
}

update_restart_destroy :: proc(restart: ^Update_Restart) {
	delete(restart.message)
}
