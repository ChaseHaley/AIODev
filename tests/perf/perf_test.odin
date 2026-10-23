package perf_test

import "aio:perf"
import "core:testing"
import "core:time"

record_builds :: proc(s: ^perf.Stats, values: []f32) {
	for value in values {
		perf.record_frame(s, value, 0, false)
	}
}

@(test)
empty_stats_report_zero :: proc(t: ^testing.T) {
	s: perf.Stats
	perf.start(&s)
	snapshot := perf.snapshot(&s)
	testing.expect_value(t, snapshot.presented, u64(0))
	testing.expect_value(t, snapshot.built, u64(0))
	testing.expect_value(t, snapshot.idle_presents, u64(0))
	testing.expect_value(t, snapshot.input_samples, 0)
	testing.expect_value(t, snapshot.build, perf.Timings{})
	testing.expect_value(t, snapshot.render, perf.Timings{})
	testing.expect_value(t, snapshot.input, perf.Timings{})
}

@(test)
recorded_counters_accumulate :: proc(t: ^testing.T) {
	s: perf.Stats
	perf.start(&s)
	perf.mark_built(&s)
	perf.record_frame(&s, 0, 0, true)
	perf.record_frame(&s, 0, 0, false)
	perf.record_frame(&s, 0, 0, true)
	snapshot := perf.snapshot(&s)
	testing.expect_value(t, snapshot.presented, u64(3))
	testing.expect_value(t, snapshot.built, u64(1))
	testing.expect_value(t, snapshot.idle_presents, u64(2))
}

// Nearest rank over three samples: p50 is the second and p95 the third, not an interpolation.
@(test)
nearest_rank_three_samples :: proc(t: ^testing.T) {
	s: perf.Stats
	perf.start(&s)
	record_builds(&s, []f32{1, 2, 3})
	snapshot := perf.snapshot(&s)
	testing.expect_value(t, snapshot.build.p50_ms, f32(2))
	testing.expect_value(t, snapshot.build.p95_ms, f32(3))
	testing.expect_value(t, snapshot.build.max_ms, f32(3))
}

@(test)
nearest_rank_hundred_samples :: proc(t: ^testing.T) {
	s: perf.Stats
	perf.start(&s)
	values: [100]f32
	for i in 0 ..< len(values) {
		values[i] = f32(i + 1)
	}
	record_builds(&s, values[:])
	snapshot := perf.snapshot(&s)
	testing.expect_value(t, snapshot.build.p50_ms, f32(50))
	testing.expect_value(t, snapshot.build.p95_ms, f32(95))
	testing.expect_value(t, snapshot.build.max_ms, f32(100))
}

// The ring keeps the newest CAPACITY samples, so an overwritten prefix must not reach a percentile.
@(test)
ring_wraparound_keeps_newest_samples :: proc(t: ^testing.T) {
	s: perf.Stats
	perf.start(&s)
	values: [perf.CAPACITY + 476]f32
	for i in 0 ..< len(values) {
		values[i] = f32(i + 1)
	}
	record_builds(&s, values[:])
	snapshot := perf.snapshot(&s)
	// Retained samples are 477..1500: nearest rank 512 is 988, rank 973 is 1449.
	testing.expect_value(t, snapshot.build.p50_ms, f32(988))
	testing.expect_value(t, snapshot.build.p95_ms, f32(1449))
	testing.expect_value(t, snapshot.build.max_ms, f32(1500))
}

@(test)
reset_clears_samples_and_counters :: proc(t: ^testing.T) {
	s: perf.Stats
	perf.start(&s)
	perf.mark_built(&s)
	record_builds(&s, []f32{4, 8})
	perf.reset(&s)
	snapshot := perf.snapshot(&s)
	testing.expect_value(t, snapshot.presented, u64(0))
	testing.expect_value(t, snapshot.built, u64(0))
	testing.expect_value(t, snapshot.build, perf.Timings{})
	testing.expect_value(t, snapshot.render, perf.Timings{})
	testing.expect_value(t, snapshot.input, perf.Timings{})
	testing.expect_value(t, snapshot.input_last_ms, f32(0))
}

// One input mark becomes exactly one latency sample, and later frames do not reuse it.
@(test)
input_mark_is_consumed_once :: proc(t: ^testing.T) {
	s: perf.Stats
	perf.start(&s)
	perf.mark_input(&s)
	perf.record_frame(&s, 0, 0, false)
	first := perf.snapshot(&s)
	testing.expect_value(t, first.input_samples, 1)
	testing.expect_value(t, first.input.p50_ms, first.input_last_ms)
	testing.expect_value(t, first.input.max_ms, first.input_last_ms)
	perf.record_frame(&s, 0, 0, false)
	second := perf.snapshot(&s)
	testing.expect_value(t, second.input_samples, 1)
	testing.expect_value(t, second.input_last_ms, first.input_last_ms)
}

// A second mark before a frame replaces the pending one instead of queuing two samples.
@(test)
input_mark_replaces_pending_mark :: proc(t: ^testing.T) {
	s: perf.Stats
	perf.start(&s)
	perf.mark_input(&s)
	perf.mark_input(&s)
	perf.record_frame(&s, 0, 0, false)
	snapshot := perf.snapshot(&s)
	testing.expect_value(t, snapshot.input_samples, 1)
}

// An input mark restarts the idle clock, so the frame that consumes it is not idle. The test
// avoids asserting the 500 ms threshold itself, which would depend on wall-clock precision.
@(test)
input_mark_suppresses_idle :: proc(t: ^testing.T) {
	s: perf.Stats
	perf.start(&s)
	perf.mark_input(&s)
	testing.expect(t, !perf.idle_at(&s, time.tick_now()))
}
