package control_test

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import w "core:sys/windows"
import "aio:control"

Pipe_Test :: struct {
	name: string,
	allocator: runtime.Allocator,
	count: int,
	timeout: int,
	error: control.Error,
	process_id: u32,
	responses: int,
}

test_pipe_name :: proc(t: ^testing.T) -> string {
	buffer: [256]u8
	id := fmt.bprintf(buffer[:], "aiodev-test-%d-%p-%d", w.GetCurrentProcessId(), t, time.tick_since({}))
	name, err := control.pipe_name(id)
	if !testing.expect_value(t, err, control.Error.None) { return "" }
	return name
}

client_thread :: proc(t: ^thread.Thread) {
	s := (^Pipe_Test)(t.data)
	context.allocator = s.allocator
	c, err := control.connect(s.name, 2000, s.allocator)
	if err != .None { s.error = err; return }
	defer control.close(&c)
	s.process_id = c.process_id
	for _ in 0..<s.count {
		r, failure := control.call(&c, {"type", "hello\n\"\\world"}, s.timeout)
		if failure != .None { s.error = failure; return }
		if r.ok && r.text == "reply\n\"\\" { s.responses += 1 }
		control.response_destroy(&r, s.allocator)
	}
}

start_client :: proc(t: ^testing.T, s: ^Pipe_Test) -> ^thread.Thread {
	worker := thread.create(client_thread)
	if !testing.expect(t, worker != nil) { return nil }
	worker.data = s
	thread.start(worker)
	return worker
}

await_request :: proc(t: ^testing.T, s: ^control.Server) -> ^control.Message {
	start := time.tick_now()
	for time.tick_since(start) < 3*time.Second {
		if m := control.poll(s); m != nil { return m }
		time.sleep(time.Millisecond)
	}
	testing.expect(t, false, "request did not reach server")
	return nil
}

wake_test :: proc(user: rawptr) { sync.atomic_add((^int)(user), 1) }

await_delivery :: proc(t: ^testing.T, s: ^control.Server, id: u64) {
	start := time.tick_now()
	for !control.delivery_finished(s, id) && time.tick_since(start) < 3*time.Second {
		time.sleep(time.Millisecond)
	}
	testing.expect(t, control.delivery_finished(s, id))
}

expect_duplicate :: proc(name: string) -> (^control.Server, control.Error) {
	context.logger = {}
	return control.create(name, {})
}

expect_closed_call :: proc(c: ^control.Client) -> (control.Response, control.Error) {
	context.logger = {}
	return control.call(c, {"ping"}, 1000)
}

@(test)
pipe_round_trips_delayed_and_exclusive :: proc(t: ^testing.T) {
	name := test_pipe_name(t)
	defer delete(name)
	wakes: int
	s, err := control.create(name, {wake_test, &wakes})
	if !testing.expect_value(t, err, control.Error.None) { return }
	defer control.destroy(s)
	testing.expect(t, !control.delivery_finished(nil, 1))
	testing.expect(t, !control.delivery_finished(s, 0))
	testing.expect(t, !control.delivery_finished(s, 1))
	second, duplicate_error := expect_duplicate(name)
	if second != nil { control.destroy(second) }
	testing.expect_value(t, duplicate_error, control.Error.System)
	state := Pipe_Test{name = name, allocator = context.allocator, count = 3, timeout = 2000}
	worker := start_client(t, &state)
	if worker == nil { return }
	defer thread.destroy(worker)
	for i in 0..<3 {
		m := await_request(t, s)
		if m == nil { break }
		testing.expect_value(t, m.parse_error.advice, "")
		testing.expect_value(t, m.request.(control.Type).text, "hello\n\"\\world")
		if i == 1 { time.sleep(40*time.Millisecond) }
		testing.expect(t, !control.delivery_finished(s, m.id))
		testing.expect_value(t, control.respond(s, m.id, {ok = true, text = "reply\n\"\\"}), control.Error.None)
		await_delivery(t, s, m.id)
		control.message_destroy(m)
	}
	thread.join(worker)
	testing.expect_value(t, state.error, control.Error.None)
	testing.expect_value(t, state.process_id, w.GetCurrentProcessId())
	testing.expect_value(t, state.responses, 3)
	testing.expect_value(t, sync.atomic_load(&wakes), 3)
}

@(test)
pipe_disconnect_and_stale_reply :: proc(t: ^testing.T) {
	name := test_pipe_name(t)
	defer delete(name)
	s, err := control.create(name, {})
	if !testing.expect_value(t, err, control.Error.None) { return }
	defer control.destroy(s)
	state := Pipe_Test{name = name, allocator = context.allocator, count = 1, timeout = 100}
	worker := start_client(t, &state)
	if worker == nil { return }
	m := await_request(t, s)
	thread.join(worker)
	thread.destroy(worker)
	testing.expect_value(t, state.error, control.Error.Timeout)
	if m == nil { return }
	defer control.message_destroy(m)
	await_delivery(t, s, m.id)
	state = Pipe_Test{name = name, allocator = context.allocator, count = 1, timeout = 2000}
	worker = start_client(t, &state)
	if worker == nil { return }
	defer thread.destroy(worker)
	next := await_request(t, s)
	if next != nil {
		testing.expect_value(t, control.respond(s, m.id, {ok = true, text = "stale"}), control.Error.Closed)
		testing.expect_value(t, control.respond(s, next.id, {ok = true, text = "reply\n\"\\"}), control.Error.None)
		control.message_destroy(next)
	}
	thread.join(worker)
	testing.expect_value(t, state.error, control.Error.None)
	testing.expect_value(t, state.responses, 1)
}

@(test)
pipe_destroy_idle_reading_and_pending :: proc(t: ^testing.T) {
	control.destroy(nil)
	for mode in 0..<3 {
		name := test_pipe_name(t)
		s, err := control.create(name, {})
		if !testing.expect_value(t, err, control.Error.None) { delete(name); return }
		if mode == 0 { control.destroy(s); delete(name); continue }
		if mode == 1 {
			c, connect_error := control.connect(name, 1000)
			testing.expect_value(t, connect_error, control.Error.None)
			start := time.tick_now()
			control.destroy(s)
			testing.expect(t, time.tick_since(start) < time.Second)
			response, call_error := expect_closed_call(&c)
			control.response_destroy(&response)
			testing.expect(t, call_error == .Closed || call_error == .System)
			control.close(&c)
		} else {
			state := Pipe_Test{name = name, allocator = context.allocator, count = 1, timeout = 2000}
			worker := start_client(t, &state)
			if worker == nil { control.destroy(s); delete(name); return }
			m := await_request(t, s)
			control.destroy(s)
			control.message_destroy(m)
			thread.join(worker)
			thread.destroy(worker)
			testing.expect_value(t, state.error, control.Error.Closed)
		}
		delete(name)
	}
}

@(test)
pipe_missing_timeout_and_client_limit :: proc(t: ^testing.T) {
	name := test_pipe_name(t)
	defer delete(name)
	start := time.tick_now()
	c, err := control.connect(name, 25)
	defer control.close(&c)
	testing.expect_value(t, err, control.Error.Timeout)
	testing.expect(t, time.tick_since(start) < time.Second)
	_, invalid := control.connect(name, -1)
	testing.expect_value(t, invalid, control.Error.Invalid_Argument)
	s, create_error := control.create(name, {})
	if !testing.expect_value(t, create_error, control.Error.None) { return }
	defer control.destroy(s)
	c, err = control.connect(name, 1000)
	if !testing.expect_value(t, err, control.Error.None) { return }
	large := strings.repeat("x", control.MAX_MESSAGE)
	defer delete(large)
	_, limit_error := control.call(&c, {"type", large})
	testing.expect_value(t, limit_error, control.Error.Protocol)
}

Raw_Client :: struct {
	name: string,
	allocator: runtime.Allocator,
	payload: string,
	oversized: bool,
	write_ok, read_ok: bool,
}

raw_transfer :: proc(pipe: w.HANDLE, buffer: []u8, writing: bool) -> (int, bool) {
	event := w.CreateEventW(nil, true, false, nil)
	if event == nil { return 0, false }
	defer {
		if !bool(w.CloseHandle(event)) { log.errorf("CloseHandle failed: %v", w.GetLastError()) }
	}
	ov := w.OVERLAPPED{hEvent = event}
	n: u32
	ok: w.BOOL
	if writing { ok = w.WriteFile(pipe, raw_data(buffer), u32(len(buffer)), &n, &ov) } else {
		ok = w.ReadFile(pipe, raw_data(buffer), u32(len(buffer)), &n, &ov)
	}
	if !bool(ok) {
		if w.GetLastError() != w.ERROR_IO_PENDING { return 0, false }
		result := w.WaitForSingleObject(event, 2000)
		if result != w.WAIT_OBJECT_0 {
			if !bool(w.CancelIoEx(pipe, &ov)) && w.GetLastError() != w.ERROR_NOT_FOUND {
				log.errorf("CancelIoEx failed: %v", w.GetLastError())
			}
			if !bool(w.GetOverlappedResult(pipe, &ov, &n, true)) &&
			   w.GetLastError() != w.ERROR_OPERATION_ABORTED {
				log.errorf("GetOverlappedResult failed: %v", w.GetLastError())
			}
			return 0, false
		}
		if !bool(w.GetOverlappedResult(pipe, &ov, &n, false)) { return 0, false }
	}
	return int(n), n > 0
}

raw_client_thread :: proc(t: ^thread.Thread) {
	s := (^Raw_Client)(t.data)
	context.allocator = s.allocator
	wide := w.utf8_to_wstring(s.name, s.allocator)
	if wide == nil { return }
	defer delete(wide, s.allocator)
	pipe := w.CreateFileW(wide, w.GENERIC_READ | w.GENERIC_WRITE, 0, nil,
		w.OPEN_EXISTING, w.FILE_FLAG_OVERLAPPED, nil)
	if pipe == w.INVALID_HANDLE_VALUE { return }
	defer { if !bool(w.CloseHandle(pipe)) { s.read_ok = false } }
	if s.oversized {
		block: [8192]u8
		for &c in block { c = 'x' }
		for _ in 0..<control.MAX_MESSAGE/len(block) {
			n, ok := raw_transfer(pipe, block[:], true)
			if !ok || n != len(block) { return }
		}
		n, ok := raw_transfer(pipe, block[:1], true)
		if !ok || n != 1 { return }
	} else {
		for offset := 0; offset < len(s.payload); {
			n, ok := raw_transfer(pipe, transmute([]u8)s.payload[offset:], true)
			if !ok { return }
			offset += n
		}
	}
	s.write_ok = true
	buffer: [4096]u8
	n, ok := raw_transfer(pipe, buffer[:], false)
	s.read_ok = ok && strings.contains(string(buffer[:n]), `"ok":false`)
}

@(test)
pipe_protocol_errors_and_server_limit :: proc(t: ^testing.T) {
	for payload in ([]string{"not json\n", "[null]\n", "[42]\n", "[\"ping\",]\n", "oversized"}) {
		name := test_pipe_name(t)
		s, err := control.create(name, {})
		if !testing.expect_value(t, err, control.Error.None) { delete(name); return }
		state := Raw_Client{name = name, allocator = context.allocator,
			payload = payload, oversized = payload == "oversized"}
		worker := thread.create(raw_client_thread)
		if !testing.expect(t, worker != nil) { control.destroy(s); delete(name); return }
		worker.data = &state
		thread.start(worker)
		thread.join(worker)
		thread.destroy(worker)
		testing.expect(t, state.write_ok)
		testing.expect(t, state.read_ok)
		m := control.poll(s)
		testing.expect(t, m == nil)
		control.message_destroy(m)
		control.destroy(s)
		delete(name)
	}
}

@(test)
pipe_parse_error_response :: proc(t: ^testing.T) {
	name := test_pipe_name(t)
	defer delete(name)
	s, err := control.create(name, {})
	if !testing.expect_value(t, err, control.Error.None) { return }
	defer control.destroy(s)
	c, connect_error := control.connect(name, 1000)
	if !testing.expect_value(t, connect_error, control.Error.None) { return }
	defer control.close(&c)
	for _ in 0..<2 {
		r, call_error := control.call(&c, {"unknown"}, 1000)
		testing.expect_value(t, call_error, control.Error.None)
		testing.expect(t, !r.ok)
		testing.expect_value(t, r.text, "\"unknown\": unknown command; use help")
		control.response_destroy(&r)
	}
	testing.expect(t, control.poll(s) == nil)
}

@(test)
pipe_unpolled_disconnect_and_busy_connect :: proc(t: ^testing.T) {
	name := test_pipe_name(t)
	defer delete(name)
	s, err := control.create(name, {})
	if !testing.expect_value(t, err, control.Error.None) { return }
	defer control.destroy(s)
	c, connect_error := control.connect(name, 1000)
	if !testing.expect_value(t, connect_error, control.Error.None) { return }
	busy, busy_error := control.connect(name, 25)
	control.close(&busy)
	testing.expect_value(t, busy_error, control.Error.Timeout)
	response, timeout_error := control.call(&c, {"key", "Ctrl+P"}, 30)
	control.response_destroy(&response)
	control.close(&c)
	testing.expect_value(t, timeout_error, control.Error.Timeout)
	next, next_error := control.connect(name, 1000)
	if !testing.expect_value(t, next_error, control.Error.None) { return }
	defer control.close(&next)
	testing.expect(t, control.poll(s) == nil)
}

@(test)
pipe_fragmented_and_coalesced_lines :: proc(t: ^testing.T) {
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
	for piece in ([]string{"[\"ty", "pe\",\"a\"]\n[\"type\",\"b\"]\n"}) {
		n, ok := raw_transfer(pipe, transmute([]u8)piece, true)
		testing.expect(t, ok && n == len(piece))
	}
	for expected in ([]string{"a", "b"}) {
		m := await_request(t, s)
		if m == nil { return }
		testing.expect_value(t, m.request.(control.Type).text, expected)
		testing.expect_value(t, control.respond(s, m.id, {ok = false, text = "observed failure"}), control.Error.None)
		control.message_destroy(m)
		buffer: [128]u8
		text := strings.builder_make()
		for {
			n, ok := raw_transfer(pipe, buffer[:], false)
			if !testing.expect(t, ok) { break }
			strings.write_string(&text, string(buffer[:n]))
			if strings.has_suffix(strings.to_string(text), "\n") { break }
		}
		testing.expect_value(t, strings.to_string(text), "{\"ok\":false,\"text\":\"observed failure\"}\n")
		strings.builder_destroy(&text)
	}
}

@(test)
pipe_delivery_blocked_then_disconnected :: proc(t: ^testing.T) {
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
	defer if pipe != nil { testing.expect(t, bool(w.CloseHandle(pipe))) }
	payload := "[\"ping\"]\n"
	n, written := raw_transfer(pipe, transmute([]u8)payload, true)
	if !testing.expect(t, written && n == len(payload)) { return }
	m := await_request(t, s)
	if m == nil { return }
	defer control.message_destroy(m)
	large := strings.repeat("x", 256*1024)
	defer delete(large)
	testing.expect_value(t, control.respond(s, m.id, {ok = true, text = large}), control.Error.None)
	testing.expect(t, !control.delivery_finished(s, m.id))
	testing.expect(t, bool(w.CloseHandle(pipe)))
	pipe = nil
	await_delivery(t, s, m.id)
	testing.expect(t, !control.delivery_finished(s, m.id+1))
}

// A client that connects but never sends a line must not hold the single pipe
// instance past the server I/O timeout.
@(test)
pipe_silent_client_releases_instance :: proc(t: ^testing.T) {
	name := test_pipe_name(t)
	defer delete(name)
	s, err := control.create(name, {})
	if !testing.expect_value(t, err, control.Error.None) { return }
	defer control.destroy(s)
	first, first_error := control.connect(name, 1000)
	if !testing.expect_value(t, first_error, control.Error.None) { return }
	defer control.close(&first)
	// Send nothing. The server must time out the request-line read, disconnect,
	// and accept the next client instead of waiting forever.
	start := time.tick_now()
	second, second_error := control.connect(name, 10000)
	if !testing.expect_value(t, second_error, control.Error.None) { return }
	defer control.close(&second)
	testing.expect(t, time.tick_since(start) < 10*time.Second)
	r, call_error := control.call(&second, {"unknown"}, 1000)
	defer control.response_destroy(&r)
	testing.expect_value(t, call_error, control.Error.None)
	testing.expect(t, !r.ok)
	testing.expect_value(t, r.text, "\"unknown\": unknown command; use help")
}

// A client that requests a response but never reads it must not hold the instance:
// the response is larger than the 64 KiB outbound buffer, so the write stalls until
// the server I/O timeout disconnects it.
@(test)
pipe_unread_response_releases_instance :: proc(t: ^testing.T) {
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
	defer { if pipe != nil { testing.expect(t, bool(w.CloseHandle(pipe))) } }
	payload := "[\"ping\"]\n"
	n, written := raw_transfer(pipe, transmute([]u8)payload, true)
	if !testing.expect(t, written && n == len(payload)) { return }
	m := await_request(t, s)
	if m == nil { return }
	defer control.message_destroy(m)
	large := strings.repeat("x", 256*1024)
	defer delete(large)
	testing.expect_value(t, control.respond(s, m.id, {ok = true, text = large}), control.Error.None)
	testing.expect(t, !control.delivery_finished(s, m.id))
	// Never read. The single instance must come back after the write stalls.
	start := time.tick_now()
	next, next_error := control.connect(name, 10000)
	if !testing.expect_value(t, next_error, control.Error.None) { return }
	defer control.close(&next)
	testing.expect(t, time.tick_since(start) < 10*time.Second)
	await_delivery(t, s, m.id)
	r, call_error := control.call(&next, {"unknown"}, 1000)
	defer control.response_destroy(&r)
	testing.expect_value(t, call_error, control.Error.None)
	testing.expect(t, !r.ok)
	testing.expect_value(t, r.text, "\"unknown\": unknown command; use help")
}

@(test)
pipe_argument_limit :: proc(t: ^testing.T) {
	name := test_pipe_name(t)
	defer delete(name)
	s, err := control.create(name, {})
	if !testing.expect_value(t, err, control.Error.None) { return }
	defer control.destroy(s)
	c, connect_error := control.connect(name, 1000)
	if !testing.expect_value(t, connect_error, control.Error.None) { return }
	// The client refuses to encode an argument list the server would reject.
	args := make([]string, control.MAX_ARGUMENTS + 1)
	defer delete(args)
	args[0] = "ping"
	for i in 1..<len(args) { args[i] = "x" }
	rejected, reject_error := control.call(&c, args, 5000)
	control.response_destroy(&rejected)
	testing.expect_value(t, reject_error, control.Error.Protocol)
	// The same connection stays usable after the rejection.
	reply, reply_error := control.call(&c, {"unknown"}, 1000)
	testing.expect_value(t, reply_error, control.Error.None)
	testing.expect(t, !reply.ok)
	testing.expect_value(t, reply.text, "\"unknown\": unknown command; use help")
	control.response_destroy(&reply)
	control.close(&c)
	// The server independently caps the decoded array, even for a raw client that
	// bypasses control.call's check.
	raw, raw_error := control.connect(name, 3000)
	if !testing.expect_value(t, raw_error, control.Error.None) { return }
	payload := strings.builder_make()
	defer strings.builder_destroy(&payload)
	strings.write_byte(&payload, '[')
	for i in 0..<control.MAX_ARGUMENTS + 1 {
		if i > 0 { strings.write_byte(&payload, ',') }
		strings.write_string(&payload, `"ping"`)
	}
	strings.write_string(&payload, "]\n")
	n, written := raw_transfer(raw.pipe, transmute([]u8)strings.to_string(payload), true)
	testing.expect(t, written && n == len(strings.to_string(payload)))
	buffer: [4096]u8
	read_n, read_ok := raw_transfer(raw.pipe, buffer[:], false)
	testing.expect(t, read_ok)
	testing.expect(t, strings.contains(string(buffer[:read_n]), "use a JSON string array"))
	control.close(&raw)
	// The server accepts and serves a normal request afterwards.
	next, next_error := control.connect(name, 3000)
	if !testing.expect_value(t, next_error, control.Error.None) { return }
	defer control.close(&next)
	response, call_error := control.call(&next, {"unknown"}, 1000)
	defer control.response_destroy(&response)
	testing.expect_value(t, call_error, control.Error.None)
	testing.expect(t, !response.ok)
	testing.expect_value(t, response.text, "\"unknown\": unknown command; use help")
}

// await_response has no deadline: a request held past SERVER_IO_TIMEOUT_MS still
// completes, and a response larger than the 64 KiB buffer still arrives intact when
// the client reads it.
@(test)
pipe_long_wait_and_response_stay_unbounded :: proc(t: ^testing.T) {
	name := test_pipe_name(t)
	defer delete(name)
	s, err := control.create(name, {})
	if !testing.expect_value(t, err, control.Error.None) { return }
	defer control.destroy(s)
	state := Pipe_Test{name = name, allocator = context.allocator, count = 1, timeout = 12000}
	worker := start_client(t, &state)
	if worker == nil { return }
	defer thread.destroy(worker)
	m := await_request(t, s)
	if m == nil { return }
	time.sleep(time.Duration(control.SERVER_IO_TIMEOUT_MS + 1000) * time.Millisecond)
	testing.expect_value(t, control.respond(s, m.id, {ok = true, text = "reply\n\"\\"}), control.Error.None)
	await_delivery(t, s, m.id)
	control.message_destroy(m)
	thread.join(worker)
	testing.expect_value(t, state.error, control.Error.None)
	testing.expect_value(t, state.responses, 1)
	// A client that does read a >64 KiB response receives all of it.
	c, connect_error := control.connect(name, 3000)
	if !testing.expect_value(t, connect_error, control.Error.None) { return }
	defer control.close(&c)
	payload := "[\"ping\"]\n"
	n, written := raw_transfer(c.pipe, transmute([]u8)payload, true)
	if !testing.expect(t, written && n == len(payload)) { return }
	next := await_request(t, s)
	if next == nil { return }
	defer control.message_destroy(next)
	large := strings.repeat("x", 256*1024)
	defer delete(large)
	testing.expect_value(t, control.respond(s, next.id, {ok = true, text = large}), control.Error.None)
	buffer: [8192]u8
	received := 0
	saw_newline := false
	for !saw_newline {
		count, ok := raw_transfer(c.pipe, buffer[:], false)
		if !testing.expect(t, ok) { return }
		received += count
		if count > 0 && buffer[count - 1] == '\n' { saw_newline = true }
	}
	testing.expect(t, received > 64*1024)
	testing.expect(t, received >= len(large))
	await_delivery(t, s, next.id)
}