package turns

import "core:mem"
import "core:strings"
import "core:sync"

// Past this many distinct paths waiting to be taken, further paths are dropped and the watch reports
// an overflow, so a runaway build cannot grow the set without bound and the owner rescans instead.
WATCH_PENDING_LIMIT :: 100_000

// A take empties the set, but a table that grew for one burst is not worth keeping.
WATCH_RETAINED_PATHS :: 4096

// Runs on the watch's own thread after paths arrive or changes were lost. It must only signal the
// owner (platform.wake), never call back into this package: watch_stop waits for that thread.
Watch_Wake :: struct {
	data: rawptr,
	wake: proc "contextless" (data: rawptr),
}

// One directory watched on a thread of its own. The thread only collects which paths changed; the
// owner drains them with watch_take when it likes and reads the files itself. Both threads allocate
// from `allocator`, so it must tolerate being called from two threads. A watch whose directory goes
// away stops watching and reports an overflow once; the owner finds out by rescanning.
Watch :: struct {
	// Guards pending and overflowed, the only fields the watch's thread shares with its owner.
	mutex:      sync.Mutex,
	// Every key is a string owned by `allocator`.
	pending:    map[string]struct{},
	overflowed: bool,
	// Fixed before the thread starts.
	allocator:  mem.Allocator,
	wake:       Watch_Wake,
	recursive:  bool,
	native:     Watch_Native,
}

// Appends the paths that changed since the last take to `out`, relative to the watched directory,
// with '/' separators and each once. A path may name a directory: the OS reports a directory as
// changed whenever an entry in it is added, removed or renamed. A rename lists both names.
// overflowed = changes were lost since the last take (the OS buffer overflowed, the set hit its
// limit, or the directory can no longer be watched), so the owner must rescan the directory.
@(require_results)
watch_take :: proc(
	watch: ^Watch,
	out: ^[dynamic]string,
	allocator := context.allocator,
) -> (
	overflowed: bool,
) {
	if watch == nil {return false}
	sync.mutex_lock(&watch.mutex)
	defer sync.mutex_unlock(&watch.mutex)
	overflowed = watch.overflowed
	watch.overflowed = false
	_ = reserve(out, len(out) + len(watch.pending))
	for path, _ in watch.pending {
		copied, clone_error := strings.clone(path, allocator)
		if clone_error != nil {
			overflowed = true
			continue
		}
		if _, append_error := append(out, copied); append_error != nil {
			delete(copied, allocator)
			overflowed = true
		}
	}
	for path, _ in watch.pending {delete(path, watch.allocator)}
	clear(&watch.pending)
	if cap(watch.pending) > WATCH_RETAINED_PATHS {
		delete(watch.pending)
		watch.pending = make(map[string]struct{}, watch.allocator)
	}
	return
}

// Adds a path the owner has not taken yet. Reports whether the owner has something new to take.
@(private)
watch_record :: proc(watch: ^Watch, path: string) -> bool {
	sync.mutex_lock(&watch.mutex)
	defer sync.mutex_unlock(&watch.mutex)
	if path in watch.pending {return false}
	if len(watch.pending) >= WATCH_PENDING_LIMIT {
		watch.overflowed = true
		return true
	}
	key, clone_error := strings.clone(path, watch.allocator)
	if clone_error != nil {
		watch.overflowed = true
		return true
	}
	_, _, inserted, insert_error := map_entry(&watch.pending, key)
	if insert_error != nil || !inserted {delete(key, watch.allocator)}
	if insert_error != nil {
		watch.overflowed = true
		return true
	}
	return inserted
}

// Records that changes were lost and wakes the owner to rescan.
@(private)
watch_overflow :: proc(watch: ^Watch) {
	sync.mutex_lock(&watch.mutex)
	watch.overflowed = true
	sync.mutex_unlock(&watch.mutex)
	watch_notify(watch)
}

@(private)
watch_notify :: proc(watch: ^Watch) {
	if watch.wake.wake != nil {watch.wake.wake(watch.wake.data)}
}

// A repository's own bookkeeping, which git rewrites constantly and no one reading changes wants.
@(private)
watch_ignored :: proc(path: string) -> bool {
	return path == ".git" || strings.has_prefix(path, ".git/")
}

@(private)
watch_release :: proc(watch: ^Watch) {
	for path, _ in watch.pending {delete(path, watch.allocator)}
	delete(watch.pending)
}
