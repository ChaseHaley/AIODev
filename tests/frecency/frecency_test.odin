package frecency_test

import "core:fmt"
import "core:math"
import "core:mem"
import "core:strings"
import "core:testing"
import "aio:frecency"

@(private = "file")
DAY :: 24 * 60 * 60

@(private = "file")
near :: proc(a, b: f64) -> bool {return math.abs(a - b) < 1e-9}

@(test)
score_adds_one_per_use_and_halves_each_half_life :: proc(t: ^testing.T) {
	testing.expect_value(t, frecency.score({}, 1000), 0.0)
	u := frecency.use({}, 1000)
	testing.expect_value(t, u.count, 1)
	testing.expect_value(t, u.last, i64(1000))
	testing.expect(t, near(frecency.score(u, 1000), 1))
	testing.expect(t, near(frecency.score(u, 1000 + frecency.HALF_LIFE), 0.5))
	testing.expect(t, near(frecency.score(u, 1000 + 2 * frecency.HALF_LIFE), 0.25))
	u = frecency.use(u, 1000 + frecency.HALF_LIFE)
	testing.expect_value(t, u.count, 2)
	testing.expect(t, near(u.weight, 1.5))
	// A clock that moved back counts the last use as current and keeps the later time.
	testing.expect(t, near(frecency.score(u, 0), 1.5))
	testing.expect_value(t, frecency.use(u, 0).last, i64(1000 + frecency.HALF_LIFE))
}

@(test)
score_weighs_recency_against_frequency :: proc(t: ^testing.T) {
	now := i64(100 * DAY)
	month_old: frecency.Usage
	for _ in 0 ..< 10 {month_old = frecency.use(month_old, now - 30 * DAY)}
	hour_old := frecency.use({}, now - 60 * 60)
	testing.expect(t, frecency.score(hour_old, now) > frecency.score(month_old, now))
	// Among uses of the same age, more uses score higher.
	once := frecency.use({}, now - DAY)
	twice := frecency.use(once, now - DAY)
	testing.expect(t, frecency.score(twice, now) > frecency.score(once, now))
	// Three uses a week ago still beat one yesterday.
	week_old: frecency.Usage
	for _ in 0 ..< 3 {week_old = frecency.use(week_old, now - 7 * DAY)}
	testing.expect(t, frecency.score(week_old, now) > frecency.score(once, now))
}

@(test)
table_owns_its_keys_and_drops_the_lowest_score_when_full :: proc(t: ^testing.T) {
	tracking: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracking, context.allocator)
	defer mem.tracking_allocator_destroy(&tracking)
	context.allocator = mem.tracking_allocator(&tracking)
	{
		table: frecency.Table(string)
		defer frecency.destroy(&table)
		// The table keeps its own copy of a caller's key.
		key := strings.clone("pane.split_right")
		for _ in 0 ..< 50 {testing.expect(t, frecency.record(&table, key, 0))}
		delete(key)
		testing.expect(t, near(frecency.lookup(&table, "pane.split_right", 0), 50))
		testing.expect_value(t, frecency.lookup(&table, "never.run", 0), 0.0)

		for i in 0 ..< frecency.LIMIT + 10 {
			testing.expect(t, frecency.record(&table, fmt.tprintf("command.%d", i), i64(i) * 60))
		}
		testing.expect_value(t, len(table.entries), frecency.LIMIT)
		now := i64(frecency.LIMIT + 10) * 60
		// The heavily used key outlives single uses; the oldest single uses went first.
		testing.expect(t, frecency.lookup(&table, "pane.split_right", now) > 49)
		for i in 0 ..< 11 {
			testing.expectf(t, fmt.tprintf("command.%d", i) not_in table.entries, "command.%d was kept", i)
		}
		testing.expect(t, "command.11" in table.entries)

		// Restoring keeps a usage already present and skips an empty one.
		testing.expect(t, frecency.restore(&table, "pane.split_right", {count = 1, last = 0, weight = 1}, now))
		testing.expect(t, frecency.lookup(&table, "pane.split_right", now) > 49)
		testing.expect(t, frecency.restore(&table, "never.run", {}, now))
		testing.expect(t, "never.run" not_in table.entries)

		ids: frecency.Table(u64)
		defer frecency.destroy(&ids)
		testing.expect(t, frecency.record(&ids, 7, 0))
		testing.expect(t, near(frecency.lookup(&ids, 7, 0), 1))
	}
	testing.expectf(t, len(tracking.allocation_map) == 0, "%d allocations leaked", len(tracking.allocation_map))
}
