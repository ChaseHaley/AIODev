package control_test

import "core:strings"
import "core:testing"
import "core:thread"
import w "core:sys/windows"
import "aio:control"

@(test)
cli_pipe_name_is_distinct_from_verification :: proc(t: ^testing.T) {
	cli, cli_error := control.cli_pipe_name("AIODev.work", context.temp_allocator)
	testing.expect_value(t, cli_error, control.Error.None)
	testing.expect_value(t, cli, `\\.\pipe\AIODev.work.cli`)
	verify, _ := control.pipe_name("AIODev.work", context.temp_allocator)
	testing.expect(t, cli != verify)
	for id in ([]string{"", `a\b`, "a/b", "a\x00b"}) {
		_, err := control.cli_pipe_name(id, context.temp_allocator)
		testing.expect_value(t, err, control.Error.Invalid_Argument)
	}
}

Cli_Call :: struct {
	name:              string,
	ok, text_received: bool,
	status:            u8,
	error:             control.Error,
}

@(test)
raw_server_delivers_arguments_and_status :: proc(t: ^testing.T) {
	name := test_pipe_name(t)
	defer delete(name)
	s, err := control.create(name, {}, raw = true)
	if !testing.expect_value(t, err, control.Error.None) { return }
	defer control.destroy(s)
	state := Cli_Call{name = name}
	worker := thread.create_and_start_with_data(&state, proc(data: rawptr) {
		c := (^Cli_Call)(data)
		client, connect_error := control.connect(c.name, 2000)
		if connect_error != .None { c.error = connect_error; return }
		defer control.close(&client)
		// Not verification grammar: a raw server must not answer it with a parse error.
		response: control.Response
		response, c.error = control.call(&client, {"", "text", "pane.split", "--direction", "down"}, 2000)
		c.ok, c.status, c.text_received = response.ok, response.status, response.text == "no such pane"
		control.response_destroy(&response)
	})
	if !testing.expect(t, worker != nil) { return }
	defer thread.destroy(worker)
	m := await_request(t, s)
	if m == nil { thread.join(worker); return }
	testing.expect_value(t, m.parse_error.advice, "")
	testing.expect(t, m.request == nil)
	testing.expect_value(t, len(m.args), 5)
	testing.expect_value(t, m.args[2], "pane.split")
	testing.expect_value(t, control.respond(s, m.id, {ok = false, text = "no such pane", status = 3}), control.Error.None)
	control.message_destroy(m)
	thread.join(worker)
	testing.expect_value(t, state.error, control.Error.None)
	testing.expect(t, !state.ok && state.text_received)
	testing.expect_value(t, state.status, u8(3))
}

@(test)
client_reads_optional_status :: proc(t: ^testing.T) {
	Case :: struct { payload: string, error: control.Error, status: u8 }
	cases := [?]Case{
		{"{\"ok\":false,\"text\":\"x\",\"status\":3}\n", .None, 3},
		{"{\"status\":130,\"ok\":false,\"text\":\"x\"}\n", .None, 130},
		{"{\"ok\":true,\"text\":\"x\"}\n", .None, 0},
		{"{\"ok\":false,\"text\":\"x\",\"status\":256}\n", .Protocol, 0},
		{"{\"ok\":false,\"text\":\"x\",\"status\":-1}\n", .Protocol, 0},
		{"{\"ok\":false,\"text\":\"x\",\"status\":\"3\"}\n", .Protocol, 0},
		{"{\"ok\":false,\"text\":\"x\",\"status\":1,\"status\":2}\n", .Protocol, 0},
		{"{\"ok\":false,\"text\":\"x\",\"status\":1,\"extra\":2}\n", .Protocol, 0},
	}
	for item in cases {
		name := test_pipe_name(t)
		wide := w.utf8_to_wstring(name, context.allocator)
		if !testing.expect(t, wide != nil) { delete(name); return }
		pipe := w.CreateNamedPipeW(wide, w.PIPE_ACCESS_DUPLEX | w.FILE_FLAG_OVERLAPPED,
			w.PIPE_REJECT_REMOTE_CLIENTS, 1, 4096, 4096, 0, nil)
		delete(wide)
		if !testing.expect(t, pipe != w.INVALID_HANDLE_VALUE) { delete(name); return }
		state := Raw_Server{pipe = pipe, payload = item.payload}
		worker := thread.create(raw_server_thread)
		if !testing.expect(t, worker != nil) {
			testing.expect(t, bool(w.CloseHandle(pipe)))
			delete(name)
			return
		}
		worker.data = &state
		thread.start(worker)
		c, connect_error := control.connect(name, 1000)
		testing.expect_value(t, connect_error, control.Error.None)
		r, err := control.call(&c, {"ping"}, 1000)
		testing.expectf(t, err == item.error, "%q gave %v", item.payload, err)
		testing.expect_value(t, r.status, item.status)
		control.response_destroy(&r)
		control.close(&c)
		thread.join(worker)
		thread.destroy(worker)
		delete(name)
	}
}

@(test)
verification_replies_keep_two_keys :: proc(t: ^testing.T) {
	name := test_pipe_name(t)
	defer delete(name)
	s, err := control.create(name, {})
	if !testing.expect_value(t, err, control.Error.None) { return }
	defer control.destroy(s)
	wide := w.utf8_to_wstring(name, context.allocator)
	if !testing.expect(t, wide != nil) { return }
	defer delete(wide)
	pipe := w.CreateFileW(wide, w.GENERIC_READ | w.GENERIC_WRITE, 0, nil,
		w.OPEN_EXISTING, w.FILE_FLAG_OVERLAPPED, nil)
	if !testing.expect(t, pipe != w.INVALID_HANDLE_VALUE) { return }
	defer { testing.expect(t, bool(w.CloseHandle(pipe))) }
	payload := "[\"ping\"]\n"
	n, written := raw_transfer(pipe, transmute([]u8)payload, true)
	if !testing.expect(t, written && n == len(payload)) { return }
	m := await_request(t, s)
	if m == nil { return }
	testing.expect_value(t, control.respond(s, m.id, {ok = true, text = "pong"}), control.Error.None)
	control.message_destroy(m)
	buffer: [128]u8
	text := strings.builder_make()
	defer strings.builder_destroy(&text)
	for !strings.has_suffix(strings.to_string(text), "\n") {
		count, ok := raw_transfer(pipe, buffer[:], false)
		if !testing.expect(t, ok) { break }
		strings.write_string(&text, string(buffer[:count]))
	}
	testing.expect_value(t, strings.to_string(text), "{\"ok\":true,\"text\":\"pong\"}\n")
}
