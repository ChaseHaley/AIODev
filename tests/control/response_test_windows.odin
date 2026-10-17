package control_test

import "core:strings"
import "core:testing"
import "core:thread"
import w "core:sys/windows"
import "aio:control"

Raw_Server :: struct { pipe: w.HANDLE, payload: string, read_ok, write_ok: bool }

raw_server_thread :: proc(t: ^thread.Thread) {
	s := (^Raw_Server)(t.data)
	defer { if !bool(w.CloseHandle(s.pipe)) { s.write_ok = false } }
	event := w.CreateEventW(nil, true, false, nil)
	if event == nil { return }
	defer { if !bool(w.CloseHandle(event)) { s.write_ok = false } }
	ov := w.OVERLAPPED{hEvent = event}
	if !bool(w.ConnectNamedPipe(s.pipe, &ov)) {
		code := w.GetLastError()
		if code == w.ERROR_IO_PENDING {
			result := w.WaitForSingleObject(event, 2000)
			if result != w.WAIT_OBJECT_0 {
				if !bool(w.CancelIoEx(s.pipe, &ov)) && w.GetLastError() != w.ERROR_NOT_FOUND { return }
				n: u32
				if !bool(w.GetOverlappedResult(s.pipe, &ov, &n, true)) &&
				   w.GetLastError() != w.ERROR_OPERATION_ABORTED { return }
				return
			}
			n: u32
			if !bool(w.GetOverlappedResult(s.pipe, &ov, &n, false)) { return }
		} else if code != w.ERROR_PIPE_CONNECTED { return }
	}
	buffer: [1024]u8
	_, read_ok := raw_transfer(s.pipe, buffer[:], false)
	s.read_ok = read_ok
	if !read_ok { return }
	for offset := 0; offset < len(s.payload); {
		n, ok := raw_transfer(s.pipe, transmute([]u8)s.payload[offset:], true)
		if !ok { return }
		offset += n
	}
	s.write_ok = true
	_, _ = raw_transfer(s.pipe, buffer[:], false)
}

@(test)
client_rejects_malformed_responses :: proc(t: ^testing.T) {
	for payload in ([]string{
		"{}\n", "null\n", "[]\n", "{\"ok\":true}\n", "{\"ok\":true,\"text\":null}\n",
		"{\"ok\":true,\"text\":\"a\",\"text\":\"b\"}\n", "{\"ok\":\"true\",\"text\":\"x\"}\n",
		"{\"ok\":true,\"text\":\"x\",\"extra\":0}\n", "{\"ok\":false,\"text\":\"failure\"}\n",
		"{\"text\":\"\",\"ok\":true}\n",
	}) {
		name := test_pipe_name(t)
		wide := w.utf8_to_wstring(name, context.allocator)
		if !testing.expect(t, wide != nil) { delete(name); return }
		pipe := w.CreateNamedPipeW(wide, w.PIPE_ACCESS_DUPLEX | w.FILE_FLAG_OVERLAPPED,
			w.PIPE_REJECT_REMOTE_CLIENTS, 1, 4096, 4096, 0, nil)
		delete(wide)
		if !testing.expect(t, pipe != w.INVALID_HANDLE_VALUE) { delete(name); return }
		state := Raw_Server{pipe = pipe, payload = payload}
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
		if strings.contains(payload, "failure") {
			testing.expect_value(t, err, control.Error.None)
			testing.expect(t, !r.ok)
			testing.expect_value(t, r.text, "failure")
		} else if strings.has_prefix(payload, "{\"text\"") {
			testing.expect_value(t, err, control.Error.None)
			testing.expect(t, r.ok && r.text == "")
		} else { testing.expect_value(t, err, control.Error.Protocol) }
		control.response_destroy(&r)
		control.close(&c)
		thread.join(worker)
		thread.destroy(worker)
		testing.expect(t, state.read_ok && state.write_ok)
		delete(name)
	}
}
