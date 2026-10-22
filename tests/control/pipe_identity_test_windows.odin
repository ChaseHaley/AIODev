package control_test

import "aio:control"
import "core:fmt"
import w "core:sys/windows"
import "core:testing"
import "core:thread"

foreign import identity_advapi32 "system:advapi32.lib"

@(private, default_calling_convention = "system")
foreign identity_advapi32 {
	ImpersonateNamedPipeClient :: proc(pipe: w.HANDLE) -> w.BOOL ---
	RevertToSelf :: proc() -> w.BOOL ---
}

@(private)
Identity_Probe :: struct {
	pipe: w.HANDLE,
	level: w.DWORD,
	observed, reverted, replied: bool,
	failure_call: string,
	error: w.DWORD,
}

@(private)
identity_failure :: proc(p: ^Identity_Probe, call: string) {
	p.failure_call, p.error = call, w.GetLastError()
}

@(private, require_results)
identity_accept :: proc(p: ^Identity_Probe) -> bool {
	event := w.CreateEventW(nil, true, false, nil)
	if event == nil {identity_failure(p, "CreateEventW"); return false}
	defer if !bool(w.CloseHandle(event)) {identity_failure(p, "CloseHandle event")}
	ov := w.OVERLAPPED{hEvent = event}
	if bool(w.ConnectNamedPipe(p.pipe, &ov)) {return true}
	code := w.GetLastError()
	if code == w.ERROR_PIPE_CONNECTED {return true}
	if code != w.ERROR_IO_PENDING {identity_failure(p, "ConnectNamedPipe"); return false}
	result := w.WaitForSingleObject(event, 2000)
	if result != w.WAIT_OBJECT_0 {
		if result == w.WAIT_FAILED {identity_failure(p, "WaitForSingleObject")} else {
			p.failure_call, p.error = "WaitForSingleObject result", result
		}
		if !bool(w.CancelIoEx(p.pipe, &ov)) && w.GetLastError() != w.ERROR_NOT_FOUND {
			identity_failure(p, "CancelIoEx")
		}
		n: u32
		if !bool(w.GetOverlappedResult(p.pipe, &ov, &n, true)) &&
		   w.GetLastError() != w.ERROR_OPERATION_ABORTED {
			identity_failure(p, "GetOverlappedResult after cancel")
		}
		return false
	}
	n: u32
	if !bool(w.GetOverlappedResult(p.pipe, &ov, &n, false)) {
		identity_failure(p, "GetOverlappedResult")
		return false
	}
	return true
}

@(private)
identity_observe :: proc(p: ^Identity_Probe) {
	if !bool(ImpersonateNamedPipeClient(p.pipe)) {
		identity_failure(p, "ImpersonateNamedPipeClient")
		return
	}
	defer {
		if bool(RevertToSelf()) {p.reverted = true} else {identity_failure(p, "RevertToSelf")}
	}
	token: w.HANDLE
	if !bool(w.OpenThreadToken(w.GetCurrentThread(), w.TOKEN_QUERY, true, &token)) {
		identity_failure(p, "OpenThreadToken")
		return
	}
	defer if !bool(w.CloseHandle(token)) {identity_failure(p, "CloseHandle token")}
	size: w.DWORD
	if !bool(w.GetTokenInformation(token, .TokenImpersonationLevel, &p.level, size_of(p.level), &size)) {
		identity_failure(p, "GetTokenInformation")
		return
	}
	p.observed = size == size_of(p.level)
}

@(private)
identity_server :: proc(worker: ^thread.Thread) {
	p := cast(^Identity_Probe)worker.data
	if !identity_accept(p) {return}
	buffer: [8192]u8
	_, read_ok := raw_transfer(p.pipe, buffer[:], false)
	if !read_ok {p.failure_call = "read request"; return}
	identity_observe(p)
	// Never perform the reply under the client's token, including a failed reversion.
	if !p.reverted || !p.observed || p.failure_call != "" {return}
	response := "{\"ok\":true,\"text\":\"identity checked\"}\n"
	n, write_ok := raw_transfer(p.pipe, transmute([]u8)response, true)
	p.replied = write_ok && n == len(response)
}

@(test)
pipe_client_grants_identification_only :: proc(t: ^testing.T) {
	name := test_pipe_name(t)
	if name == "" {return}
	defer delete(name)
	wide := w.utf8_to_wstring(name, context.allocator)
	if !testing.expect(t, wide != nil) {return}
	defer delete(wide)
	pipe := w.CreateNamedPipeW(
		wide,
		w.PIPE_ACCESS_DUPLEX | w.FILE_FLAG_OVERLAPPED | w.FILE_FLAG_FIRST_PIPE_INSTANCE,
		w.PIPE_TYPE_BYTE | w.PIPE_READMODE_BYTE | w.PIPE_WAIT | w.PIPE_REJECT_REMOTE_CLIENTS,
		1, 8192, 8192, 0, nil,
	)
	if !testing.expect(t, pipe != w.INVALID_HANDLE_VALUE, fmt.tprintf("CreateNamedPipeW: %v", w.GetLastError())) {
		return
	}
	defer testing.expect(t, bool(w.CloseHandle(pipe)), "CloseHandle pipe")
	probe := Identity_Probe{pipe = pipe}
	worker := thread.create(identity_server)
	if !testing.expect(t, worker != nil) {return}
	worker.data = &probe
	joined := false
	defer {
		if !joined {thread.join(worker)}
		thread.destroy(worker)
	}
	thread.start(worker)
	client, connect_error := control.connect(name, 2000)
	if !testing.expect_value(t, connect_error, control.Error.None) {return}
	defer control.close(&client)
	testing.expect_value(t, client.process_id, w.GetCurrentProcessId())
	response, call_error := control.call(&client, {"ping"}, 2000)
	defer control.response_destroy(&response)
	thread.join(worker)
	joined = true
	testing.expect(t, probe.failure_call == "", fmt.tprintf("%s: %v", probe.failure_call, probe.error))
	testing.expect(t, probe.observed, "server observed the actual client token")
	testing.expect_value(t, probe.level, w.DWORD(w.SECURITY_IMPERSONATION_LEVEL.SecurityIdentification))
	testing.expect(t, probe.reverted, "observer reverted before replying")
	testing.expect(t, probe.replied)
	testing.expect_value(t, call_error, control.Error.None)
	testing.expect(t, response.ok)
	testing.expect_value(t, response.text, "identity checked")
}
