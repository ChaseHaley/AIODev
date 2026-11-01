package control_test

import "aio:control"
import "core:fmt"
import "core:os"
import "core:testing"
import "core:thread"
import w "core:sys/windows"

@(private)
identity_accept_only :: proc(worker: ^thread.Thread) {
	p := cast(^Identity_Probe)worker.data
	_ = identity_accept(p)
}

@(private)
expect_identity :: proc(
	t: ^testing.T,
	client: ^control.Client,
	identity: control.Server_Identity,
	want: control.Error,
	label: string,
) {
	// verify_server logs a diagnostic for each rejection, and the test runner counts any
	// error-level log as a test failure. A deliberate rejection is checked with logging off.
	logger := context.logger
	context.logger = {}
	defer context.logger = logger
	got := control.verify_server(client, identity)
	testing.expectf(t, got == want, "%s: expected %v, got %v", label, want, got)
}

@(test)
server_identity_accepts_the_expected_process_and_rejects_a_decoy :: proc(t: ^testing.T) {
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
		1,
		8192,
		8192,
		0,
		nil,
	)
	if !testing.expect(
		t,
		pipe != w.INVALID_HANDLE_VALUE,
		fmt.tprintf("CreateNamedPipeW: %v", w.GetLastError()),
	) {
		return
	}
	defer testing.expect(t, bool(w.CloseHandle(pipe)), "CloseHandle pipe")
	probe := Identity_Probe{pipe = pipe}
	worker := thread.create(identity_accept_only)
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
	image, image_error := os.get_executable_path(context.allocator)
	if !testing.expect_value(t, image_error, nil) {return}
	defer delete(image)
	pid := w.GetCurrentProcessId()
	expect_identity(t, &client, {pid = pid, image = image}, .None, "pid and image")
	created, exited, kernel, user: w.FILETIME
	if testing.expect(
		t,
		bool(w.GetProcessTimes(w.GetCurrentProcess(), &created, &exited, &kernel, &user)),
	) {
		created_value := u64(created.dwHighDateTime) << 32 | u64(created.dwLowDateTime)
		expect_identity(
			t,
			&client,
			{pid = pid, created = created_value, image = image},
			.None,
			"pid, creation time and image",
		)
	}
	expect_identity(t, &client, {pid = pid + 1, image = image}, .Impostor, "wrong pid")
	expect_identity(
		t,
		&client,
		{pid = pid, image = `C:\Windows\System32\notepad.exe`},
		.Impostor,
		"wrong image",
	)
	expect_identity(
		t,
		&client,
		{pid = pid, created = 1, image = image},
		.Impostor,
		"wrong creation time",
	)
	expect_identity(t, &client, {}, .Invalid_Argument, "empty identity")
	thread.join(worker)
	joined = true
	testing.expect(
		t,
		probe.failure_call == "",
		fmt.tprintf("%s: %v", probe.failure_call, probe.error),
	)
}
