package turns

import "core:log"
import "core:mem"
import w "core:sys/windows"
import "core:thread"
import "core:unicode/utf16"

// The kernel fills one buffer per read. A burst that outruns it is discarded whole and the read
// completes with no bytes, which is how an overflow shows.
@(private)
WATCH_BUFFER_SIZE :: 64 * 1024

// The longest name one read can carry is half the buffer in UTF-16 units, each at most three bytes
// of UTF-8.
@(private)
WATCH_NAME_SIZE :: WATCH_BUFFER_SIZE / size_of(u16) * 3

// NextEntryOffset, Action and FileNameLength come before the name in a FILE_NOTIFY_INFORMATION.
@(private)
WATCH_RECORD_HEADER :: 3 * size_of(u32)

@(private)
WATCH_FILTER :: w.FILE_NOTIFY_CHANGE_FILE_NAME | w.FILE_NOTIFY_CHANGE_DIR_NAME |
	w.FILE_NOTIFY_CHANGE_LAST_WRITE | w.FILE_NOTIFY_CHANGE_SIZE | w.FILE_NOTIFY_CHANGE_CREATION

// Not in core:sys/windows: the change list of a network directory was too large to return.
@(private)
ERROR_NOTIFY_ENUM_DIR :: 1022

// The directory is read with ReadDirectoryChangesW, overlapped, so one thread can wait for a change
// and for the stop request together. Once that thread runs it alone touches `changed` and `reading`.
@(private)
Watch_Native :: struct {
	directory: w.HANDLE,
	// The read in flight; its event is signalled when the read completes.
	changed:   w.OVERLAPPED,
	// Manual reset, set by watch_stop.
	stop:      w.HANDLE,
	worker:    ^thread.Thread,
	// DWORD aligned, as the kernel requires.
	reading:   [WATCH_BUFFER_SIZE / size_of(u32)]u32,
	// The path being decoded.
	name:      [WATCH_NAME_SIZE]u8,
}

// What a finished read held.
@(private)
Watch_Read :: enum u8 {
	Changes,
	Overflow,
	Failed,
}

// Starts watching `directory`, and everything below it when `recursive`. The wake runs on the watch's
// own thread once paths have arrived. Returns false, logging why, when the directory cannot be
// watched. The allocator must tolerate use from the watch's thread.
@(require_results)
watch_start :: proc(
	directory: string,
	recursive: bool,
	wake: Watch_Wake,
	allocator := context.allocator,
) -> (
	^Watch,
	bool,
) {
	watch, allocation_error := new(Watch, allocator)
	if allocation_error != nil {
		log.error("allocating a directory watch failed")
		return nil, false
	}
	watch.allocator = allocator
	watch.wake = wake
	watch.recursive = recursive
	watch.pending = make(map[string]struct{}, allocator)
	// The first read is armed here rather than on the thread, so a path that cannot be watched, such
	// as a file, fails the start instead of silently never reporting.
	if !watch_open(watch, directory) || !watch_arm(watch) {
		watch_stop(watch)
		return nil, false
	}
	watch.native.worker = thread.create(watch_main)
	if watch.native.worker == nil {
		log.error("starting the directory watch thread failed")
		watch_cancel_read(watch)
		watch_stop(watch)
		return nil, false
	}
	watch.native.worker.data = watch
	watch.native.worker.init_context = context
	thread.start(watch.native.worker)
	return watch, true
}

// Joins the thread and frees everything, including paths nobody took. Accepts nil and a watch that
// only partly started. Must not run on the watch's thread, so never from the wake.
watch_stop :: proc(watch: ^Watch) {
	if watch == nil {return}
	native := &watch.native
	if native.worker != nil {
		// The thread cancels the read in flight and waits for the kernel to let go of the buffer
		// before it returns, so the handles can close and the memory be freed after the join.
		_ = w.SetEvent(native.stop)
		thread.join(native.worker)
		thread.destroy(native.worker)
	}
	watch_close(&native.directory)
	watch_close(&native.changed.hEvent)
	watch_close(&native.stop)
	allocator := watch.allocator
	watch_release(watch)
	free(watch, allocator)
}

@(private)
watch_close :: proc(handle: ^w.HANDLE) {
	if handle^ == nil {return}
	_ = w.CloseHandle(handle^)
	handle^ = nil
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

@(private, require_results)
watch_open :: proc(watch: ^Watch, directory: string) -> bool {
	native := &watch.native
	path := w.utf8_to_wstring(directory, watch.allocator)
	if path == nil {
		log.errorf("converting the watched directory %q to UTF-16 failed", directory)
		return false
	}
	defer delete(path, watch.allocator)
	if !watch_is_directory(path, directory) {return false}
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
	native.changed.hEvent = w.CreateEventW(nil, true, false, nil)
	if native.changed.hEvent == nil {
		log.errorf("CreateEventW failed: %d", w.GetLastError())
		return false
	}
	native.stop = w.CreateEventW(nil, true, false, nil)
	if native.stop == nil {
		log.errorf("CreateEventW failed: %d", w.GetLastError())
		return false
	}
	return true
}

// Starts the next read. Changes made while no read is in flight queue in the kernel, up to the
// buffer's size, and the next read returns them.
@(private, require_results)
watch_arm :: proc(watch: ^Watch) -> bool {
	native := &watch.native
	native.changed = {hEvent = native.changed.hEvent}
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
		log.errorf("ReadDirectoryChangesW failed: %d", w.GetLastError())
		return false
	}
	return true
}

// Cancels the read in flight and waits until the kernel is done with the buffer, cancelled or
// completed.
@(private)
watch_cancel_read :: proc(watch: ^Watch) {
	native := &watch.native
	if !bool(w.CancelIoEx(native.directory, &native.changed)) {
		error := w.GetLastError()
		if error != w.ERROR_NOT_FOUND {
			// Waiting for a read that was not cancelled could block for ever. Closing the handle
			// cancels it instead.
			log.errorf("CancelIoEx failed: %d", error)
			return
		}
	}
	transferred: w.DWORD
	if !bool(w.GetOverlappedResult(native.directory, &native.changed, &transferred, true)) {
		error := w.GetLastError()
		if error != w.ERROR_OPERATION_ABORTED {
			log.errorf("GetOverlappedResult after cancelling failed: %d", error)
		}
	}
}

@(private)
watch_main :: proc(t: ^thread.Thread) {
	watch := (^Watch)(t.data)
	native := &watch.native
	// watch_start armed the first read.
	in_flight := true
	defer if in_flight {watch_cancel_read(watch)}
	handles := [2]w.HANDLE{native.changed.hEvent, native.stop}
	for {
		signalled := w.WaitForMultipleObjects(2, &handles[0], false, w.INFINITE)
		if signalled == w.WAIT_OBJECT_0 + 1 {return}
		if signalled != w.WAIT_OBJECT_0 {
			log.errorf("waiting for directory changes failed: %d", w.GetLastError())
			watch_overflow(watch)
			return
		}
		bytes, result := watch_finish_read(watch)
		in_flight = false
		switch result {
		case .Changes:
			if watch_parse(watch, bytes) {watch_notify(watch)}
		case .Overflow:
			watch_overflow(watch)
		case .Failed:
			watch_overflow(watch)
			return
		}
		if !watch_arm(watch) {
			watch_overflow(watch)
			return
		}
		in_flight = true
	}
}

@(private)
watch_finish_read :: proc(watch: ^Watch) -> (bytes: int, result: Watch_Read) {
	native := &watch.native
	count: w.DWORD
	if !bool(w.GetOverlappedResult(native.directory, &native.changed, &count, false)) {
		error := w.GetLastError()
		if error == ERROR_NOTIFY_ENUM_DIR {return 0, .Overflow}
		log.errorf("reading directory changes failed: %d", error)
		return 0, .Failed
	}
	if count == 0 {return 0, .Overflow}
	return int(count), .Changes
}

// Records every path in the first `bytes` of the buffer. Reports whether the owner has anything new.
@(private)
watch_parse :: proc(watch: ^Watch, bytes: int) -> (arrived: bool) {
	native := &watch.native
	buffer := mem.slice_to_bytes(native.reading[:])
	offset := 0
	for offset + WATCH_RECORD_HEADER <= bytes {
		record := (^w.FILE_NOTIFY_INFORMATION)(&buffer[offset])
		first := offset + WATCH_RECORD_HEADER
		length := int(record.FileNameLength) / size_of(u16)
		if first + length * size_of(u16) > bytes {break}
		name := mem.slice_data_cast([]u16, buffer[first:first + length * size_of(u16)])
		path := watch_path(native.name[:], name)
		if path != "" && !watch_ignored(path) && watch_record(watch, path) {arrived = true}
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
