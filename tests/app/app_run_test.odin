package app_test

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:testing"
import "core:thread"
import "core:time"
import app "../../src"
import "aio:control"
import "aio:layout"
import "aio:platform"

when app.AIO_CONTROL {
	@(test)
	app_run_holds_only_the_owners_quit :: proc(t: ^testing.T) {
		state: app.App
		testing.expect(t, app.app_running(&state))
		app.app_quit(&state)
		testing.expect_value(t, state.run, app.App_Run.Quit)
		testing.expect(t, !app.app_running(&state))
		testing.expect(t, app.app_quit_hold(&state))
		testing.expect(t, app.app_running(&state))
		app.app_quit(&state)
		testing.expect_value(t, state.run, app.App_Run.Draining)
		app.app_quit_release(&state)
		testing.expect_value(t, state.run, app.App_Run.Quit)
		testing.expect(t, !app.app_running(&state))

		// A lost device ends the loop even while a quit is being drained, and is never held open.
		state = {}
		app.app_quit(&state)
		testing.expect(t, app.app_quit_hold(&state))
		app.app_device_failed(&state)
		testing.expect_value(t, state.run, app.App_Run.Device_Failed)
		testing.expect(t, !app.app_quit_hold(&state))
		app.app_quit(&state)
		app.app_quit_release(&state)
		testing.expect_value(t, state.run, app.App_Run.Device_Failed)
		testing.expect(t, !app.app_running(&state))
	}

	@(private = "file")
	Harness_Client :: struct {
		name:      string,
		args:      []string,
		allocator: runtime.Allocator,
		response:  control.Response,
		error:     control.Error,
	}

	@(private = "file")
	harness_client :: proc(t: ^thread.Thread) {
		c := (^Harness_Client)(t.data)
		context.allocator = c.allocator
		client, err := control.connect(c.name, 2000)
		if err != .None {c.error = err; return}
		defer control.close(&client)
		c.response, c.error = control.call(&client, c.args, 5000)
	}

	// Sends one request to the harness, ticking it until the reply is delivered and the app has
	// stopped. Returns each run state seen, in order.
	@(private = "file")
	request_through_harness :: proc(
		t: ^testing.T,
		state: ^app.App,
		client: ^Harness_Client,
		args: []string,
	) -> (
		runs: [dynamic]app.App_Run,
	) {
		runs = make([dynamic]app.App_Run, context.temp_allocator)
		append(&runs, state.run)
		id := fmt.tprintf("AIODev.Test.VerifyRun.%d.%d", os.get_pid(), time.tick_now()._nsec)
		name, name_error := control.pipe_name(id, context.temp_allocator)
		if !testing.expect_value(t, name_error, control.Error.None) {return}
		server, server_error := control.create(name, {})
		if !testing.expect_value(t, server_error, control.Error.None) {return}
		state.verify.server = server
		client.name, client.args, client.allocator = name, args, context.allocator
		worker := thread.create(harness_client)
		if !testing.expect(t, worker != nil) {return}
		worker.data = client
		thread.start(worker)
		start := time.tick_now()
		for (app.app_running(state) || !control.delivery_finished(server, 1)) &&
		    time.tick_since(start) < 5 * time.Second {
			app.verify_tick(state)
			if runs[len(runs) - 1] != state.run {append(&runs, state.run)}
			time.sleep(time.Millisecond)
		}
		thread.join(worker)
		thread.destroy(worker)
		return
	}

	@(test)
	verification_quit_runs_until_its_reply_is_delivered :: proc(t: ^testing.T) {
		state: app.App
		defer app.verify_destroy(&state)
		client: Harness_Client
		defer control.response_destroy(&client.response)
		runs := request_through_harness(t, &state, &client, {"tray", "quit"})
		testing.expect_value(t, client.error, control.Error.None)
		testing.expect(t, client.response.ok)
		testing.expect_value(t, client.response.text, "ok; quitting")
		if !testing.expect_value(t, len(runs), 3) {return}
		testing.expect_value(t, runs[0], app.App_Run.Running)
		testing.expect_value(t, runs[1], app.App_Run.Draining)
		testing.expect_value(t, runs[2], app.App_Run.Quit)
	}

	// Tray quit once the device is lost: nothing is held, and the reply says the app is ending.
	@(test)
	verification_tray_quit_after_a_lost_device_holds_nothing :: proc(t: ^testing.T) {
		state: app.App
		defer app.verify_destroy(&state)
		app.app_device_failed(&state)
		client: Harness_Client
		defer control.response_destroy(&client.response)
		runs := request_through_harness(t, &state, &client, {"tray", "quit"})
		testing.expect_value(t, client.error, control.Error.None)
		testing.expect(t, !client.response.ok)
		testing.expect_value(t, client.response.text, "error: the graphics device was lost; AIODev is exiting")
		if !testing.expect_value(t, len(runs), 1) {return}
		testing.expect_value(t, runs[0], app.App_Run.Device_Failed)
	}

	// A drive that finds the app stopped used to set it running again to drain a quit, even when the
	// device was lost and nothing could draw.
	@(test)
	verification_drive_after_a_lost_device_does_not_resume_the_app :: proc(t: ^testing.T) {
		state := app.App{app_id = "AIODev.Test.VerifyDriveLostDevice"}
		if !testing.expect_value(t, platform.init(&state.platform, state.app_id), platform.Init_Result.Primary) {
			return
		}
		defer testing.expect_value(t, platform.destroy(&state.platform), platform.Error.None)
		window_id, window_error := platform.window_create(&state.platform, {hidden = true, width = 160, height = 100})
		if !testing.expect_value(t, window_error, platform.Error.None) {return}
		workspace: app.Workspace
		tab := app.Tab{id = 1}
		if !testing.expect_value(t, layout.init(&tab.tree, {.Terminal, 0}), nil) {return}
		defer layout.destroy(&tab.tree)
		append(&workspace.tabs, &tab)
		defer delete(workspace.tabs)
		w := app.Window{id = window_id, workspace = &workspace, focused = true, width = 160, height = 100}
		append(&state.windows, &w)
		defer delete(state.windows)
		append(&state.workspaces, &workspace)
		defer delete(state.workspaces)
		defer app.verify_destroy(&state)
		app.app_device_failed(&state)
		client: Harness_Client
		defer control.response_destroy(&client.response)
		runs := request_through_harness(t, &state, &client, {"window", "select", fmt.tprintf("%d", window_id)})
		testing.expect_value(t, client.error, control.Error.None)
		testing.expect(t, !client.response.ok)
		testing.expect_value(t, client.response.text, "error: the graphics device was lost; AIODev is exiting")
		if !testing.expect_value(t, len(runs), 1) {return}
		testing.expect_value(t, runs[0], app.App_Run.Device_Failed)
	}
}
