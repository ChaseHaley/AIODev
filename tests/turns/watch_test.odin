package turns_test

import "aio:turns"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

// How long a change may take to reach the watch before a test calls it lost.
@(private = "file")
WATCH_PATIENCE :: 3 * time.Second

@(private = "file")
Watch_Count :: struct {
	count: i32,
}

@(private = "file")
watch_counted :: proc "contextless" (data: rawptr) {
	counter := (^Watch_Count)(data)
	sync.atomic_add(&counter.count, 1)
}

// A temp directory, the watch on it, and every path the watch has reported so far.
@(private = "file")
Watched :: struct {
	directory: string,
	counter:   Watch_Count,
	watch:     ^turns.Watch,
	seen:      [dynamic]string,
}

@(private = "file")
watch_prepare :: proc(t: ^testing.T, f: ^Watched) -> bool {
	directory, directory_error := os.make_directory_temp("", "aio-watch-*", context.allocator)
	if !testing.expect_value(t, directory_error, nil) {return false}
	f.directory = directory
	return true
}

@(private = "file")
watch_begin :: proc(t: ^testing.T, f: ^Watched, recursive: bool) -> bool {
	wake := turns.Watch_Wake {
		data = &f.counter,
		wake = watch_counted,
	}
	started: bool
	f.watch, started = turns.watch_start(f.directory, recursive, wake)
	return testing.expect(t, started, "the watch starts")
}

@(private = "file")
watch_destroy :: proc(t: ^testing.T, f: ^Watched) {
	turns.watch_stop(f.watch)
	for path in f.seen {delete(path)}
	delete(f.seen)
	if f.directory != "" {
		testing.expect_value(t, os.remove_all(f.directory), nil)
		delete(f.directory)
	}
}

@(private = "file")
watch_path :: proc(f: ^Watched, name: string) -> string {
	return strings.concatenate({f.directory, "/", name}, context.temp_allocator)
}

@(private = "file")
watch_write :: proc(t: ^testing.T, f: ^Watched, name, text: string) {
	testing.expect_value(t, os.write_entire_file(watch_path(f, name), text), nil)
}

@(private = "file")
watch_mkdir :: proc(t: ^testing.T, f: ^Watched, name: string) {
	testing.expect_value(t, os.make_directory(watch_path(f, name)), nil)
}

@(private = "file")
watch_seen :: proc(f: ^Watched, path: string) -> bool {
	for seen in f.seen {
		if seen == path {return true}
	}
	return false
}

// Takes from the watch until every wanted path has been reported or the patience runs out, and
// checks each take on the way: no overflow, no path twice.
@(private = "file")
watch_collect :: proc(t: ^testing.T, f: ^Watched, wanted: ..string) -> bool {
	began := time.tick_now()
	for {
		batch := make([dynamic]string, context.temp_allocator)
		overflowed := turns.watch_take(f.watch, &batch)
		testing.expect(t, !overflowed, "the buffer does not overflow")
		for path, index in batch {
			for other in batch[:index] {
				testing.expectf(t, other != path, "%q is reported once per take", path)
			}
			append(&f.seen, path)
		}
		found := true
		for want in wanted {
			found &&= watch_seen(f, want)
		}
		if found {return true}
		if time.tick_since(began) > WATCH_PATIENCE {break}
		time.sleep(5 * time.Millisecond)
	}
	for want in wanted {
		testing.expectf(t, watch_seen(f, want), "%q is reported", want)
	}
	return false
}

// Waits for a wake after `before`, the wake count when the change was made.
@(private = "file")
watch_await_wake :: proc(t: ^testing.T, f: ^Watched, before: i32) {
	began := time.tick_now()
	for sync.atomic_load(&f.counter.count) == before && time.tick_since(began) < WATCH_PATIENCE {
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, sync.atomic_load(&f.counter.count) != before, "the watch wakes its owner")
}

// Returns once no wake has come for a while, so every change made so far has been reported.
@(private = "file")
watch_quiet :: proc(f: ^Watched) {
	last := sync.atomic_load(&f.counter.count)
	for quiet_since := time.tick_now(); time.tick_since(quiet_since) < 150 * time.Millisecond; {
		time.sleep(10 * time.Millisecond)
		now := sync.atomic_load(&f.counter.count)
		if now != last {
			last = now
			quiet_since = time.tick_now()
		}
	}
}

@(test)
watch_reports_created_changed_removed_and_renamed_paths :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	f: Watched
	defer watch_destroy(t, &f)
	if !watch_prepare(t, &f) {return}
	watch_write(t, &f, "modified.txt", "one")
	watch_write(t, &f, "removed.txt", "x")
	watch_write(t, &f, "old.txt", "x")
	watch_mkdir(t, &f, "sub")
	watch_write(t, &f, "sub/inner.txt", "x")
	if !watch_begin(t, &f, true) {return}

	watch_write(t, &f, "created.txt", "x")
	watch_write(t, &f, "modified.txt", "two")
	testing.expect_value(t, os.remove(watch_path(&f, "removed.txt")), nil)
	renamed := os.rename(watch_path(&f, "old.txt"), watch_path(&f, "renamed.txt"))
	testing.expect_value(t, renamed, nil)
	watch_write(t, &f, "sub/inner.txt", "y")
	watch_mkdir(t, &f, "sub/deeper")
	watch_write(t, &f, "sub/deeper/new.txt", "x")
	// A BMP letter, CJK, and an emoji that takes a surrogate pair in UTF-16.
	watch_write(t, &f, "naïve-日本-😀.txt", "x")
	watch_write(t, &f, ".gitignore", "x")
	watch_mkdir(t, &f, ".git")
	watch_write(t, &f, ".git/config", "x")
	watch_mkdir(t, &f, ".git/objects")
	watch_write(t, &f, ".git/objects/ab", "x")
	// Only the repository's own .git at the root is dropped.
	watch_mkdir(t, &f, "sub/.git")
	watch_write(t, &f, "sub/.git/x", "x")
	// Changes arrive in the order they were made, so once the last one is reported nothing earlier is
	// still on its way.
	watch_write(t, &f, "zz-last.txt", "x")

	watch_collect(
		t,
		&f,
		"created.txt",
		"modified.txt",
		"removed.txt",
		"old.txt",
		"renamed.txt",
		"sub/inner.txt",
		"sub/deeper/new.txt",
		"naïve-日本-😀.txt",
		".gitignore",
		"sub/.git/x",
		"zz-last.txt",
	)
	for hidden in ([]string{".git", ".git/config", ".git/objects", ".git/objects/ab"}) {
		testing.expectf(t, !watch_seen(&f, hidden), "%q is not reported", hidden)
	}
	for path in f.seen {
		testing.expectf(t, !strings.contains_rune(path, '\\'), "%q uses '/' separators", path)
	}
}

@(test)
watch_reports_a_path_once_per_take :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	f: Watched
	defer watch_destroy(t, &f)
	if !watch_prepare(t, &f) {return}
	if !watch_begin(t, &f, true) {return}

	for _ in 0 ..< 20 {
		watch_write(t, &f, "busy.txt", "x")
	}
	watch_write(t, &f, "other.txt", "x")
	watch_await_wake(t, &f, 0)
	watch_quiet(&f)

	batch := make([dynamic]string, context.temp_allocator)
	testing.expect(t, !turns.watch_take(f.watch, &batch, context.temp_allocator), "no overflow")
	busy, other := 0, 0
	for path in batch {
		switch path {
		case "busy.txt":
			busy += 1
		case "other.txt":
			other += 1
		}
	}
	testing.expect_value(t, busy, 1)
	testing.expect_value(t, other, 1)
}

@(test)
watch_reports_every_path_of_a_burst :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	f: Watched
	defer watch_destroy(t, &f)
	if !watch_prepare(t, &f) {return}
	if !watch_begin(t, &f, true) {return}

	names := make([dynamic]string, context.temp_allocator)
	for index in 0 ..< 200 {
		name := fmt.tprintf("burst-%03d.txt", index)
		append(&names, name)
		watch_write(t, &f, name, "x")
	}
	watch_collect(t, &f, ..names[:])
}

@(test)
watch_non_recursive_ignores_nested_files :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	f: Watched
	defer watch_destroy(t, &f)
	if !watch_prepare(t, &f) {return}
	watch_mkdir(t, &f, "sub")
	if !watch_begin(t, &f, false) {return}

	watch_write(t, &f, "sub/inner.txt", "x")
	watch_write(t, &f, "top.txt", "x")
	watch_write(t, &f, "zz-last.txt", "x")

	watch_collect(t, &f, "top.txt", "zz-last.txt")
	testing.expect(t, !watch_seen(&f, "sub/inner.txt"), "a nested file is not reported")
	testing.expect(t, !watch_seen(&f, "inner.txt"), "a nested file is not reported by its name")
}

@(test)
watch_take_appends_empties_and_wakes :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	f: Watched
	defer watch_destroy(t, &f)
	if !watch_prepare(t, &f) {return}
	if !watch_begin(t, &f, true) {return}

	before := sync.atomic_load(&f.counter.count)
	watch_write(t, &f, "wake.txt", "x")
	watch_await_wake(t, &f, before)
	watch_quiet(&f)

	taken := make([dynamic]string, context.temp_allocator)
	append(&taken, "kept")
	testing.expect(t, !turns.watch_take(f.watch, &taken, context.temp_allocator), "no overflow")
	if testing.expect(t, len(taken) >= 2, "the take adds to what the caller holds") {
		testing.expect_value(t, taken[0], "kept")
		reported := false
		for path in taken[1:] {
			reported ||= path == "wake.txt"
		}
		testing.expect(t, reported, "the take holds the changed path")
	}
	again := make([dynamic]string, context.temp_allocator)
	testing.expect(t, !turns.watch_take(f.watch, &again, context.temp_allocator), "no overflow")
	testing.expect_value(t, len(again), 0)

	turns.watch_stop(f.watch)
	f.watch = nil
	after := sync.atomic_load(&f.counter.count)
	watch_write(t, &f, "later.txt", "x")
	time.sleep(200 * time.Millisecond)
	testing.expect_value(t, sync.atomic_load(&f.counter.count), after)
}

@(test)
watch_stop_is_prompt_and_nil_safe :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	turns.watch_stop(nil)
	f: Watched
	defer watch_destroy(t, &f)
	if !watch_prepare(t, &f) {return}

	for _ in 0 ..< 20 {
		watch, started := turns.watch_start(f.directory, true, {})
		if !testing.expect(t, started, "the watch starts") {return}
		turns.watch_stop(watch)
	}

	if !watch_begin(t, &f, true) {return}
	before := sync.atomic_load(&f.counter.count)
	watch_write(t, &f, "pending.txt", "x")
	watch_await_wake(t, &f, before)
	began := time.tick_now()
	turns.watch_stop(f.watch)
	f.watch = nil
	testing.expect(t, time.tick_since(began) < time.Second, "the watch stops promptly")
}

@(test)
watch_start_fails_without_a_directory :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	f: Watched
	defer watch_destroy(t, &f)
	if !watch_prepare(t, &f) {return}
	watch_write(t, &f, "file.txt", "x")

	watch, started := turns.watch_start(watch_path(&f, "missing"), true, {})
	testing.expect(t, !started, "a missing directory cannot be watched")
	testing.expect(t, watch == nil, "no watch comes back")
	watch, started = turns.watch_start(watch_path(&f, "file.txt"), true, {})
	testing.expect(t, !started, "a file cannot be watched")
	testing.expect(t, watch == nil, "no watch comes back")
}
