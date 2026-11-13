package platform

@(require) import "core:log"
@(require) import "core:sync"
@(require) import w "core:sys/windows"
@(require) import "core:thread"

// The Win32 backend; a headless build compiles another (see AIO_HEADLESS in platform.odin).
when !AIO_HEADLESS {
	// A program run without a window whose exit the app waits for, as Update AIODev waits for its
	// updater. A thread waits for the process and wakes the loop when it exits.
	Program_Run :: struct {
		process, stop: w.HANDLE,
		thread:        ^thread.Thread,
		platform:      ^Platform,
		exit_code:     u32,
		done:          bool,
	}

	@(private)
	program_run_wait :: proc(t: ^thread.Thread) {
		run := (^Program_Run)(t.data)
		handles := [2]w.HANDLE{run.process, run.stop}
		if w.WaitForMultipleObjects(2, &handles[0], false, w.INFINITE) != w.WAIT_OBJECT_0 {return}
		code: w.DWORD
		if !bool(w.GetExitCodeProcess(run.process, &code)) {
			log.errorf("GetExitCodeProcess failed: %d", w.GetLastError())
			code = max(u32)
		}
		run.exit_code = code
		sync.atomic_store(&run.done, true)
		_ = wake(run.platform)
	}

	// Starts command_line in `directory` with no console window. The command line names its program by
	// explicit path, so nothing is searched for. Returns nil when it could not start.
	@(require_results)
	program_run_start :: proc(p: ^Platform, command_line, directory: string) -> ^Program_Run {
		command := w.utf8_to_wstring(command_line, context.allocator)
		if command == nil {return nil}
		defer delete(command)
		folder := w.utf8_to_wstring(directory, context.allocator)
		if folder == nil {return nil}
		defer delete(folder)
		run, err := new(Program_Run)
		if err != nil {return nil}
		run.platform = p
		run.stop = w.CreateEventW(nil, true, false, nil)
		if run.stop == nil {
			log.errorf("CreateEventW failed: %d", w.GetLastError())
			free(run)
			return nil
		}
		startup := w.STARTUPINFOW{cb = size_of(w.STARTUPINFOW)}
		info: w.PROCESS_INFORMATION
		flags := u32(w.CREATE_NO_WINDOW)
		if !bool(w.CreateProcessW(nil, command, nil, nil, false, flags, nil, folder, &startup, &info)) {
			log.errorf("CreateProcessW failed: Win32 %d", w.GetLastError())
			w.CloseHandle(run.stop)
			free(run)
			return nil
		}
		w.CloseHandle(info.hThread)
		run.process = info.hProcess
		run.thread = thread.create(program_run_wait)
		if run.thread == nil {
			log.error("starting the program wait failed")
			program_run_destroy(run)
			return nil
		}
		run.thread.data = run
		run.thread.init_context = context
		thread.start(run.thread)
		return run
	}

	// Whether the program has exited, and its exit code once it has.
	@(require_results)
	program_run_finished :: proc(run: ^Program_Run) -> (exit_code: u32, finished: bool) {
		if !sync.atomic_load(&run.done) {return 0, false}
		return run.exit_code, true
	}

	// Stops waiting and frees the run; a program still running carries on without the app.
	program_run_destroy :: proc(run: ^Program_Run) {
		if run.thread != nil {
			w.SetEvent(run.stop)
			thread.join(run.thread)
			thread.destroy(run.thread)
		}
		if run.process != nil {w.CloseHandle(run.process)}
		w.CloseHandle(run.stop)
		free(run)
	}
}
