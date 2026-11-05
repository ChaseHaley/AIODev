package platform

import "core:log"
import "core:strings"
import "core:sync"
import w "core:sys/windows"
import "core:thread"

foreign import pick_user32 "system:user32.lib"

@(default_calling_convention = "system", private)
foreign pick_user32 {
	EnumThreadWindows :: proc(
		thread: w.DWORD,
		callback: proc "system" (w.HWND, w.LPARAM) -> w.BOOL,
		data: w.LPARAM,
	) -> w.BOOL ---
}

// A file dialog open on its own thread. The system dialog runs a modal loop, which on the UI thread
// would stop every terminal from drawing until it closed.
File_Pick :: struct {
	thread:            ^thread.Thread,
	owner:             w.HWND,
	filter, directory: cstring16,
	path:              string,
	picked:            bool,
	thread_id:         w.DWORD,
	done:              bool,
}

@(private)
file_pick_run :: proc(t: ^thread.Thread) {
	pick := (^File_Pick)(t.data)
	sync.atomic_store(&pick.thread_id, w.GetCurrentThreadId())
	defer {
		sync.atomic_store(&pick.done, true)
		// Wakes the UI thread's event wait so it collects the result. A closed owner needs no waking.
		w.PostMessageW(pick.owner, w.WM_NULL, 0, 0)
	}
	// The Explorer dialog needs an apartment on the thread that shows it.
	initialized := w.CoInitializeEx(nil, .APARTMENTTHREADED)
	defer if initialized >= 0 {w.CoUninitialize()}
	buffer: [4096]u16
	dialog := w.OPENFILENAMEW {
		lStructSize     = size_of(w.OPENFILENAMEW),
		hwndOwner       = pick.owner,
		lpstrFile       = cstring16(&buffer[0]),
		nMaxFile        = u32(len(buffer)),
		lpstrFilter     = pick.filter,
		lpstrInitialDir = pick.directory,
		// The dialog otherwise changes the process's working directory, which new shells inherit.
		Flags           = w.OFN_EXPLORER | w.OFN_PATHMUSTEXIST | w.OFN_FILEMUSTEXIST | w.OFN_NOCHANGEDIR,
	}
	if !bool(w.GetOpenFileNameW(&dialog)) {
		if code := w.CommDlgExtendedError(); code != 0 {log.errorf("GetOpenFileNameW failed: %d", code)}
		return
	}
	length := 0
	for length < len(buffer) && buffer[length] != 0 {length += 1}
	path, err := w.utf16_to_utf8(buffer[:length], context.allocator)
	if err == nil {pick.path, pick.picked = path, true}
}

// Opens a dialog owned by the window. Returns nil when it could not start.
@(require_results)
file_pick_start :: proc(p: ^Platform, id: Window_Id, filter_name, pattern, directory: string) -> ^File_Pick {
	window := find_window(p, id)
	if window == nil {return nil}
	pick, err := new(File_Pick)
	if err != nil {return nil}
	pick.owner = window.hwnd
	filter := strings.concatenate({filter_name, "\x00", pattern, "\x00"}, context.temp_allocator)
	pick.filter = w.utf8_to_wstring(filter, context.allocator)
	if directory != "" {pick.directory = w.utf8_to_wstring(directory, context.allocator)}
	pick.thread = thread.create(file_pick_run)
	if pick.filter == nil || pick.thread == nil {
		file_pick_destroy(pick)
		return nil
	}
	pick.thread.data = pick
	pick.thread.init_context = context
	thread.start(pick.thread)
	return pick
}

// Whether the dialog has closed. The path is empty when nothing was chosen, and belongs to the pick.
@(require_results)
file_pick_finished :: proc(pick: ^File_Pick) -> (path: string, finished: bool) {
	if !sync.atomic_load(&pick.done) {return "", false}
	return pick.path, true
}

// Closes a dialog that is still open, waits for its thread and frees the pick.
file_pick_destroy :: proc(pick: ^File_Pick) {
	if pick.thread != nil {
		for !thread.is_done(pick.thread) {
			if id := sync.atomic_load(&pick.thread_id); id != 0 {
				EnumThreadWindows(id, proc "system" (window: w.HWND, _: w.LPARAM) -> w.BOOL {
					w.PostMessageW(window, w.WM_CLOSE, 0, 0)
					return true
				}, 0)
			}
			w.Sleep(10)
		}
		thread.destroy(pick.thread)
	}
	delete(pick.path)
	if pick.filter != nil {free(rawptr(pick.filter))}
	if pick.directory != nil {free(rawptr(pick.directory))}
	free(pick)
}
