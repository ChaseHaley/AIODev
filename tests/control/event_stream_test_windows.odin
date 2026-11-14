package control_test

import "aio:control"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"

Stream_Subscription :: struct {
	client:   ^control.Client,
	response: control.Response,
	error:    control.Error,
}

open_test_stream :: proc(t: ^testing.T, server: ^control.Server, client: ^control.Client) -> u64 {
	state := Stream_Subscription{client = client}
	worker := thread.create_and_start_with_data(&state, proc(data: rawptr) {
		state := (^Stream_Subscription)(data)
		context.allocator = state.client.allocator
		state.response, state.error = control.subscribe(state.client, {"events"}, 2000)
	})
	if !testing.expect(t, worker != nil) {return 0}
	defer thread.destroy(worker)
	message := await_request(t, server)
	id: u64
	if message != nil {
		id = message.id
		testing.expect_value(t, control.stream_start(server, id), control.Error.None)
		testing.expect_value(t, control.respond(server, id, {ok = true}), control.Error.None)
		control.message_destroy(message)
	}
	thread.join(worker)
	defer control.response_destroy(&state.response, client.allocator)
	if !testing.expect_value(t, state.error, control.Error.None) {return 0}
	testing.expect(t, state.response.ok)
	return id
}

@(test)
pipe_two_clients_have_independent_requests_in_flight :: proc(t: ^testing.T) {
	name := test_pipe_name(t)
	defer delete(name)
	server, err := control.create(name, {})
	if !testing.expect_value(t, err, control.Error.None) {return}
	defer control.destroy(server)
	states := [2]Pipe_Test{}
	workers: [2]^thread.Thread
	for &state, index in states {
		state = {name = name, allocator = context.allocator, count = 1, timeout = 4000}
		workers[index] = start_client(t, &state)
	}
	// Neither request is answered until both clients have reached the app.
	first := await_request(t, server)
	second := await_request(t, server)
	if first != nil && second != nil {testing.expect(t, first.id != second.id)}
	messages := [2]^control.Message{first, second}
	for message in messages {
		if message == nil {continue}
		testing.expect_value(t, control.respond(server, message.id, {ok = true, text = "reply\n\"\\"}), control.Error.None)
		control.message_destroy(message)
	}
	for worker, index in workers {
		if worker == nil {continue}
		thread.join(worker)
		thread.destroy(worker)
		testing.expect_value(t, states[index].error, control.Error.None)
		testing.expect_value(t, states[index].responses, 1)
	}
}

@(test)
pipe_stream_preserves_order_and_survives_idle_timeouts :: proc(t: ^testing.T) {
	name := test_pipe_name(t)
	defer delete(name)
	server, err := control.create(name, {})
	if !testing.expect_value(t, err, control.Error.None) {return}
	defer control.destroy(server)
	client, connect_error := control.connect(name, 1000)
	if !testing.expect_value(t, connect_error, control.Error.None) {return}
	defer control.close(&client)
	id := open_test_stream(t, server, &client)
	if id == 0 {return}
	_, idle_error := control.next_line(&client, 5)
	testing.expect_value(t, idle_error, control.Error.Timeout)
	lines := [3]string{`{"type":"pane.focused","pane":1}`, `{"type":"pane.focused","pane":2}`, `{"type":"app.quitting"}`}
	for line in lines {testing.expect_value(t, control.stream_push(server, id, line), control.Error.None)}
	for expected in lines {
		line, read_error := control.next_line(&client, 1000)
		testing.expect_value(t, read_error, control.Error.None)
		testing.expect_value(t, line, expected)
		delete(line)
	}
	control.close(&client)
	start := time.tick_now()
	for control.stream_connected(server, id) && time.tick_since(start) < time.Second {time.sleep(time.Millisecond)}
	testing.expect(t, !control.stream_connected(server, id))
}

@(test)
pipe_full_stream_disconnects_without_blocking_other_clients :: proc(t: ^testing.T) {
	context.logger = {}
	name := test_pipe_name(t)
	defer delete(name)
	server, err := control.create(name, {})
	if !testing.expect_value(t, err, control.Error.None) {return}
	defer control.destroy(server)
	client, connect_error := control.connect(name, 1000)
	if !testing.expect_value(t, connect_error, control.Error.None) {return}
	defer control.close(&client)
	id := open_test_stream(t, server, &client)
	if id == 0 {return}
	// The client stops reading. One large line can be in WriteFile and one in the bounded queue.
	large := strings.repeat("x", control.MAX_STREAM_BYTES)
	defer delete(large)
	start := time.tick_now()
	push_error: control.Error
	for _ in 0 ..< 3 {
		push_error = control.stream_push(server, id, large)
		if push_error != .None {break}
	}
	testing.expect_value(t, push_error, control.Error.Closed)
	testing.expect(t, time.tick_since(start) < time.Second, "the pusher must never wait on the pipe")
	testing.expect(t, !control.stream_connected(server, id))
	other, other_error := control.connect(name, 1000)
	if !testing.expect_value(t, other_error, control.Error.None) {return}
	defer control.close(&other)
	reply, call_error := answered_call(t, server, &other, {"ping"})
	defer control.response_destroy(&reply)
	testing.expect_value(t, call_error, control.Error.None)
	testing.expect_value(t, reply.text, "answered")
}
