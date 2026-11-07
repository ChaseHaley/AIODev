package app_test

import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"
import app "../../src"
import "aio:control"
import "aio:ui"

@(private = "file")
cli_sync_quietly :: proc(state: ^app.App) {
	// A failed start logs an error, which the test runner would count as a failure.
	context.logger = {}
	app.control_cli_sync(state)
}

// Every settings sync used to retry a pipe that failed to start and repeat its notice.
@(test)
cli_pipe_failure_waits_for_control_enabled_to_change :: proc(t: ^testing.T) {
	state: app.App
	state.app_id = fmt.tprintf("AIODev.Test.CliPipe.%d.%d", os.get_pid(), time.tick_now()._nsec)
	ui.notices_init(&state.notices)
	defer ui.notices_destroy(&state.notices)
	defer app.control_cli_stop(&state)
	name, name_error := control.cli_pipe_name(state.app_id, context.temp_allocator)
	if !testing.expect_value(t, name_error, control.Error.None) {return}
	squatter, squatter_error := control.create(name, {})
	if !testing.expect_value(t, squatter_error, control.Error.None) {return}

	state.settings.control.enabled = true
	cli_sync_quietly(&state)
	_, failed := state.cli.(app.Cli_Pipe_Failed)
	testing.expect(t, failed)
	testing.expect_value(t, state.notices.next_id, 1)

	control.destroy(squatter)
	cli_sync_quietly(&state)
	_, failed = state.cli.(app.Cli_Pipe_Failed)
	testing.expect(t, failed, "a sync without a change to control.enabled must not retry")
	testing.expect_value(t, state.notices.next_id, 1)

	state.settings.control.enabled = false
	app.control_cli_sync(&state)
	testing.expect(t, state.cli == nil)
	state.settings.control.enabled = true
	app.control_cli_sync(&state)
	_, running := state.cli.(^control.Server)
	testing.expect(t, running, "turning control.enabled off and on starts the pipe again")
	testing.expect_value(t, state.notices.next_id, 1)
}
