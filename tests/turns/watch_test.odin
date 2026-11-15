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

// A temp directory, a set watching it, and every path the watch has reported so far.
@(private = "file")
Watched :: struct {
	directory: string,
	counter:   Watch_Count,
	set:       ^turns.Watch_Set,
	id:        turns.Watch_Id,
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
	created, added: bool
	f.set, created = turns.watch_set_create(wake)
	if !testing.expect(t, created, "the set starts") {return false}
	f.id, added = turns.watch_set_add(f.set, f.directory, recursive)
	return testing.expect(t, added && f.id != 0, "the directory is added")
}

@(private = "file")
watch_destroy :: proc(t: ^testing.T, f: ^Watched) {
	turns.watch_set_destroy(f.set)
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
		overflowed, dead := turns.watch_set_take(f.set, f.id, &batch)
		testing.expect(t, !overflowed, "the buffer does not overflow")
		testing.expect(t, !dead, "the watch stays alive")
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
watch_await_wake :: proc(t: ^testing.T, counter: ^Watch_Count, before: i32) {
	began := time.tick_now()
	for sync.atomic_load(&counter.count) == before && time.tick_since(began) < WATCH_PATIENCE {
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, sync.atomic_load(&counter.count) != before, "the watch wakes its owner")
}

// Returns once no wake has come for a while, so every change made so far has been reported.
@(private = "file")
watch_quiet :: proc(counter: ^Watch_Count) {
	last := sync.atomic_load(&counter.count)
	for quiet_since := time.tick_now(); time.tick_since(quiet_since) < 150 * time.Millisecond; {
		time.sleep(10 * time.Millisecond)
		now := sync.atomic_load(&counter.count)
		if now != last {
			last = now
			quiet_since = time.tick_now()
		}
	}
}

// A set watching several directories under one temp directory. Everything is parallel by the index
// `fleet_add` returned: the directory, its watch, the paths it reported and whether it was reported dead.
@(private = "file")
Fleet :: struct {
	root:    string,
	counter: Watch_Count,
	set:     ^turns.Watch_Set,
	dirs:    [dynamic]string,
	ids:     [dynamic]turns.Watch_Id,
	seen:    [dynamic][dynamic]string,
	dead:    [dynamic]bool,
}

// A path a watch of the fleet is expected to report.
@(private = "file")
Fleet_Want :: struct {
	index: int,
	path:  string,
}

@(private = "file")
fleet_prepare :: proc(t: ^testing.T, f: ^Fleet) -> bool {
	root, root_error := os.make_directory_temp("", "aio-fleet-*", context.allocator)
	if !testing.expect_value(t, root_error, nil) {return false}
	f.root = root
	wake := turns.Watch_Wake {
		data = &f.counter,
		wake = watch_counted,
	}
	created: bool
	f.set, created = turns.watch_set_create(wake)
	return testing.expect(t, created, "the set starts")
}

// Watches `directory`; returns its index, or -1.
@(private = "file")
fleet_add :: proc(t: ^testing.T, f: ^Fleet, directory: string, recursive := true) -> int {
	id, added := turns.watch_set_add(f.set, directory, recursive)
	if !testing.expectf(t, added && id != 0, "%q is added", directory) {return -1}
	append(&f.dirs, strings.clone(directory))
	append(&f.ids, id)
	append(&f.seen, make([dynamic]string))
	append(&f.dead, false)
	return len(f.ids) - 1
}

// Creates and watches `count` directories, d-00 and on.
@(private = "file")
fleet_subdirs :: proc(t: ^testing.T, f: ^Fleet, count: int) -> bool {
	for index in 0 ..< count {
		directory := fmt.tprintf("%s/d-%02d", f.root, index)
		if !testing.expect_value(t, os.make_directory(directory), nil) {return false}
		if fleet_add(t, f, directory) != index {return false}
	}
	return true
}

@(private = "file")
fleet_destroy :: proc(t: ^testing.T, f: ^Fleet) {
	turns.watch_set_destroy(f.set)
	for directory in f.dirs {delete(directory)}
	for &paths in f.seen {
		for path in paths {delete(path)}
		delete(paths)
	}
	delete(f.dirs)
	delete(f.ids)
	delete(f.seen)
	delete(f.dead)
	if f.root != "" {
		testing.expect_value(t, os.remove_all(f.root), nil)
		delete(f.root)
	}
}

@(private = "file")
fleet_index :: proc(f: ^Fleet, id: turns.Watch_Id) -> int {
	for candidate, index in f.ids {
		if candidate == id {return index}
	}
	return -1
}

@(private = "file")
fleet_path :: proc(f: ^Fleet, index: int, name: string) -> string {
	return strings.concatenate({f.dirs[index], "/", name}, context.temp_allocator)
}

@(private = "file")
fleet_write :: proc(t: ^testing.T, f: ^Fleet, index: int, name: string) {
	testing.expect_value(t, os.write_entire_file(fleet_path(f, index, name), "x"), nil)
}

@(private = "file")
fleet_seen :: proc(f: ^Fleet, index: int, path: string) -> bool {
	for seen in f.seen[index] {
		if seen == path {return true}
	}
	return false
}

// Takes from every watch the set lists as ready, and checks each take: no overflow while alive.
@(private = "file")
fleet_drain :: proc(t: ^testing.T, f: ^Fleet) {
	ready := make([dynamic]turns.Watch_Id, context.temp_allocator)
	turns.watch_set_ready(f.set, &ready)
	for id in ready {
		index := fleet_index(f, id)
		if !testing.expectf(t, index >= 0, "ready lists only watches that were added, not %d", id) {
			continue
		}
		batch := make([dynamic]string, context.temp_allocator)
		overflowed, dead := turns.watch_set_take(f.set, id, &batch)
		if dead {
			f.dead[index] = true
		} else {
			testing.expect(t, !overflowed, "the buffer does not overflow")
		}
		for path in batch {append(&f.seen[index], path)}
	}
}

// Drains until every wanted path has been reported or the patience runs out.
@(private = "file")
fleet_collect :: proc(t: ^testing.T, f: ^Fleet, wanted: ..Fleet_Want) -> bool {
	began := time.tick_now()
	for {
		fleet_drain(t, f)
		found := true
		for want in wanted {
			found &&= fleet_seen(f, want.index, want.path)
		}
		if found {return true}
		if time.tick_since(began) > WATCH_PATIENCE {break}
		time.sleep(5 * time.Millisecond)
	}
	for want in wanted {
		found := fleet_seen(f, want.index, want.path)
		testing.expectf(t, found, "%q is reported by watch %d", want.path, want.index)
	}
	return false
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
	watch_await_wake(t, &f.counter, 0)
	watch_quiet(&f.counter)

	batch := make([dynamic]string, context.temp_allocator)
	overflowed, dead := turns.watch_set_take(f.set, f.id, &batch, context.temp_allocator)
	testing.expect(t, !overflowed, "no overflow")
	testing.expect(t, !dead, "not dead")
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
	watch_await_wake(t, &f.counter, before)
	watch_quiet(&f.counter)

	taken := make([dynamic]string, context.temp_allocator)
	append(&taken, "kept")
	overflowed, dead := turns.watch_set_take(f.set, f.id, &taken, context.temp_allocator)
	testing.expect(t, !overflowed && !dead, "no overflow, not dead")
	if testing.expect(t, len(taken) >= 2, "the take adds to what the caller holds") {
		testing.expect_value(t, taken[0], "kept")
		reported := false
		for path in taken[1:] {
			reported ||= path == "wake.txt"
		}
		testing.expect(t, reported, "the take holds the changed path")
	}
	again := make([dynamic]string, context.temp_allocator)
	overflowed, dead = turns.watch_set_take(f.set, f.id, &again, context.temp_allocator)
	testing.expect(t, !overflowed && !dead, "no overflow, not dead")
	testing.expect_value(t, len(again), 0)

	turns.watch_set_destroy(f.set)
	f.set = nil
	after := sync.atomic_load(&f.counter.count)
	watch_write(t, &f, "later.txt", "x")
	time.sleep(200 * time.Millisecond)
	testing.expect_value(t, sync.atomic_load(&f.counter.count), after)
}

@(test)
watch_set_destroy_is_prompt_and_nil_safe :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	turns.watch_set_destroy(nil)
	f: Watched
	defer watch_destroy(t, &f)
	if !watch_prepare(t, &f) {return}

	for _ in 0 ..< 20 {
		set, created := turns.watch_set_create({})
		if !testing.expect(t, created, "the set starts") {return}
		id, added := turns.watch_set_add(set, f.directory, true)
		testing.expect(t, added && id != 0, "the directory is added")
		turns.watch_set_destroy(set)
	}

	if !watch_begin(t, &f, true) {return}
	before := sync.atomic_load(&f.counter.count)
	watch_write(t, &f, "pending.txt", "x")
	watch_await_wake(t, &f.counter, before)
	began := time.tick_now()
	turns.watch_set_destroy(f.set)
	f.set = nil
	testing.expect(t, time.tick_since(began) < time.Second, "the set stops promptly")
}

@(test)
watch_set_add_fails_without_a_directory :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	f: Watched
	defer watch_destroy(t, &f)
	if !watch_prepare(t, &f) {return}
	watch_write(t, &f, "file.txt", "x")
	set, created := turns.watch_set_create({})
	if !testing.expect(t, created, "the set starts") {return}
	defer turns.watch_set_destroy(set)

	id, added := turns.watch_set_add(set, watch_path(&f, "missing"), true)
	testing.expect(t, !added, "a missing directory cannot be watched")
	testing.expect_value(t, id, turns.Watch_Id(0))
	id, added = turns.watch_set_add(set, watch_path(&f, "file.txt"), true)
	testing.expect(t, !added, "a file cannot be watched")
	testing.expect_value(t, id, turns.Watch_Id(0))
	id, added = turns.watch_set_add(nil, f.directory, true)
	testing.expect(t, !added, "a missing set cannot watch")
	testing.expect_value(t, id, turns.Watch_Id(0))

	// A directory that was rejected leaves the set usable.
	id, added = turns.watch_set_add(set, f.directory, true)
	testing.expect(t, added && id != 0, "the set still watches")
	ready := make([dynamic]turns.Watch_Id, context.temp_allocator)
	turns.watch_set_ready(set, &ready)
	testing.expect_value(t, len(ready), 0)
}

@(test)
watch_set_names_no_watch_by_zero_or_a_stale_id :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	f: Fleet
	defer fleet_destroy(t, &f)
	if !fleet_prepare(t, &f) || !fleet_subdirs(t, &f, 1) {return}
	id := f.ids[0]
	turns.watch_set_remove(f.set, id)

	paths := make([dynamic]string, context.temp_allocator)
	for unknown in ([]turns.Watch_Id{0, id, id + 7}) {
		overflowed, dead := turns.watch_set_take(f.set, unknown, &paths, context.temp_allocator)
		testing.expectf(t, !overflowed && dead, "%d names no watch, so it is dead", unknown)
		// Removing what is not there changes nothing.
		turns.watch_set_remove(f.set, unknown)
	}
	testing.expect_value(t, len(paths), 0)
	_, dead := turns.watch_set_take(nil, id, &paths, context.temp_allocator)
	testing.expect(t, dead, "no set, no watch")
	turns.watch_set_ready(nil, nil)
}

@(test)
watch_set_reports_fifty_directories_on_one_set :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	f: Fleet
	defer fleet_destroy(t, &f)
	COUNT :: 50
	if !fleet_prepare(t, &f) || !fleet_subdirs(t, &f, COUNT) {return}

	wanted := make([dynamic]Fleet_Want, context.temp_allocator)
	for index in 0 ..< COUNT {
		own := fmt.tprintf("only-%02d.txt", index)
		fleet_write(t, &f, index, "shared-name.txt")
		fleet_write(t, &f, index, own)
		append(&wanted, Fleet_Want{index, "shared-name.txt"}, Fleet_Want{index, own})
	}
	fleet_collect(t, &f, ..wanted[:])

	for index in 0 ..< COUNT {
		testing.expectf(t, !f.dead[index], "watch %d is alive", index)
		own := fmt.tprintf("only-%02d.txt", index)
		for path in f.seen[index] {
			testing.expectf(
				t,
				path == "shared-name.txt" || path == own,
				"watch %d reports only its own directory's paths, not %q",
				index,
				path,
			)
		}
	}
}

@(test)
watch_set_reports_paths_relative_to_each_directory :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	f: Fleet
	defer fleet_destroy(t, &f)
	if !fleet_prepare(t, &f) {return}
	inner := fmt.tprintf("%s/inner", f.root)
	if !testing.expect_value(t, os.make_directory(inner), nil) {return}
	outer_index := fleet_add(t, &f, f.root)
	inner_index := fleet_add(t, &f, inner)
	if outer_index < 0 || inner_index < 0 {return}

	fleet_write(t, &f, inner_index, "deep.txt")
	// A directory nested in another watched directory is reported by both.
	fleet_collect(t, &f, Fleet_Want{outer_index, "inner/deep.txt"}, Fleet_Want{inner_index, "deep.txt"})
	testing.expect(t, !fleet_seen(&f, inner_index, "inner/deep.txt"), "the inner watch is relative to itself")
	testing.expect(t, !fleet_seen(&f, outer_index, "deep.txt"), "the outer watch is relative to itself")
}

@(test)
watch_set_remove_leaves_the_others_reporting :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	f: Fleet
	defer fleet_destroy(t, &f)
	if !fleet_prepare(t, &f) || !fleet_subdirs(t, &f, 3) {return}

	// Paths wait in the middle watch when it goes; they go with it.
	before := sync.atomic_load(&f.counter.count)
	fleet_write(t, &f, 1, "pending.txt")
	watch_await_wake(t, &f.counter, before)
	began := time.tick_now()
	turns.watch_set_remove(f.set, f.ids[1])
	testing.expect(t, time.tick_since(began) < time.Second, "a watch is removed promptly")
	paths := make([dynamic]string, context.temp_allocator)
	overflowed, dead := turns.watch_set_take(f.set, f.ids[1], &paths, context.temp_allocator)
	testing.expect(t, !overflowed && dead, "a removed watch is gone")
	testing.expect_value(t, len(paths), 0)

	fleet_write(t, &f, 0, "after.txt")
	fleet_write(t, &f, 1, "after.txt")
	fleet_write(t, &f, 2, "after.txt")
	fleet_collect(t, &f, Fleet_Want{0, "after.txt"}, Fleet_Want{2, "after.txt"})
	watch_quiet(&f.counter)
	fleet_drain(t, &f)
	testing.expect_value(t, len(f.seen[1]), 0)
	testing.expect(t, !f.dead[0] && !f.dead[2], "the others stay alive")

	// Nothing wakes the owner for a removed directory.
	after := sync.atomic_load(&f.counter.count)
	fleet_write(t, &f, 1, "later.txt")
	time.sleep(200 * time.Millisecond)
	testing.expect_value(t, sync.atomic_load(&f.counter.count), after)
	ready := make([dynamic]turns.Watch_Id, context.temp_allocator)
	turns.watch_set_ready(f.set, &ready)
	testing.expect_value(t, len(ready), 0)

	// The set takes the directory again under a new id.
	again, added := turns.watch_set_add(f.set, f.dirs[1], true)
	testing.expect(t, added && again != 0 && again != f.ids[1], "the removed directory can be watched again")
	fleet_write(t, &f, 1, "again.txt")
	f.ids[1] = again
	fleet_collect(t, &f, Fleet_Want{1, "again.txt"})
}

@(test)
watch_set_reports_a_deleted_directory_dead :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	f: Fleet
	defer fleet_destroy(t, &f)
	if !fleet_prepare(t, &f) || !fleet_subdirs(t, &f, 3) {return}
	fleet_write(t, &f, 1, "inside.txt")
	fleet_collect(t, &f, Fleet_Want{1, "inside.txt"})

	testing.expect_value(t, os.remove_all(f.dirs[1]), nil)
	began := time.tick_now()
	for !f.dead[1] && time.tick_since(began) < WATCH_PATIENCE {
		fleet_drain(t, &f)
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, f.dead[1], "a deleted directory is reported dead")
	testing.expect(t, !f.dead[0] && !f.dead[2], "the others are not")

	// Death is reported once through ready, and stays dead for a take.
	ready := make([dynamic]turns.Watch_Id, context.temp_allocator)
	turns.watch_set_ready(f.set, &ready)
	for id in ready {
		testing.expect(t, id != f.ids[1], "a dead watch is listed as ready once")
	}
	paths := make([dynamic]string, context.temp_allocator)
	overflowed, dead := turns.watch_set_take(f.set, f.ids[1], &paths, context.temp_allocator)
	testing.expect(t, dead, "the watch stays dead")
	testing.expect(t, !overflowed, "the overflow of its death was reported once")

	// The owner removes it; the rest of the set carries on.
	turns.watch_set_remove(f.set, f.ids[1])
	_, again := turns.watch_set_add(f.set, f.dirs[1], true)
	testing.expect(t, !again, "the deleted directory cannot be watched")
	fleet_write(t, &f, 0, "alive.txt")
	fleet_write(t, &f, 2, "alive.txt")
	fleet_collect(t, &f, Fleet_Want{0, "alive.txt"}, Fleet_Want{2, "alive.txt"})
	testing.expect(t, !f.dead[0] && !f.dead[2], "the others are still alive")
}

@(test)
watch_set_ready_lists_the_watches_with_news_in_order :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	f: Fleet
	defer fleet_destroy(t, &f)
	if !fleet_prepare(t, &f) || !fleet_subdirs(t, &f, 3) {return}
	ready := make([dynamic]turns.Watch_Id, context.temp_allocator)
	turns.watch_set_ready(f.set, &ready)
	testing.expect_value(t, len(ready), 0)

	fleet_write(t, &f, 2, "two.txt")
	fleet_write(t, &f, 0, "zero.txt")
	began := time.tick_now()
	for len(ready) < 2 && time.tick_since(began) < WATCH_PATIENCE {
		time.sleep(5 * time.Millisecond)
		clear(&ready)
		turns.watch_set_ready(f.set, &ready)
	}
	watch_quiet(&f.counter)
	clear(&ready)
	turns.watch_set_ready(f.set, &ready)
	if testing.expect_value(t, len(ready), 2) {
		testing.expect_value(t, ready[0], f.ids[0])
		testing.expect_value(t, ready[1], f.ids[2])
	}

	// Ready lists what has not been taken; taking one watch drops only that one.
	paths := make([dynamic]string, context.temp_allocator)
	overflowed, dead := turns.watch_set_take(f.set, f.ids[2], &paths, context.temp_allocator)
	testing.expect(t, !overflowed && !dead, "no overflow, not dead")
	testing.expect_value(t, len(paths), 1)
	clear(&ready)
	turns.watch_set_ready(f.set, &ready)
	if testing.expect_value(t, len(ready), 1) {testing.expect_value(t, ready[0], f.ids[0])}
	overflowed, dead = turns.watch_set_take(f.set, f.ids[0], &paths, context.temp_allocator)
	testing.expect(t, !overflowed && !dead, "no overflow, not dead")
	clear(&ready)
	turns.watch_set_ready(f.set, &ready)
	testing.expect_value(t, len(ready), 0)
}

@(test)
watch_set_destroy_cancels_every_read_promptly :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	f: Fleet
	defer fleet_destroy(t, &f)
	if !fleet_prepare(t, &f) || !fleet_subdirs(t, &f, 20) {return}
	for index in 0 ..< 20 {fleet_write(t, &f, index, "pending.txt")}
	// Half of them are removed first, so destroy meets watches in every state.
	for index := 0; index < 20; index += 2 {turns.watch_set_remove(f.set, f.ids[index])}

	began := time.tick_now()
	turns.watch_set_destroy(f.set)
	f.set = nil
	testing.expect(t, time.tick_since(began) < time.Second, "the set stops promptly")
}

// A take right after a sync holds every change made before it, with no waiting in between: once
// for each of many single writes, a write made while the thread is busy with an earlier one, and a
// burst.
@(test)
watch_set_sync_makes_every_earlier_change_takeable :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	f: Watched
	defer watch_destroy(t, &f)
	if !watch_prepare(t, &f) {return}
	if !watch_begin(t, &f, true) {return}
	testing.expect(t, !turns.watch_set_sync(nil, time.Second), "a missing set cannot be synced")

	batch := make([dynamic]string, context.temp_allocator)
	for index in 0 ..< 50 {
		name := fmt.tprintf("single-%02d.txt", index)
		watch_write(t, &f, name, "x")
		if index % 2 == 1 {watch_write(t, &f, "again.txt", name)}
		if !testing.expect(t, turns.watch_set_sync(f.set, time.Second), "the sync completes") {return}
		clear(&batch)
		_, _ = turns.watch_set_take(f.set, f.id, &batch, context.temp_allocator)
		found, again := false, false
		for path in batch {
			found ||= path == name
			again ||= path == "again.txt"
		}
		testing.expectf(t, found, "%s is takeable once synced: %v", name, batch)
		if index % 2 == 1 {testing.expectf(t, again, "again.txt is takeable once synced: %v", batch)}
	}

	names := make([dynamic]string, context.temp_allocator)
	for index in 0 ..< 100 {
		name := fmt.tprintf("burst-%03d.txt", index)
		append(&names, name)
		watch_write(t, &f, name, "x")
	}
	if !testing.expect(t, turns.watch_set_sync(f.set, time.Second), "the sync completes") {return}
	clear(&batch)
	overflowed, _ := turns.watch_set_take(f.set, f.id, &batch, context.temp_allocator)
	if overflowed {return}
	for name in names {
		found := false
		for path in batch {found ||= path == name}
		testing.expectf(t, found, "%s is takeable once synced", name)
	}
}
