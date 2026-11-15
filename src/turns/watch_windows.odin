package turns

import "core:log"
import "core:mem"
import w "core:sys/windows"
import "core:sync"
import "core:thread"
import "core:time"
import "core:unicode/utf16"

// The kernel fills one buffer per read. A burst that outruns it is discarded whole and the read
// completes with no bytes, which is how an overflow shows.
@(private)
WATCH_BUFFER_SIZE :: 32 * 1024

// The longest name one read can carry is half the buffer in UTF-16 units, each at most three bytes
// of UTF-8.
@(private)
WATCH_NAME_SIZE :: WATCH_BUFFER_SIZE / size_of(u16) * 3

// NextEntryOffset, Action and FileNameLength come before the name in a FILE_NOTIFY_INFORMATION.
@(private)
WATCH_RECORD_HEADER :: 3 * size_of(u32)

// How many finished reads the thread takes from the queue at once.
@(private)
WATCH_BATCH :: 32

@(private)
WATCH_FILTER :: w.FILE_NOTIFY_CHANGE_FILE_NAME | w.FILE_NOTIFY_CHANGE_DIR_NAME |
	w.FILE_NOTIFY_CHANGE_LAST_WRITE | w.FILE_NOTIFY_CHANGE_SIZE | w.FILE_NOTIFY_CHANGE_CREATION

// Not in core:sys/windows: the change list of a network directory was too large to return.
@(private)
ERROR_NOTIFY_ENUM_DIR :: 1022

// Each directory is read with ReadDirectoryChangesW, overlapped, and its handle is attached to the
// set's completion port, so one thread waits for the changes of every directory and for the stop
// request together. Only that thread, and add, remove and destroy under the set's mutex, touch it.
@(private)
Watch_Native :: struct {
	directory: w.HANDLE,
	// The read in flight. Its completion names the watch through the key the handle was attached with.
	changed:   w.OVERLAPPED,
	// DWORD aligned, as the kernel requires.
	reading:   [WATCH_BUFFER_SIZE / size_of(u32)]u32,
}

@(private)
Watch_Set_Native :: struct {
	// Every finished read of every directory, and the stop request, arrive here.
	port:   w.HANDLE,
	worker: ^thread.Thread,
	// The path being decoded; only the worker's thread uses it.
	name:   [WATCH_NAME_SIZE]u8,
}

// What a finished read held.
@(private)
Watch_Read :: enum u8 {
	Changes,
	Overflow,
	Failed,
}

// A marker sent through the completion port. The waiter and the set's thread each hold it, and
// whichever lets go last frees it, so a waiter that timed out leaves nothing for the thread to write
// into.
@(private)
Watch_Marker :: struct {
	// The port wants an OVERLAPPED; this one is only an address the thread recognises.
	entry:   w.OVERLAPPED,
	handled: sync.Sema,
	holders: i32,
}

// Starts the thread that collects the changes of every directory added to the set. The wake runs
// on that thread once paths have arrived, changes were lost or a watch died. Returns false, logging
// why, when the thread cannot start. The allocator must tolerate use from that thread.
@(require_results)
watch_set_create :: proc(wake: Watch_Wake, allocator := context.allocator) -> (^Watch_Set, bool) {
	set, allocation_error := new(Watch_Set, allocator)
	if allocation_error != nil {
		log.error("allocating a directory watch set failed")
		return nil, false
	}
	set.allocator = allocator
	set.wake = wake
	set.watches = make([dynamic]^Watch_Directory, allocator)
	// One thread takes the completions, so the port needs no more concurrency than that.
	set.native.port = w.CreateIoCompletionPort(w.INVALID_HANDLE_VALUE, nil, 0, 1)
	if set.native.port == nil {
		log.errorf("CreateIoCompletionPort failed: %d", w.GetLastError())
		watch_set_destroy(set)
		return nil, false
	}
	set.native.worker = thread.create(watch_set_main)
	if set.native.worker == nil {
		log.error("starting the directory watch thread failed")
		watch_set_destroy(set)
		return nil, false
	}
	set.native.worker.data = set
	set.native.worker.init_context = context
	thread.start(set.native.worker)
	return set, true
}

// Cancels every read, waits for the kernel to let go of the buffers, joins the thread and frees
// everything, including paths nobody took. Accepts nil and a set that only partly started. Must
// not run on the set's thread, so never from the wake, nor while another thread uses the set.
watch_set_destroy :: proc(set: ^Watch_Set) {
	if set == nil {return}
	native := &set.native
	if native.worker != nil {
		sync.mutex_lock(&set.mutex)
		set.closing = true
		for watch in set.watches {
			watch.closing = true
			if watch.busy {watch_cancel(watch)}
		}
		sync.mutex_unlock(&set.mutex)
		// The thread leaves once the cancelled reads have finished; this wakes it when there were none.
		if !bool(w.PostQueuedCompletionStatus(native.port, 0, 0, nil)) {
			log.errorf("PostQueuedCompletionStatus failed: %d", w.GetLastError())
		}
		thread.join(native.worker)
		thread.destroy(native.worker)
		// A marker whose waiter gave up may still be queued, and only the thread's hold on it is left.
		queued: [WATCH_BATCH]w.OVERLAPPED_ENTRY
		removed: w.c_ulong
		for bool(w.GetQueuedCompletionStatusEx(native.port, &queued[0], WATCH_BATCH, &removed, 0, false)) {
			for entry in queued[:removed] {
				if entry.lpOverlapped != nil && entry.lpCompletionKey == 0 {
					watch_marker_release(set, (^Watch_Marker)(entry.lpOverlapped))
				}
			}
		}
	}
	for watch in set.watches {
		// Only a set whose thread failed has a read left, which the OS may still write into.
		if watch.busy {continue}
		watch_discard(set, watch)
	}
	delete(set.watches)
	watch_close(&native.port)
	allocator := set.allocator
	free(set, allocator)
}

// Starts watching `directory`, and everything below it when `recursive`. Returns false without
// logging for a path that is missing or not a directory, and false, logging why, when the OS
// refuses to watch it.
@(require_results)
watch_set_add :: proc(set: ^Watch_Set, directory: string, recursive: bool) -> (Watch_Id, bool) {
	if set == nil {return 0, false}
	allocator := set.allocator
	path := w.utf8_to_wstring(directory, allocator)
	if path == nil {
		log.errorf("converting the watched directory %q to UTF-16 failed", directory)
		return 0, false
	}
	defer delete(path, allocator)
	if !watch_is_directory(path, directory) {return 0, false}
	watch, allocation_error := new(Watch_Directory, allocator)
	if allocation_error != nil {
		log.errorf("allocating a watch of %q failed", directory)
		return 0, false
	}
	watch.recursive = recursive
	watch.pending = make(map[string]struct{}, allocator)
	if !watch_open(set, watch, path, directory) {
		watch_discard(set, watch)
		return 0, false
	}
	// The first read starts here rather than on the thread, so a directory that cannot be watched
	// fails the add instead of silently never reporting. It starts under the mutex because the thread
	// may see its completion at once and must find the watch ready.
	sync.mutex_lock(&set.mutex)
	id := set.next_id + 1
	watch.id = id
	_, append_error := append(&set.watches, watch)
	armed := append_error == nil && watch_arm(watch)
	if armed {
		set.next_id = id
		watch.busy = true
	} else if append_error == nil {
		pop(&set.watches)
	}
	sync.mutex_unlock(&set.mutex)
	if append_error != nil {log.errorf("listing a watch of %q failed", directory)}
	if !armed {
		watch_discard(set, watch)
		return 0, false
	}
	return id, true
}

// Cancels the read of watch `id`, waits until the kernel is done with its buffer, and drops its
// pending paths and its handle. An id that names no watch is ignored. Must not run on the set's
// thread, so never from the wake.
watch_set_remove :: proc(set: ^Watch_Set, id: Watch_Id) {
	if set == nil {return}
	sync.mutex_lock(&set.mutex)
	defer sync.mutex_unlock(&set.mutex)
	watch := watch_find(set, id)
	if watch == nil {return}
	watch.closing = true
	if watch.busy {watch_cancel(watch)}
	for watch.busy && !set.failed {sync.cond_wait(&set.idle, &set.mutex)}
	// A failed set never sees its reads finish, and the OS may still write into the buffer: the
	// watch stays listed, unfreed, and dies with the set.
	if watch.busy {return}
	for listed, index in set.watches {
		if listed == watch {
			ordered_remove(&set.watches, index)
			break
		}
	}
	watch_discard(set, watch)
}

// Returns once the set's thread has taken in every directory change the OS reported before the call,
// so a take that follows sees them: completions leave the port in the order they arrived. A change
// the OS kept while no read was in flight completes only when the thread starts the next read, behind
// the first marker, so a second marker follows it. False, after logging, when the thread did not get
// there within `timeout` or cannot any more; the caller goes on with what has arrived.
@(require_results)
watch_set_sync :: proc(set: ^Watch_Set, timeout: time.Duration) -> bool {
	if set == nil {return false}
	started := time.tick_now()
	for _ in 0 ..< 2 {
		left := timeout - time.tick_since(started)
		if left <= 0 || !watch_set_marker(set, left) {
			log.warn("the directory watch thread did not catch up")
			return false
		}
	}
	return true
}

@(private, require_results)
watch_set_marker :: proc(set: ^Watch_Set, timeout: time.Duration) -> bool {
	sync.mutex_lock(&set.mutex)
	gone := set.failed || set.closing
	sync.mutex_unlock(&set.mutex)
	if gone {return false}
	marker, allocation_error := new(Watch_Marker, set.allocator)
	if allocation_error != nil {return false}
	marker.holders = 2
	if !bool(w.PostQueuedCompletionStatus(set.native.port, 0, 0, &marker.entry)) {
		log.errorf("PostQueuedCompletionStatus failed: %d", w.GetLastError())
		free(marker, set.allocator)
		return false
	}
	handled := sync.sema_wait_with_timeout(&marker.handled, timeout)
	watch_marker_release(set, marker)
	return handled
}

@(private)
watch_marker_release :: proc(set: ^Watch_Set, marker: ^Watch_Marker) {
	if sync.atomic_sub(&marker.holders, 1) == 1 {free(marker, set.allocator)}
}

// Closes the directory and frees the watch with what it holds. Nothing may be reading into it.
@(private)
watch_discard :: proc(set: ^Watch_Set, watch: ^Watch_Directory) {
	watch_close(&watch.native.directory)
	watch_release(set, watch)
	free(watch, set.allocator)
}

@(private)
watch_close :: proc(handle: ^w.HANDLE) {
	if handle^ == nil {return}
	_ = w.CloseHandle(handle^)
	handle^ = nil
}

// What the OS answers for a directory that was deleted or moved away from under a read. Expected
// whenever a work tree goes, so not worth logging.
@(private)
watch_vanished :: proc(error: w.DWORD) -> bool {
	switch error {
	case w.ERROR_ACCESS_DENIED, w.ERROR_FILE_NOT_FOUND, w.ERROR_PATH_NOT_FOUND, w.ERROR_INVALID_HANDLE:
		return true
	}
	return false
}

// A path that is missing or not a directory is a caller's condition, not a Win32 fault, so it fails
// quietly. Any other reason the attributes cannot be read is logged.
@(private, require_results)
watch_is_directory :: proc(path: w.LPCWSTR, directory: string) -> bool {
	attributes := w.GetFileAttributesW(path)
	if attributes == w.INVALID_FILE_ATTRIBUTES {
		error := w.GetLastError()
		switch error {
		case w.ERROR_FILE_NOT_FOUND, w.ERROR_PATH_NOT_FOUND, w.ERROR_INVALID_NAME:
		case:
			log.errorf("reading the attributes of %q failed: %d", directory, error)
		}
		return false
	}
	return attributes & w.FILE_ATTRIBUTE_DIRECTORY != 0
}

// Opens the directory and attaches it to the set's port, keyed by the watch, which is how the
// thread finds the watch again. The watch outlives every completion queued for it.
@(private, require_results)
watch_open :: proc(set: ^Watch_Set, watch: ^Watch_Directory, path: w.LPCWSTR, directory: string) -> bool {
	native := &watch.native
	native.directory = w.CreateFileW(
		path,
		w.FILE_LIST_DIRECTORY,
		w.FILE_SHARE_READ | w.FILE_SHARE_WRITE | w.FILE_SHARE_DELETE,
		nil,
		w.OPEN_EXISTING,
		w.FILE_FLAG_BACKUP_SEMANTICS | w.FILE_FLAG_OVERLAPPED,
		nil,
	)
	if native.directory == w.INVALID_HANDLE_VALUE {
		native.directory = nil
		log.errorf("opening %q to watch it failed: %d", directory, w.GetLastError())
		return false
	}
	if w.CreateIoCompletionPort(native.directory, set.native.port, w.ULONG_PTR(uintptr(watch)), 0) == nil {
		log.errorf("attaching %q to the completion port failed: %d", directory, w.GetLastError())
		watch_close(&native.directory)
		return false
	}
	return true
}

// Starts the next read. Changes made while no read is in flight queue in the kernel, up to the
// buffer's size, and the next read returns them. The set's mutex is held, or the watch is not
// listed yet.
@(private, require_results)
watch_arm :: proc(watch: ^Watch_Directory) -> bool {
	native := &watch.native
	native.changed = {}
	armed := w.ReadDirectoryChangesW(
		native.directory,
		&native.reading[0],
		WATCH_BUFFER_SIZE,
		w.BOOL(watch.recursive),
		WATCH_FILTER,
		nil,
		&native.changed,
		nil,
	)
	if !bool(armed) {
		error := w.GetLastError()
		if !watch_vanished(error) {log.errorf("ReadDirectoryChangesW failed: %d", error)}
		return false
	}
	return true
}

// Asks the kernel to cancel the read in flight. The cancelled read still completes, and the thread
// sees that as it sees any other. The set's mutex is held.
@(private)
watch_cancel :: proc(watch: ^Watch_Directory) {
	native := &watch.native
	if bool(w.CancelIoEx(native.directory, &native.changed)) {return}
	error := w.GetLastError()
	// The read finished first and its completion is on its way to the thread.
	if error == w.ERROR_NOT_FOUND {return}
	// Waiting for a read that was not cancelled could block for ever. Closing the handle cancels it
	// instead.
	log.errorf("CancelIoEx failed: %d", error)
	watch_close(&native.directory)
}

@(private)
watch_set_main :: proc(t: ^thread.Thread) {
	set := (^Watch_Set)(t.data)
	entries: [WATCH_BATCH]w.OVERLAPPED_ENTRY
	for {
		removed: w.c_ulong
		waited := w.GetQueuedCompletionStatusEx(
			set.native.port,
			&entries[0],
			WATCH_BATCH,
			&removed,
			w.INFINITE,
			false,
		)
		if !bool(waited) {
			log.errorf("waiting for directory changes failed: %d", w.GetLastError())
			watch_set_fail(set)
			return
		}
		arrived := false
		sync.mutex_lock(&set.mutex)
		for entry in entries[:removed] {
			// The stop request is the only entry that carries no read, and a marker the only one with
			// no watch.
			if entry.lpOverlapped == nil {continue}
			if entry.lpCompletionKey == 0 {
				marker := (^Watch_Marker)(entry.lpOverlapped)
				sync.sema_post(&marker.handled)
				watch_marker_release(set, marker)
				continue
			}
			watch := (^Watch_Directory)(rawptr(uintptr(entry.lpCompletionKey)))
			if watch_complete(set, watch) {arrived = true}
		}
		sync.cond_broadcast(&set.idle)
		finished := set.closing && watch_set_idle(set)
		sync.mutex_unlock(&set.mutex)
		if arrived {watch_notify(set)}
		if finished {return}
	}
}

// Whether no watch has a read in flight. The set's mutex is held.
@(private)
watch_set_idle :: proc(set: ^Watch_Set) -> bool {
	for watch in set.watches {
		if watch.busy {return false}
	}
	return true
}

// The thread cannot wait for completions any more: every watch is lost, and nothing may wait for
// a read that no one will see finish.
@(private)
watch_set_fail :: proc(set: ^Watch_Set) {
	sync.mutex_lock(&set.mutex)
	set.failed = true
	for watch in set.watches {
		watch.overflowed, watch.dead = true, true
	}
	sync.cond_broadcast(&set.idle)
	sync.mutex_unlock(&set.mutex)
	watch_notify(set)
}

// Takes in the finished read of `watch` and starts the next one, unless the watch is closing, in
// which case it stops being busy. Reports whether the owner has anything new. The set's mutex is
// held.
@(private)
watch_complete :: proc(set: ^Watch_Set, watch: ^Watch_Directory) -> (arrived: bool) {
	if watch.closing {
		watch.busy = false
		return false
	}
	bytes, result := watch_finish_read(watch)
	switch result {
	case .Changes:
		arrived = watch_parse(set, watch, bytes)
	case .Overflow:
		watch.overflowed, arrived = true, true
	case .Failed:
		return watch_die(watch)
	}
	if !watch_arm(watch) {return watch_die(watch)}
	return
}

// The watch stops reading for good. Always has something new for the owner.
@(private)
watch_die :: proc(watch: ^Watch_Directory) -> bool {
	watch.overflowed, watch.dead, watch.busy = true, true, false
	return true
}

@(private)
watch_finish_read :: proc(watch: ^Watch_Directory) -> (bytes: int, result: Watch_Read) {
	native := &watch.native
	count: w.DWORD
	if !bool(w.GetOverlappedResult(native.directory, &native.changed, &count, false)) {
		error := w.GetLastError()
		if error == ERROR_NOTIFY_ENUM_DIR {return 0, .Overflow}
		if !watch_vanished(error) {log.errorf("reading directory changes failed: %d", error)}
		return 0, .Failed
	}
	if count == 0 {return 0, .Overflow}
	return int(count), .Changes
}

// Records every path in the first `bytes` of the buffer. Reports whether the owner has anything new.
// The set's mutex is held.
@(private)
watch_parse :: proc(set: ^Watch_Set, watch: ^Watch_Directory, bytes: int) -> (arrived: bool) {
	buffer := mem.slice_to_bytes(watch.native.reading[:])
	offset := 0
	for offset + WATCH_RECORD_HEADER <= bytes {
		record := (^w.FILE_NOTIFY_INFORMATION)(&buffer[offset])
		first := offset + WATCH_RECORD_HEADER
		length := int(record.FileNameLength) / size_of(u16)
		if first + length * size_of(u16) > bytes {break}
		name := mem.slice_data_cast([]u16, buffer[first:first + length * size_of(u16)])
		path := watch_path(set.native.name[:], name)
		if path != "" && !watch_ignored(path) && watch_record(set, watch, path) {arrived = true}
		if record.NextEntryOffset == 0 {break}
		offset += int(record.NextEntryOffset)
	}
	return
}

// The name as UTF-8 with '/' separators, written to the front of `buffer`. A file name cannot hold
// '/', so every backslash is a separator.
@(private)
watch_path :: proc(buffer: []u8, name: []u16) -> string {
	size := utf16.decode_to_utf8(buffer, name)
	for &c in buffer[:size] {
		if c == '\\' {c = '/'}
	}
	return string(buffer[:size])
}
