package app_test

import "core:fmt"
import "core:os"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import app "../../src"
import "aio:cli_protocol"
import "aio:commands"
import "aio:events"
import "aio:control"
@(require) import "aio:views"
import "cosmos:ui"

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

@(private = "file")
Cli_Event_Request :: struct {
	client: ^control.Client,
	command: []string,
	response: control.Response,
	error: control.Error,
	done: bool,
}

@(private = "file")
cli_event_request :: proc(t: ^testing.T, state: ^app.App, client: ^control.Client, command: []string) -> control.Response {
	request := Cli_Event_Request{client = client, command = command}
	worker := thread.create_and_start_with_data(&request, proc(data: rawptr) {
		call := (^Cli_Event_Request)(data)
		context.allocator = call.client.allocator
		args := cli_protocol.request_encode({command = call.command}, context.allocator)
		defer delete(args)
		call.response, call.error = control.subscribe(call.client, args, 2000)
		sync.atomic_store(&call.done, true)
	})
	if !testing.expect(t, worker != nil) {return {}}
	defer thread.destroy(worker)
	start := time.tick_now()
	for !sync.atomic_load(&request.done) && time.tick_since(start) < 3 * time.Second {
		app.control_cli_tick(state)
		time.sleep(time.Millisecond)
	}
	thread.join(worker)
	testing.expect_value(t, request.error, control.Error.None)
	return request.response
}

@(test)
cli_event_subscriptions_filter_and_release_interest_without_processes :: proc(t: ^testing.T) {
	state: app.App
	events.init(&state.events)
	defer events.destroy(&state.events)
	state.registry = commands.create()
	defer commands.destroy(&state.registry)
	if !testing.expect_value(t, app.register_actions(&state.registry), commands.Error.None) {return}
	name, name_error := control.cli_pipe_name(
		fmt.tprintf("AIODev.Test.Events.%d.%d", os.get_pid(), time.tick_now()._nsec),
		context.temp_allocator,
	)
	if !testing.expect_value(t, name_error, control.Error.None) {return}
	server, create_error := control.create(name, {})
	if !testing.expect_value(t, create_error, control.Error.None) {return}
	state.cli = server
	defer app.control_cli_stop(&state)
	first, first_error := control.connect(name, 1000)
	if !testing.expect_value(t, first_error, control.Error.None) {return}
	defer control.close(&first)
	second, second_error := control.connect(name, 1000)
	if !testing.expect_value(t, second_error, control.Error.None) {return}
	defer control.close(&second)

	rejected := cli_event_request(t, &state, &first, {"app.events", "pane.unknown"})
	testing.expect_value(t, cli_protocol.response_status(rejected), cli_protocol.Status.Usage)
	control.response_destroy(&rejected)
	testing.expect_value(t, state.events.interest[.Cli], events.Kinds{})
	events.set_interest(&state.events, .Lua, {.Pane_Closed})
	focused := cli_event_request(t, &state, &first, {"app.events", "pane.focused"})
	testing.expect(t, focused.ok)
	control.response_destroy(&focused)
	bells := cli_event_request(t, &state, &second, {"app.events", "pane.bell", "pane.exited"})
	testing.expect(t, bells.ok)
	control.response_destroy(&bells)
	testing.expect_value(t, state.events.interest[.Cli], events.Kinds{.Pane_Focused, .Pane_Bell, .Pane_Exited})
	Focus_Fields :: struct {
		pane, previous: u32,
	}
	Pane_Fields :: struct {
		pane: u32,
	}
	events.push(&state.events, .Pane_Focused, Focus_Fields{7, 3})
	events.push(&state.events, .Pane_Bell, Pane_Fields{8})
	events.push(&state.events, .Pane_Closed, Pane_Fields{9})
	app.control_cli_events(&state, events.pending(&state.events))
	events.clear(&state.events)
	focus_line, focus_error := control.next_line(&first, 1000)
	testing.expect_value(t, focus_error, control.Error.None)
	testing.expect_value(t, focus_line, `{"type":"pane.focused","pane":7,"previous":3}`)
	delete(focus_line)
	bell_line, bell_error := control.next_line(&second, 1000)
	testing.expect_value(t, bell_error, control.Error.None)
	testing.expect_value(t, bell_line, `{"type":"pane.bell","pane":8}`)
	delete(bell_line)
	_, extra_error := control.next_line(&first, 5)
	testing.expect_value(t, extra_error, control.Error.Timeout)
	_, other_error := control.next_line(&second, 5)
	testing.expect_value(t, other_error, control.Error.Timeout)

	control.close(&first)
	start := time.tick_now()
	for (.Pane_Focused in state.events.interest[.Cli]) && time.tick_since(start) < time.Second {
		app.control_cli_events(&state, nil)
		time.sleep(time.Millisecond)
	}
	testing.expect_value(t, state.events.interest[.Cli], events.Kinds{.Pane_Bell, .Pane_Exited})
	control.close(&second)
	start = time.tick_now()
	for state.events.interest[.Cli] != (events.Kinds{}) && time.tick_since(start) < time.Second {
		app.control_cli_events(&state, nil)
		time.sleep(time.Millisecond)
	}
	testing.expect_value(t, state.events.interest[.Cli], events.Kinds{})
	testing.expect_value(t, state.events.interest[.Lua], events.Kinds{.Pane_Closed})

	all, all_error := control.connect(name, 1000)
	if !testing.expect_value(t, all_error, control.Error.None) {return}
	defer control.close(&all)
	ack := cli_event_request(t, &state, &all, {"app.events"})
	testing.expect(t, ack.ok)
	control.response_destroy(&ack)
	for kind in events.Kind {testing.expect(t, kind in state.events.interest[.Cli])}
}
