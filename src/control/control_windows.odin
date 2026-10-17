package control

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import w "core:sys/windows"

Server :: struct {
	allocator: runtime.Allocator,
	wake: Wake,
	pipe, stop, ready: w.HANDLE,
	worker: ^thread.Thread,
	mutex: sync.Mutex, // Guards request, response, and delivery state.
	pending: ^Message,
	active, serial, completed: u64,
	response: []u8,
}
Client :: struct {
	pipe: w.HANDLE,
	process_id: u32,
	allocator: runtime.Allocator,
	reader: Line_Reader,
}

@(private)
Line_Reader :: struct { buffer: [8192]u8, first, last: int }

@(private, require_results)
os_error :: proc(call: string) -> Error {
	code := w.GetLastError()
	log.errorf("control: %s failed: %v", call, code)
	if code == w.ERROR_BROKEN_PIPE || code == w.ERROR_NO_DATA || code == ERROR_PIPE_NOT_CONNECTED {
		return .Closed
	}
	return .System
}

@(private)
close_handle :: proc(h: ^w.HANDLE) {
	if h^ == nil || h^ == w.INVALID_HANDLE_VALUE {
		h^ = nil
		return
	}
	if !bool(w.CloseHandle(h^)) {
		log.errorf("control: CloseHandle failed: %v", w.GetLastError())
	}
	h^ = nil
}

@(private)
local_free :: proc(p: rawptr) {
	if p != nil && w.LocalFree(p) != nil {
		log.errorf("control: LocalFree failed: %v", w.GetLastError())
	}
}

@(private, require_results)
security_descriptor :: proc(allocator: runtime.Allocator) -> (w.PSECURITY_DESCRIPTOR, Error) {
	token: w.HANDLE
	if !bool(w.OpenProcessToken(w.GetCurrentProcess(), w.TOKEN_QUERY, &token)) {
		return nil, os_error("OpenProcessToken")
	}
	defer close_handle(&token)
	size: u32
	if bool(w.GetTokenInformation(token, .TokenUser, nil, 0, &size)) ||
	   w.GetLastError() != w.ERROR_INSUFFICIENT_BUFFER { return nil, os_error("GetTokenInformation") }
	buffer, allocation_error := make([]u8, int(size), allocator)
	if allocation_error != nil { return nil, .Out_Of_Memory }
	defer delete(buffer, allocator)
	if !bool(w.GetTokenInformation(token, .TokenUser, raw_data(buffer), size, &size)) {
		return nil, os_error("GetTokenInformation")
	}
	user := (^w.TOKEN_USER)(raw_data(buffer))
	sid: w.LPCWSTR
	if !bool(w.ConvertSidToStringSidW(cast(^w.SID)user.User.Sid, &sid)) {
		return nil, os_error("ConvertSidToStringSidW")
	}
	defer local_free(rawptr(sid))
	text_buffer: [256]u8
	text := w.wstring_to_utf8(text_buffer[:], sid)
	if text == "" { return nil, os_error("WideCharToMultiByte") }
	sddl_buffer: [300]u8
	sddl := fmt.bprintf(sddl_buffer[:], "D:P(A;;GA;;;%s)", text)
	wide := w.utf8_to_wstring(sddl, allocator)
	if wide == nil { return nil, .Out_Of_Memory }
	defer delete(wide, allocator)
	descriptor: w.PSECURITY_DESCRIPTOR
	if !bool(ConvertStringSecurityDescriptorToSecurityDescriptorW(wide, SDDL_REVISION_1, &descriptor, nil)) {
		return nil, os_error("ConvertStringSecurityDescriptorToSecurityDescriptorW")
	}
	return descriptor, .None
}

@(require_results)
create :: proc(name: string, wake: Wake, allocator := context.allocator) -> (^Server, Error) {
	if !valid_pipe_name(name) {
		return nil, .Invalid_Argument
	}
	s, allocation_error := new(Server, allocator)
	if allocation_error != nil { return nil, .Out_Of_Memory }
	s.allocator, s.wake = allocator, wake
	ok := false
	defer if !ok {
		destroy(s)
	}
	descriptor, err := security_descriptor(allocator)
	if err != .None { return nil, err }
	defer local_free(descriptor)
	wide := w.utf8_to_wstring(name, allocator)
	if wide == nil { return nil, .Out_Of_Memory }
	defer delete(wide, allocator)
	sa := w.SECURITY_ATTRIBUTES{nLength = size_of(w.SECURITY_ATTRIBUTES), lpSecurityDescriptor = descriptor}
	s.pipe = w.CreateNamedPipeW(wide,
		w.PIPE_ACCESS_DUPLEX | w.FILE_FLAG_OVERLAPPED | w.FILE_FLAG_FIRST_PIPE_INSTANCE,
		w.PIPE_TYPE_BYTE | w.PIPE_READMODE_BYTE | w.PIPE_WAIT | w.PIPE_REJECT_REMOTE_CLIENTS,
		1, 65536, 65536, 0, &sa)
	if s.pipe == w.INVALID_HANDLE_VALUE { return nil, os_error("CreateNamedPipeW") }
	s.stop = w.CreateEventW(nil, true, false, nil)
	if s.stop == nil { return nil, os_error("CreateEventW") }
	s.ready = w.CreateEventW(nil, false, false, nil)
	if s.ready == nil { return nil, os_error("CreateEventW") }
	s.worker = thread.create(server_thread)
	if s.worker == nil { return nil, .System }
	s.worker.data = s
	thread.start(s.worker)
	ok = true
	return s, .None
}

destroy :: proc(s: ^Server) {
	if s == nil { return }
	if s.stop != nil && !bool(w.SetEvent(s.stop)) {
		log.errorf("control: SetEvent failed: %v", w.GetLastError())
	}
	if s.worker != nil {
		thread.join(s.worker)
		thread.destroy(s.worker)
	}
	message_destroy(s.pending)
	delete(s.response, s.allocator)
	close_handle(&s.pipe)
	close_handle(&s.stop)
	close_handle(&s.ready)
	free(s, s.allocator)
}

// Poll transfers ownership; the caller destroys the message even if its client disconnects.
poll :: proc(s: ^Server) -> ^Message {
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	m := s.pending
	s.pending = nil
	return m
}

@(require_results)
respond :: proc(s: ^Server, id: u64, response: Response) -> Error {
	data, err := encode(response, s.allocator)
	if err != .None { return err }
	sync.mutex_lock(&s.mutex)
	if id == 0 || s.active != id || s.response != nil {
		sync.mutex_unlock(&s.mutex)
		delete(data, s.allocator)
		return .Closed
	}
	s.response = data
	sync.mutex_unlock(&s.mutex)
	if !bool(w.SetEvent(s.ready)) { return os_error("SetEvent") }
	return .None
}

@(require_results)
delivery_finished :: proc(s: ^Server, id: u64) -> bool {
	if s == nil || id == 0 { return false }
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	return id <= s.completed
}

@(private)
finish_delivery :: proc(s: ^Server, id: u64) {
	sync.mutex_lock(&s.mutex)
	s.completed = id
	sync.mutex_unlock(&s.mutex)
}

@(private, require_results)
wait_io :: proc(
	pipe: w.HANDLE, overlapped: ^w.OVERLAPPED, stop: w.HANDLE, timeout: u32,
) -> (u32, Error) {
	handles := [?]w.HANDLE{overlapped.hEvent, stop}
	count: u32 = stop == nil ? 1 : 2
	result := w.WaitForMultipleObjects(count, &handles[0], false, timeout)
	if result != w.WAIT_OBJECT_0 {
		if result == w.WAIT_FAILED {
			log.errorf("control: WaitForMultipleObjects failed: %v", w.GetLastError())
		}
		if !bool(w.CancelIoEx(pipe, overlapped)) && w.GetLastError() != w.ERROR_NOT_FOUND {
			log.errorf("control: CancelIoEx failed: %v", w.GetLastError())
		}
		transferred: u32
		if !bool(w.GetOverlappedResult(pipe, overlapped, &transferred, true)) &&
		   w.GetLastError() != w.ERROR_OPERATION_ABORTED {
			log.errorf("control: GetOverlappedResult after cancel failed: %v", w.GetLastError())
		}
		if result == w.WAIT_TIMEOUT { return 0, .Timeout }
		if result == w.WAIT_OBJECT_0+1 { return 0, .Closed }
		return 0, .System
	}
	n: u32
	if !bool(w.GetOverlappedResult(pipe, overlapped, &n, false)) {
		return 0, os_error("GetOverlappedResult")
	}
	return n, .None
}

@(private, require_results)
transfer :: proc(
	pipe: w.HANDLE, buffer: []u8, writing: bool, stop: w.HANDLE, timeout: u32,
) -> (int, Error) {
	event := w.CreateEventW(nil, true, false, nil)
	if event == nil { return 0, os_error("CreateEventW") }
	defer close_handle(&event)
	ov := w.OVERLAPPED{hEvent = event}
	n: u32
	ok: w.BOOL
	if writing {
		ok = w.WriteFile(pipe, raw_data(buffer), u32(len(buffer)), &n, &ov)
	} else {
		ok = w.ReadFile(pipe, raw_data(buffer), u32(len(buffer)), &n, &ov)
	}
	if !bool(ok) {
		if w.GetLastError() != w.ERROR_IO_PENDING { return 0, os_error(writing ? "WriteFile" : "ReadFile") }
		count, err := wait_io(pipe, &ov, stop, timeout)
		if err == .None && count == 0 { return 0, .Closed }
		return int(count), err
	}
	if n == 0 { return 0, .Closed }
	return int(n), .None
}

@(private)
remaining :: proc(start: time.Tick, timeout: int) -> u32 {
	if timeout < 0 { return w.INFINITE }
	elapsed := int(time.tick_since(start)/time.Millisecond)
	return u32(max(0, timeout-elapsed))
}

@(private, require_results)
read_line :: proc(
	r: ^Line_Reader, pipe: w.HANDLE, stop: w.HANDLE, start: time.Tick, timeout: int,
	allocator: runtime.Allocator,
) -> ([]u8, Error) {
	data := make([dynamic]u8, allocator)
	defer delete(data)
	for {
		if r.first == r.last {
			n, err := transfer(pipe, r.buffer[:], false, stop, remaining(start, timeout))
			if err != .None { return nil, err }
			r.first, r.last = 0, n
		}
		end := r.first
		for end < r.last && r.buffer[end] != '\n' {
			end += 1
		}
		if len(data)+end-r.first > MAX_MESSAGE { return nil, .Protocol }
		if _, err := append(&data, ..r.buffer[r.first:end]); err != nil { return nil, .Out_Of_Memory }
		r.first = end
		if end < r.last {
			r.first += 1
			line, err := make([]u8, len(data), allocator)
			if err != nil { return nil, .Out_Of_Memory }
			copy(line, data[:])
			return line, .None
		}
	}
}

@(private, require_results)
write_line :: proc(pipe: w.HANDLE, data: []u8, stop: w.HANDLE, start: time.Tick, timeout: int) -> Error {
	for offset := 0; offset < len(data); {
		n, err := transfer(pipe, data[offset:], true, stop, remaining(start, timeout))
		if err != .None { return err }
		offset += n
	}
	newline := [1]u8{'\n'}
	_, err := transfer(pipe, newline[:], true, stop, remaining(start, timeout))
	return err
}

@(private, require_results)
accept_client :: proc(s: ^Server) -> Error {
	event := w.CreateEventW(nil, true, false, nil)
	if event == nil { return os_error("CreateEventW") }
	defer close_handle(&event)
	ov := w.OVERLAPPED{hEvent = event}
	if bool(w.ConnectNamedPipe(s.pipe, &ov)) { return .None }
	code := w.GetLastError()
	if code == w.ERROR_PIPE_CONNECTED { return .None }
	if code != w.ERROR_IO_PENDING { return os_error("ConnectNamedPipe") }
	_, err := wait_io(s.pipe, &ov, s.stop, w.INFINITE)
	return err
}

@(private)
clear_request :: proc(s: ^Server) {
	sync.mutex_lock(&s.mutex)
	m, data := s.pending, s.response
	s.pending, s.response, s.active = nil, nil, 0
	sync.mutex_unlock(&s.mutex)
	message_destroy(m)
	delete(data, s.allocator)
}

@(private, require_results)
await_response :: proc(s: ^Server) -> ([]u8, Error) {
	handles := [?]w.HANDLE{s.stop, s.ready}
	for {
		sync.mutex_lock(&s.mutex)
		data := s.response
		s.response = nil
		if data != nil {
			s.active = 0
		}
		sync.mutex_unlock(&s.mutex)
		if data != nil { return data, .None }
		result := w.WaitForMultipleObjects(2, &handles[0], false, 10)
		if result == w.WAIT_OBJECT_0 { return nil, .Closed }
		if result == w.WAIT_FAILED { return nil, os_error("WaitForMultipleObjects") }
		if !bool(w.PeekNamedPipe(s.pipe, nil, 0, nil, nil, nil)) { return nil, os_error("PeekNamedPipe") }
	}
}

@(private, require_results)
serve_client :: proc(s: ^Server) -> Error {
	r: Line_Reader
	for {
		data, read_error := read_line(&r, s.pipe, s.stop, time.tick_now(), -1, s.allocator)
		if read_error != .None { return read_error }
		m, decode_error := decode_request(data, s.allocator)
		delete(data, s.allocator)
		if decode_error != .None { return decode_error }
		if m.parse_error.advice != "" {
			text := strings.builder_make(s.allocator)
			writer := Writer{out = &text}
			quoted(&writer, m.parse_error.argument)
			put(&writer, ": ")
			put(&writer, m.parse_error.advice)
			message_destroy(m)
			if writer.error != .None {
				strings.builder_destroy(&text)
				return writer.error
			}
			response, encode_error := encode(Response{false, strings.to_string(text)}, s.allocator)
			strings.builder_destroy(&text)
			if encode_error != .None { return encode_error }
			write_error := write_line(s.pipe, response, s.stop, time.tick_now(), -1)
			delete(response, s.allocator)
			if write_error != .None { return write_error }
			continue
		}
		sync.mutex_lock(&s.mutex)
		s.serial += 1
		m.id = s.serial
		id := m.id
		s.active, s.pending = m.id, m
		sync.mutex_unlock(&s.mutex)
		if s.wake.procedure != nil {
			s.wake.procedure(s.wake.user)
		}
		response, response_error := await_response(s)
		clear_request(s)
		if response_error != .None {
			finish_delivery(s, id)
			return response_error
		}
		write_error := write_line(s.pipe, response, s.stop, time.tick_now(), -1)
		delete(response, s.allocator)
		finish_delivery(s, id)
		if write_error != .None { return write_error }
	}
}

@(private)
server_thread :: proc(t: ^thread.Thread) {
	s := (^Server)(t.data)
	context.allocator = s.allocator
	for {
		if err := accept_client(s); err != .None {
			break
		}
		err := serve_client(s)
		clear_request(s)
		if err != .Closed && err != .Protocol {
			log.errorf("control: serving client failed: %v", err)
		}
		if err == .Protocol {
			data, encode_error := encode(Response{
				false, "protocol error: use a JSON string array, at most 4 MiB",
			})
			if encode_error == .None {
				if write_error := write_line(s.pipe, data, s.stop, time.tick_now(), 1000);
				   write_error != .None {
					log.errorf("control: protocol reply failed: %v", write_error)
				}
				delete(data)
				// DisconnectNamedPipe discards unread output; allow the peer to read the error and close.
				buffer: [8192]u8
				start := time.tick_now()
				for remaining(start, 1000) > 0 {
					_, drain_error := transfer(s.pipe, buffer[:], false, s.stop, remaining(start, 1000))
					if drain_error != .None {
						break
					}
				}
			} else {
				log.errorf("control: encoding protocol error failed: %v", encode_error)
			}
		}
		if !bool(w.DisconnectNamedPipe(s.pipe)) && w.GetLastError() != ERROR_PIPE_NOT_CONNECTED {
			log.errorf("control: DisconnectNamedPipe failed: %v", w.GetLastError())
		}
		result := w.WaitForSingleObject(s.stop, 0)
		if result == w.WAIT_OBJECT_0 {
			break
		}
		if result == w.WAIT_FAILED {
			log.errorf("control: stop wait failed: %v", w.GetLastError())
			break
		}
	}
}

@(require_results)
connect :: proc(name: string, timeout_ms: int, allocator := context.allocator) -> (Client, Error) {
	if timeout_ms < 0 || timeout_ms > int(max(i32)) || !valid_pipe_name(name) {
		return {}, .Invalid_Argument
	}
	wide := w.utf8_to_wstring(name, allocator)
	if wide == nil { return {}, .Out_Of_Memory }
	defer delete(wide, allocator)
	start := time.tick_now()
	for {
		pipe := w.CreateFileW(wide, w.GENERIC_READ | w.GENERIC_WRITE, 0, nil,
			w.OPEN_EXISTING,
			w.FILE_FLAG_OVERLAPPED | w.SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, nil)
		if pipe != w.INVALID_HANDLE_VALUE {
			id: u32
			if !bool(GetNamedPipeServerProcessId(pipe, &id)) {
				err := os_error("GetNamedPipeServerProcessId")
				close_handle(&pipe)
				return {}, err
			}
			return Client{pipe = pipe, process_id = id, allocator = allocator}, .None
		}
		code := w.GetLastError()
		if code != w.ERROR_FILE_NOT_FOUND && code != w.ERROR_PIPE_BUSY { return {}, os_error("CreateFileW") }
		if remaining(start, timeout_ms) == 0 { return {}, .Timeout }
		time.sleep(time.Duration(min(10, remaining(start, timeout_ms)))*time.Millisecond)
	}
}

close :: proc(c: ^Client) {
	close_handle(&c.pipe)
	c^ = {}
}

@(require_results)
call :: proc(c: ^Client, args: []string, timeout_ms: int = 15000) -> (Response, Error) {
	if c.pipe == nil { return {}, .Closed }
	if timeout_ms < 0 || timeout_ms > int(max(i32)) { return {}, .Invalid_Argument }
	allocator := c.allocator
	data, encode_error := encode(args, allocator)
	if encode_error != .None { return {}, encode_error }
	defer delete(data, allocator)
	start := time.tick_now()
	if err := write_line(c.pipe, data, nil, start, timeout_ms); err != .None {
		close(c)
		return {}, err
	}
	line, read_error := read_line(&c.reader, c.pipe, nil, start, timeout_ms, allocator)
	if read_error != .None {
		close(c)
		return {}, read_error
	}
	defer delete(line, allocator)
	response, decode_error := decode_response(line, allocator)
	if decode_error != .None {
		close(c)
	}
	return response, decode_error
}
