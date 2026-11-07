package platform

import "aio:input"
import "core:log"
import "core:strings"
import "core:sync"
import w "core:sys/windows"
import "core:thread"

foreign import pick_user32 "system:user32.lib"
foreign import pick_shell32 "system:shell32.lib"
foreign import pick_ole32 "system:ole32.lib"

@(default_calling_convention = "system", private)
foreign pick_user32 {
	EnumThreadWindows :: proc(
		thread: w.DWORD,
		callback: proc "system" (w.HWND, w.LPARAM) -> w.BOOL,
		data: w.LPARAM,
	) -> w.BOOL ---
}

@(default_calling_convention = "system", private)
foreign pick_shell32 {
	SHCreateItemFromParsingName :: proc(
		path: w.LPCWSTR,
		context_: rawptr,
		iid: ^w.GUID,
		item: ^rawptr,
	) -> w.HRESULT ---
}

@(default_calling_convention = "system", private)
foreign pick_ole32 {
	CoTaskMemFree :: proc(memory: rawptr) ---
}

@(private)
Shell_Item :: struct #raw_union {
	#subtype unknown: w.IUnknown,
	using vtable: ^Shell_Item_Vtable,
}
@(private)
Shell_Item_Vtable :: struct {
	using unknown_vtable: w.IUnknown_VTable,
	BindToHandler, GetParent: rawptr,
	GetDisplayName: proc "system" (this: ^Shell_Item, name_kind: u32, name: ^[^]u16) -> w.HRESULT,
	GetAttributes, Compare: rawptr,
}
@(private)
Open_Dialog :: struct #raw_union {
	#subtype unknown: w.IUnknown,
	using vtable: ^Open_Dialog_Vtable,
}
@(private)
Open_Dialog_Vtable :: struct {
	using unknown_vtable: w.IUnknown_VTable,
	Show: proc "system" (this: ^Open_Dialog, owner: w.HWND) -> w.HRESULT,
	SetFileTypes, SetFileTypeIndex, GetFileTypeIndex, Advise, Unadvise: rawptr,
	SetOptions: proc "system" (this: ^Open_Dialog, options: u32) -> w.HRESULT,
	GetOptions: proc "system" (this: ^Open_Dialog, options: ^u32) -> w.HRESULT,
	SetDefaultFolder: rawptr,
	SetFolder: proc "system" (this: ^Open_Dialog, item: ^Shell_Item) -> w.HRESULT,
	GetFolder, GetCurrentSelection, SetFileName, GetFileName, SetTitle: rawptr,
	SetOkButtonLabel, SetFileNameLabel: rawptr,
	GetResult: proc "system" (this: ^Open_Dialog, item: ^^Shell_Item) -> w.HRESULT,
}

// A file dialog open on its own thread. The system dialog runs a modal loop, which on the UI thread
// would stop every terminal from drawing until it closed.
File_Pick :: struct {
	thread:            ^thread.Thread,
	owner:             w.HWND,
	filter, directory: cstring16,
	folders:           bool,
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
	if pick.folders {
		file_pick_folder(pick)
		return
	}
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

// The classic dialog cannot choose a folder, so this one asks the shell's item dialog for one.
@(private)
file_pick_folder :: proc(pick: ^File_Pick) {
	class_id := w.GUID{0xdc1c5a9c, 0xe88a, 0x4dde, {0xa5, 0xa1, 0x60, 0xf8, 0x2a, 0x20, 0xae, 0xf7}}
	dialog_id := w.GUID{0xd57c7288, 0xd4ad, 0x4768, {0xbe, 0x02, 0x9d, 0x96, 0x95, 0x32, 0xd9, 0x60}}
	item_id := w.GUID{0x43826d1e, 0xe718, 0x42ee, {0xbc, 0x55, 0xa1, 0xe2, 0x61, 0xc3, 0x7b, 0xfe}}
	object: rawptr
	result := w.CoCreateInstance(&class_id, nil, w.CLSCTX_INPROC_SERVER, &dialog_id, &object)
	if result < 0 || object == nil {
		log.errorf("CoCreateInstance(FileOpenDialog) failed: %x", u32(result))
		return
	}
	dialog := (^Open_Dialog)(object)
	defer dialog->Release()
	FOS_NOCHANGEDIR :: 0x8
	FOS_PICKFOLDERS :: 0x20
	FOS_FORCEFILESYSTEM :: 0x40
	options: u32
	if result = dialog->GetOptions(&options); result < 0 {
		log.errorf("IFileDialog.GetOptions failed: %x", u32(result))
		return
	}
	options |= FOS_NOCHANGEDIR | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM
	if result = dialog->SetOptions(options); result < 0 {
		log.errorf("IFileDialog.SetOptions failed: %x", u32(result))
		return
	}
	if pick.directory != nil {
		start: rawptr
		// A start folder that has gone only costs the dialog its starting place.
		if SHCreateItemFromParsingName(pick.directory, nil, &item_id, &start) >= 0 && start != nil {
			folder := (^Shell_Item)(start)
			defer folder->Release()
			if result = dialog->SetFolder(folder); result < 0 {
				log.errorf("IFileDialog.SetFolder failed: %x", u32(result))
			}
		}
	}
	// HRESULT_FROM_WIN32(ERROR_CANCELLED), which Show returns when the user closes the dialog.
	CANCELLED :: u32(0x800704C7)
	if result = dialog->Show(pick.owner); result < 0 {
		if u32(result) != CANCELLED {log.errorf("IFileDialog.Show failed: %x", u32(result))}
		return
	}
	chosen: ^Shell_Item
	if result = dialog->GetResult(&chosen); result < 0 || chosen == nil {
		log.errorf("IFileDialog.GetResult failed: %x", u32(result))
		return
	}
	defer chosen->Release()
	SIGDN_FILESYSPATH :: 0x80058000
	name: [^]u16
	if result = chosen->GetDisplayName(SIGDN_FILESYSPATH, &name); result < 0 || name == nil {
		log.errorf("IShellItem.GetDisplayName failed: %x", u32(result))
		return
	}
	defer CoTaskMemFree(name)
	length := 0
	for name[length] != 0 {length += 1}
	path, err := w.utf16_to_utf8(name[:length], context.allocator)
	if err == nil {pick.path, pick.picked = path, true}
}

// Opens a dialog owned by the window. Returns nil when it could not start. With `folders`, it chooses
// a folder, and the filter is unused.
@(require_results)
file_pick_start :: proc(
	p: ^Platform,
	id: input.Window_Id,
	filter_name, pattern, directory: string,
	folders := false,
) -> ^File_Pick {
	window := find_window(p, id)
	if window == nil {return nil}
	pick, err := new(File_Pick)
	if err != nil {return nil}
	pick.owner, pick.folders = window.hwnd, folders
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

// Closes a dialog that is still open, waits for its thread and frees the pick. A dialog whose owner
// still exists sends it messages while it opens and closes, so the wait answers those without
// taking any posted message off the queue.
file_pick_destroy :: proc(pick: ^File_Pick) {
	if pick.thread != nil {
		for !thread.is_done(pick.thread) {
			if id := sync.atomic_load(&pick.thread_id); id != 0 {
				EnumThreadWindows(id, proc "system" (window: w.HWND, _: w.LPARAM) -> w.BOOL {
					w.PostMessageW(window, w.WM_CLOSE, 0, 0)
					return true
				}, 0)
			}
			message: w.MSG
			w.PeekMessageW(&message, nil, 0, 0, w.PM_NOREMOVE | w.PM_QS_SENDMESSAGE)
			w.Sleep(10)
		}
		thread.destroy(pick.thread)
	}
	delete(pick.path)
	if pick.filter != nil {free(rawptr(pick.filter))}
	if pick.directory != nil {free(rawptr(pick.directory))}
	free(pick)
}
