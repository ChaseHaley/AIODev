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
		hits, misses := glyphs.glyph_counts(&app.cache)
		buffer: [1024]u8
		text := fmt.bprintf(
			buffer[:],
			verify_protocol.PERF_REPLY_FORMAT,
			s.presented,
			s.built,
			s.build.p50_ms,
			s.build.p95_ms,
			s.build.max_ms,
			s.render.p50_ms,
			s.render.p95_ms,
			s.render.max_ms,
			s.input_last_ms,
			s.input.p50_ms,
			s.input.p95_ms,
			s.input.max_ms,
			pty_bytes,
			per_second,
			font.shape_calls(app.fonts),
			hits,
			misses,
			s.idle_presents,
			s.uptime_ms,
		)
		if _, err := append(&out.buf, ..transmute([]u8)text); err != nil {
			return verify_protocol.explain(out, "not enough memory for the perf reply", .Out_Of_Memory)
		}
		if request.reset {
			// Every printed counter belongs to its owner, so reset each one after the reply is
			// built. Live sessions keep their PTYs; only the delivered totals restart.
			for entry in app.sessions {
				if entry.session == nil {continue}
				term.session_reset_pty_bytes(entry.session)
			}
			font.reset_shape_calls(app.fonts)
			glyphs.reset_counts(&app.cache)
			perf.reset(&app.perf)
		}
		return .None
	}
}
