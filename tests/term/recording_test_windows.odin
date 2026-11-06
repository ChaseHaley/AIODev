package term_test

import "aio:term"
import "core:fmt"
import w "core:sys/windows"
import "core:testing"

// A capture whose file stops accepting writes ends as Faulted, which the stop reports instead of a
// clean stop. A named pipe stands in for the failing disk: closing its server end fails every later
// write.
@(test)
record_stop_reports_a_capture_a_write_error_ended :: proc(t: ^testing.T) {
	wakes: Wakes
	// The reader thread logs the fault through the context the session captured at creation;
	// expectations still report through the runner's logger.
	logger := context.logger
	context.logger = {}
	s := start(t, POWERSHELL + "\"[Console]::WriteLine('READY'); $null = [Console]::ReadLine(); " +
		"[Console]::WriteLine('AFTER_FAULT')\"", &wakes)
	context.logger = logger
	if s == nil {return}
	defer term.destroy(s)
	if !await(t, s, shows, "READY") {return}
	name := fmt.tprintf(`\\.\pipe\aio-record-fault-%d`, w.GetCurrentProcessId())
	server := w.CreateNamedPipeW(
		w.utf8_to_wstring(name, context.temp_allocator),
		w.PIPE_ACCESS_DUPLEX,
		w.PIPE_TYPE_BYTE | w.PIPE_WAIT,
		1,
		0,
		4096,
		0,
		nil,
	)
	if !testing.expect(t, server != w.INVALID_HANDLE_VALUE) {return}
	server_open := true
	defer if server_open {w.CloseHandle(server)}
	if !testing.expect_value(t, term.record_start(s, name), term.Record_Start_Error.None) {return}
	header: [term.CAPTURE_HEADER_SIZE]u8
	read: u32
	if !testing.expect(t, bool(w.ReadFile(server, &header[0], u32(len(header)), &read, nil))) {return}
	testing.expect_value(t, read, u32(len(header)))
	w.CloseHandle(server)
	server_open = false
	press_and_release(s, enter({}, 0))
	if !await(t, s, shows, "AFTER_FAULT") {return}
	// A faulted capture still occupies the session until its stop reports it.
	testing.expect_value(t, term.record_start(s, name), term.Record_Start_Error.Already_Recording)
	path, _, ended := term.record_stop(s)
	testing.expect_value(t, ended, term.Record_Stop.Faulted)
	testing.expect_value(t, path, name)
	_, _, again := term.record_stop(s)
	testing.expect_value(t, again, term.Record_Stop.Not_Recording)
}
