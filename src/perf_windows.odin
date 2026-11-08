package main

import "aio:font"
import "aio:glyphs"
import "aio:perf"
import "aio:term"
import "aio:verify_protocol"
import "core:fmt"
import "core:strings"

_ :: verify_protocol
_ :: font
_ :: glyphs
_ :: perf
_ :: term
_ :: fmt
_ :: strings

// Timing evidence: format the counters recorded in the App's perf.Stats and in the packages that
// own the remaining counters, in verify_protocol.PERF_REPLY_FORMAT's order.

when AIO_CONTROL {
	// The owner a counter's --reset goes to, in the order the resets run.
	Perf_Owner :: enum {
		Pty,
		Shaping,
		Glyphs,
		Frames,
	}

	Perf_Counter :: struct {
		value: any,
		owner: Perf_Owner,
	}

	@(require_results)
	perf_read :: proc(
		app: ^App,
		out: ^strings.Builder,
		request: verify_protocol.Perf,
	) -> verify_protocol.Error {
		s := perf.snapshot(&app.perf)
		pty_bytes: u64
		for entry in app.sessions {
			if entry.session == nil {continue}
			pty_bytes += term.session_pty_bytes(entry.session)
		}
		per_second: f64
		if s.uptime_ms > 0 {
			per_second = f64(pty_bytes) * 1000 / f64(s.uptime_ms)
		}
		shape_calls := font.shape_calls(app.fonts)
		hits, misses := glyphs.glyph_counts(&app.cache)
		// One entry per PERF_REPLY_FORMAT verb, in its order. frames.presented here is
		// perf.Stats.presented; Verify.frames documents how it differs from state's key.
		counters := [?]Perf_Counter {
			{s.presented, .Frames},
			{s.built, .Frames},
			{s.build.p50_ms, .Frames},
			{s.build.p95_ms, .Frames},
			{s.build.max_ms, .Frames},
			{s.render.p50_ms, .Frames},
			{s.render.p95_ms, .Frames},
			{s.render.max_ms, .Frames},
			{s.input_last_ms, .Frames},
			{s.input.p50_ms, .Frames},
			{s.input.p95_ms, .Frames},
			{s.input.max_ms, .Frames},
			{pty_bytes, .Pty},
			{per_second, .Pty},
			{shape_calls, .Shaping},
			{hits, .Glyphs},
			{misses, .Glyphs},
			{s.idle_presents, .Frames},
			{s.uptime_ms, .Frames},
		}
		values: [len(counters)]any
		owners: bit_set[Perf_Owner]
		for counter, i in counters {
			values[i] = counter.value
			owners += {counter.owner}
		}
		buffer: [1024]u8
		text := fmt.bprintf(buffer[:], verify_protocol.PERF_REPLY_FORMAT, ..values[:])
		if _, err := append(&out.buf, ..transmute([]u8)text); err != nil {
			return verify_protocol.explain(out, "not enough memory for the perf reply", .Out_Of_Memory)
		}
		if !request.reset {return .None}
		// Every printed counter belongs to its owner, so reset each one after the reply is built.
		// Live sessions keep their PTYs; only the delivered totals restart.
		for owner in owners {
			switch owner {
			case .Frames:
				perf.reset(&app.perf)
			case .Pty:
				for entry in app.sessions {
					if entry.session == nil {continue}
					term.session_reset_pty_bytes(entry.session)
				}
			case .Shaping:
				font.reset_shape_calls(app.fonts)
			case .Glyphs:
				glyphs.reset_counts(&app.cache)
			}
		}
		return .None
	}
}
