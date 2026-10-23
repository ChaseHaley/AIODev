package main

import "aio:control"
import "aio:term"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

_ :: control
_ :: fmt
_ :: os
_ :: filepath
_ :: strings
_ :: term

// PTY evidence: start or stop capturing the focused session's raw output for vtreplay.

when AIO_CONTROL {
	// Names are vt-<session>-001.bin upward, so this bound is also the digits the name shows.
	@(private)
	CAPTURE_COUNTER_LIMIT :: 999

	@(require_results)
	vt_record :: proc(
		app: ^App,
		out: ^strings.Builder,
		request: control.Vt,
	) -> control.Error {
		if app.options.data_dir == "" {
			return vt_failure(
				out,
				.System,
				"no instance data directory; start the app with --data-dir",
			)
		}
		w := verify_window(app)
		if w == nil {
			return vt_failure(out, .Invalid_Argument, "no focused session; focus a pane and retry")
		}
		entry := focused_session(app, w)
		if entry == nil {
			return vt_failure(out, .Invalid_Argument, "no focused session; focus a pane and retry")
		}
		if !request.recording {
			path, bytes, stopped := term.record_stop(entry.session)
			if !stopped {
				return vt_failure(out, .Invalid_Argument, "this session is not recording")
			}
			fmt.sbprintf(out, "ok; stopped %s bytes=%d\n", path, bytes)
			return .None
		}
		path, failure := vt_capture_path(app, entry.id)
		if failure != "" {
			return vt_failure(out, .System, failure)
		}
		switch term.record_start(entry.session, path) {
		case .None:
		case .Already_Recording:
			return vt_failure(out, .Invalid_Argument, "this session is already recording")
		case .File_Failed:
			return vt_failure(
				out,
				.System,
				fmt.tprintf("cannot write the capture %s; check the data directory", path),
			)
		case .Out_Of_Memory:
			return vt_failure(out, .Out_Of_Memory, "not enough memory to start recording")
		}
		fmt.sbprintf(out, "ok; recording %s\n", path)
		return .None
	}

	// vt_capture_path picks the first free name so a second recording of the same pane never
	// overwrites evidence from the first. On failure the returned message explains the directory.
	@(private, require_results)
	vt_capture_path :: proc(app: ^App, session_id: u32) -> (path, failure: string) {
		directory, join_error := filepath.join(
			{app.options.data_dir, "captures"},
			context.temp_allocator,
		)
		if join_error != nil {
			return "", "not enough memory for the capture path"
		}
		if err := os.mkdir_all(directory); err != nil {
			return "", fmt.tprintf("cannot create %s (%v); check the data directory", directory, err)
		}
		for counter in 1 ..= CAPTURE_COUNTER_LIMIT {
			name := fmt.tprintf("vt-%d-%03d.bin", session_id, counter)
			candidate, path_error := filepath.join({directory, name}, context.temp_allocator)
			if path_error != nil {
				return "", "not enough memory for the capture path"
			}
			if !os.exists(candidate) {
				return candidate, ""
			}
		}
		return "", fmt.tprintf("all %d capture names for this session are taken", CAPTURE_COUNTER_LIMIT)
	}

	// vt_failure writes the message the control client prints; verify_read forwards any output that
	// starts with "error:" instead of replacing it with a generic failure line.
	@(private, require_results)
	vt_failure :: proc(
		out: ^strings.Builder,
		err: control.Error,
		message: string,
	) -> control.Error {
		fmt.sbprintf(out, "error: %s", message)
		return err
	}
}
