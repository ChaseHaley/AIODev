package main

import "aio:term"
import "aio:verify_protocol"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

_ :: verify_protocol
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
		request: verify_protocol.Vt,
	) -> verify_protocol.Error {
		if app.paths.captures == "" {
			return verify_protocol.explain(
				out,
				"no instance data directory; start the app with --data-dir",
				.System,
			)
		}
		w := verify_window(app)
		if w == nil {
			return verify_protocol.explain(out, "no focused session; focus a pane and retry")
		}
		entry := focused_session(app, w)
		if entry == nil {
			return verify_protocol.explain(out, "no focused session; focus a pane and retry")
		}
		if !request.recording {
			path, bytes, ended := term.record_stop(entry.session)
			switch ended {
			case .Not_Recording:
				return verify_protocol.explain(out, "this session is not recording")
			case .Faulted:
				return verify_protocol.explain(
					out,
					fmt.tprintf("writing the capture %s failed; it holds the first %d bytes", path, bytes),
					.System,
				)
			case .Stopped:
			}
			fmt.sbprintf(out, "ok; stopped %s bytes=%d\n", path, bytes)
			return .None
		}
		path, failure := vt_capture_path(app, entry.id)
		if failure != "" {
			return verify_protocol.explain(out, failure, .System)
		}
		switch term.record_start(entry.session, path) {
		case .None:
		case .Already_Recording:
			return verify_protocol.explain(out, "this session is already recording")
		case .File_Failed:
			return verify_protocol.explain(
				out,
				fmt.tprintf("cannot write the capture %s; check the data directory", path),
				.System,
			)
		case .Out_Of_Memory:
			return verify_protocol.explain(out, "not enough memory to start recording", .Out_Of_Memory)
		}
		fmt.sbprintf(out, "ok; recording %s\n", path)
		return .None
	}

	// vt_capture_path picks the first free name so a second recording of the same pane never
	// overwrites evidence from the first. On failure the returned message explains the directory.
	@(private, require_results)
	vt_capture_path :: proc(app: ^App, session_id: u32) -> (path, failure: string) {
		directory := app.paths.captures
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
}
