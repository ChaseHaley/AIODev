package perf

import "core:slice"
import "core:time"

// Frame timing and present counters behind `aioctl perf`. The App owns one Stats value and hands
// it to every call, so nothing here is a process-wide singleton: tests, tools, and a future
// second instance never share counters. Recording, snapshotting, and resetting all run on the
// app's main thread. Counters that other threads or packages own (PTY bytes, shaping runs, glyph
// cache lookups) live with their owners and are read separately by perf_read.

// Retained samples per series. At 60 Hz a window keeps the last ~17 seconds, which is enough for
// p95 while still fitting the percentile scratch copy on the stack.
CAPACITY :: 1024

// A frame is idle when no injected input or control request arrived for this long.
IDLE_THRESHOLD :: 500 * time.Millisecond

// Timings holds nearest-rank percentiles and the maximum of one sample series, in milliseconds.
Timings :: struct {
	p50_ms, p95_ms, max_ms: f32,
}

// Ring retains the newest CAPACITY samples without allocating; arrival order is kept so the
// percentile copy is the only place that ever sorts.
Ring :: struct {
	samples: [CAPACITY]f32,
	next:    int,
	count:   int,
}

Stats :: struct {
	started, last_activity, pending_input: time.Tick,
	input_pending:                         bool,
	presented, built, idle_presents:       u64,
	last_input_ms:                         f32,
	build, render, input:                  Ring,
}

// Snapshot is a consistent read of the Stats counters plus the percentiles they imply.
Snapshot :: struct {
	presented, built, idle_presents: u64,
	build, render, input:            Timings,
	input_last_ms:                   f32,
	// input_samples counts retained latency samples, so callers can tell a fresh sample from a
	// stale last value.
	input_samples: int,
	uptime_ms:     u64,
}

// start marks the beginning of the interval uptime.ms and pty.bytes_per_second describe. App
// initialization calls it once; reset calls it again.
start :: proc(s: ^Stats) {
	now := time.tick_now()
	s.started, s.last_activity = now, now
}

// since_ms reports the milliseconds elapsed since `begin`, for callers timing one phase.
@(require_results)
since_ms :: proc(begin: time.Tick) -> f32 {
	return f32(time.duration_milliseconds(time.tick_diff(begin, time.tick_now())))
}

// idle_at reports whether no injected input or control request arrived for IDLE_THRESHOLD as of
// `now`. A shell that is only printing output still leaves the app idle: idle.presents counts
// frames nobody asked for through the control channel. Callers pass a tick they already read, so
// the frame path needs no extra clock read for the predicate.
@(require_results)
idle_at :: proc(s: ^Stats, now: time.Tick) -> bool {
	return time.tick_diff(s.last_activity, now) >= IDLE_THRESHOLD
}

// mark_input records when the app accepted an injected control input. The next presented frame
// turns that mark into one input-latency sample; a later mark before a frame replaces it.
mark_input :: proc(s: ^Stats) {
	now := time.tick_now()
	s.pending_input, s.input_pending = now, true
	s.last_activity = now
}

// mark_built counts one draw list that built without asking for another attempt.
mark_built :: proc(s: ^Stats) {
	s.built += 1
}

// record_frame adds one presented frame. `is_idle` comes from idle_at() for the frame's render
// start tick. Frames without a pending input mark add no input-latency sample.
record_frame :: proc(s: ^Stats, build_ms, render_ms: f32, is_idle: bool) {
	ring_push(&s.build, build_ms)
	ring_push(&s.render, render_ms)
	s.presented += 1
	if is_idle {s.idle_presents += 1}
	if s.input_pending {
		present := time.tick_now()
		latency := f32(time.duration_milliseconds(time.tick_diff(s.pending_input, present)))
		s.pending_input, s.input_pending = {}, false
		s.last_input_ms = latency
		ring_push(&s.input, latency)
	}
}

// snapshot copies the counters and computes percentiles from the retained samples. Recording and
// reading happen on the same thread, so the copy needs no lock.
@(require_results)
snapshot :: proc(s: ^Stats) -> Snapshot {
	result := Snapshot {
		presented     = s.presented,
		built         = s.built,
		idle_presents = s.idle_presents,
		input_last_ms = s.last_input_ms,
		input_samples = s.input.count,
		build         = percentiles(s.build.samples[:s.build.count]),
		render        = percentiles(s.render.samples[:s.render.count]),
		input         = percentiles(s.input.samples[:s.input.count]),
	}
	elapsed := time.tick_diff(s.started, time.tick_now())
	if elapsed > 0 {
		result.uptime_ms = u64(elapsed / time.Millisecond)
	}
	return result
}

// reset zeroes every counter and drops retained samples. Uptime restarts, so a rate read after a
// reset describes the interval since it.
reset :: proc(s: ^Stats) {
	s^ = {}
	start(s)
}

@(private)
ring_push :: proc(r: ^Ring, sample: f32) {
	r.samples[r.next] = sample
	r.next = (r.next + 1) % CAPACITY
	if r.count < CAPACITY {r.count += 1}
}

// percentiles sorts a copy, so the ring keeps arrival order and the caller's slice is untouched.
// Zero samples report zero rather than a sentinel.
@(private)
percentiles :: proc(samples: []f32) -> Timings {
	if len(samples) == 0 {return {}}
	assert(len(samples) <= CAPACITY)
	scratch: [CAPACITY]f32
	n := copy(scratch[:], samples)
	slice.sort(scratch[:n])
	return {
		p50_ms = scratch[sample_rank(50, n) - 1],
		p95_ms = scratch[sample_rank(95, n) - 1],
		max_ms = scratch[n - 1],
	}
}

// sample_rank is the nearest rank for `percent` over `count` samples: the smallest rank whose
// cumulative share reaches the percentile. Integer ceiling division keeps a lone sample at p50
// and p95 alike.
@(private)
sample_rank :: proc(percent, count: int) -> int {
	return clamp((percent * count + 99) / 100, 1, count)
}
