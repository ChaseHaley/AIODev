package turns_test

import "aio:turns"
import "core:testing"

@(test)
a_segment_ended_exactly_the_retention_ago_is_kept_and_one_millisecond_older_is_dropped :: proc(t: ^testing.T) {
	now: i64 = 1_760_000_000_000
	segments := [?]turns.Segment {
		{id = 1, ended = now - 14 * turns.DAY_MS},
		{id = 2, ended = now - 14 * turns.DAY_MS - 1},
		{id = 3, ended = now - 14 * turns.DAY_MS + 1},
		{id = 4, ended = now},
		{id = 5, ended = 0},
	}
	ids := turns.expired(segments[:], now, 14)
	defer delete(ids)
	testing.expect_value(t, len(ids), 2)
	testing.expect_value(t, ids[0], 2)
	testing.expect_value(t, ids[1], 5)
}

@(test)
retention_counts_whole_days :: proc(t: ^testing.T) {
	now: i64 = 100 * turns.DAY_MS
	segments := [?]turns.Segment{{id = 1, ended = 98 * turns.DAY_MS}, {id = 2, ended = 98 * turns.DAY_MS - 1}}
	one := turns.expired(segments[:], now, 1)
	defer delete(one)
	testing.expect_value(t, len(one), 2)
	two := turns.expired(segments[:], now, 2)
	defer delete(two)
	testing.expect_value(t, len(two), 1)
	testing.expect_value(t, two[0], 2)
}

@(test)
no_retention_limit_keeps_everything :: proc(t: ^testing.T) {
	segments := [?]turns.Segment{{id = 1, ended = 0}, {id = 2, ended = -5}}
	testing.expect_value(t, len(turns.expired(segments[:], 1 << 50, 0)), 0)
	testing.expect_value(t, len(turns.expired(segments[:], 1 << 50, -3)), 0)
}

@(test)
nothing_expired_and_no_segments_give_no_ids :: proc(t: ^testing.T) {
	segments := [?]turns.Segment{{id = 1, ended = 1000}}
	testing.expect_value(t, len(turns.expired(segments[:], 2000, 14)), 0)
	testing.expect_value(t, len(turns.expired(nil, 2000, 14)), 0)
}
