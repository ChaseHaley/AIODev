package turns

import "core:mem"
import "core:strings"
import "core:sync"

// Past this many distinct paths waiting to be taken, further paths are dropped and the watch reports
// an overflow, so a runaway build cannot grow the set without bound and the owner rescans instead.
WATCH_PENDING_LIMIT :: 100_000

// A take empties the set, but a table that grew for one burst is not worth keeping.
WATCH_RETAINED_PATHS :: 4096

// Runs on the set's own thread after paths arrive, changes were lost or a watch died. It must only
// signal the owner (platform.wake), never call back into this package: watch_set_remove and
// watch_set_destroy wait for that thread.
Watch_Wake :: struct {
	data: rawptr,
	wake: proc "contextless" (data: rawptr),
}

// Names one directory of a Watch_Set; 0 names none. A set never hands an id out twice.
Watch_Id :: distinct u32

// Any number of directories watched on one thread. The thread only collects which paths changed;
// the owner learns which watches have news with watch_set_ready, drains each with watch_set_take
// when it likes and reads the files itself. Both threads allocate from `allocator`, so it must
// tolerate being called from two threads. A watch whose directory goes away stops watching and is
// reported dead; the owner removes it.
Watch_Set :: struct {
	// Guards every field below it up to the fixed ones, and every field of the watches it lists.
	mutex:     sync.Mutex,
	// Signalled whenever a watch stops reading, which is what remove and destroy wait for.
	idle:      sync.Cond,
	// Ascending by id.
	watches:   [dynamic]^Watch_Directory,
	next_id:   Watch_Id,
	// watch_set_destroy began: no read starts any more and the thread leaves once none is in flight.
	closing:   bool,
	// The thread gave up on the OS queue, so the reads in flight will never be seen to finish.
	failed:    bool,
	// Fixed before the thread starts.
	allocator: mem.Allocator,
	wake:      Watch_Wake,
	native:    Watch_Set_Native,
}

// One directory of a set. Every field belongs to the set's mutex.
@(private)
Watch_Directory :: struct {
	id:            Watch_Id,
	recursive:     bool,
	// Every key is a string owned by the set's allocator.
	pending:       map[string]struct{},
	overflowed:    bool,
	// The directory can no longer be watched. Sticky.
	dead:          bool,
	// A take has reported the death, so ready stops listing the watch.
	dead_reported: bool,
	// A read is in flight, or the set's thread is handling its completion: the OS or that thread
	// may still touch `native`.
	busy:          bool,
	// Remove or destroy asked it to stop, so no further read starts.
	closing:       bool,
	native:        Watch_Native,
}

// Appends the ids of the watches that have pending paths, an overflow or a death their owner has not
// taken yet, in ascending order. A dead watch is listed once; the owner is expected to remove it.
watch_set_ready :: proc(set: ^Watch_Set, out: ^[dynamic]Watch_Id) {
	if set == nil {return}
	sync.mutex_lock(&set.mutex)
	defer sync.mutex_unlock(&set.mutex)
	for watch in set.watches {
		news := len(watch.pending) > 0 || watch.overflowed || (watch.dead && !watch.dead_reported)
		// A watch that did not fit stays ready for the next call.
		if news {_, _ = append(out, watch.id)}
	}
}

// Moves the paths that changed in watch `id` since its last take to `out`, relative to the watched
// directory, with '/' separators and each once; a repository's own `.git` at the root is dropped.
// A path may name a directory: the OS reports a directory as changed whenever an entry in it is
// added, removed or renamed. A rename lists both names.
// overflowed = changes were lost since the last take (the OS buffer overflowed, the watch hit its
// limit, or its directory can no longer be watched), so the owner must rescan the directory.
// dead = the watch stopped, because its directory is gone or the OS failed it, and the owner should
// remove it. An id that names no watch, including 0, is dead.
@(require_results)
watch_set_take :: proc(
	set: ^Watch_Set,
	id: Watch_Id,
	out: ^[dynamic]string,
	allocator := context.allocator,
) -> (
	overflowed, dead: bool,
) {
	if set == nil {return false, true}
	sync.mutex_lock(&set.mutex)
	defer sync.mutex_unlock(&set.mutex)
	watch := watch_find(set, id)
	if watch == nil {return false, true}
	overflowed = watch.overflowed
	watch.overflowed = false
	dead = watch.dead
	watch.dead_reported = dead
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
	for path, _ in watch.pending {delete(path, set.allocator)}
	clear(&watch.pending)
	if cap(watch.pending) > WATCH_RETAINED_PATHS {
		delete(watch.pending)
		watch.pending = make(map[string]struct{}, set.allocator)
	}
	return
}

// The watch named `id`, or nil. The set's mutex is held.
@(private)
watch_find :: proc(set: ^Watch_Set, id: Watch_Id) -> ^Watch_Directory {
	if id == 0 {return nil}
	for watch in set.watches {
		if watch.id == id {return watch}
	}
	return nil
}

// Adds a path the owner has not taken yet. Reports whether the owner has something new to take. The
// set's mutex is held.
@(private)
watch_record :: proc(set: ^Watch_Set, watch: ^Watch_Directory, path: string) -> bool {
	if path in watch.pending {return false}
	if len(watch.pending) >= WATCH_PENDING_LIMIT {
		watch.overflowed = true
		return true
	}
	key, clone_error := strings.clone(path, set.allocator)
	if clone_error != nil {
		watch.overflowed = true
		return true
	}
	_, _, inserted, insert_error := map_entry(&watch.pending, key)
	if insert_error != nil || !inserted {delete(key, set.allocator)}
	if insert_error != nil {
		watch.overflowed = true
		return true
	}
	return inserted
}

// Calls the owner's wake, if it gave one. The set's mutex is not held.
@(private)
watch_notify :: proc(set: ^Watch_Set) {
	if set.wake.wake != nil {set.wake.wake(set.wake.data)}
}

// A repository's own bookkeeping, which git rewrites constantly and no one reading changes wants.
@(private)
watch_ignored :: proc(path: string) -> bool {
	return path == ".git" || strings.has_prefix(path, ".git/")
}

// Frees the paths nobody took.
@(private)
watch_release :: proc(set: ^Watch_Set, watch: ^Watch_Directory) {
	for path, _ in watch.pending {delete(path, set.allocator)}
	delete(watch.pending)
}
