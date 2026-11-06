package platform_test

import p "aio:platform"
import "core:testing"
import "core:thread"
import w "core:sys/windows"

@(private="file")
Clipboard_Lock :: struct {ready: w.HANDLE, opened, signaled, closed: bool}

@(private="file")
hold_clipboard :: proc(worker: ^thread.Thread) {
	lock := cast(^Clipboard_Lock)worker.data
	lock.opened = bool(w.OpenClipboard(nil))
	lock.signaled = bool(w.SetEvent(lock.ready))
	if lock.opened {
		w.Sleep(40)
		lock.closed = bool(w.CloseClipboard())
	}
}

@(test)
clipboard_operations_survive_a_brief_external_lock :: proc(t: ^testing.T) {
	platform: p.Platform
	if !testing.expect_value(t, p.init(&platform, "AIODev.Test.ClipboardLock"), p.Init_Result.Primary) {return}
	defer testing.expect_value(t, p.destroy(&platform), p.Error.None)
	previous, saved := p.clipboard_get_text(&platform, context.allocator)
	if !testing.expect(t, saved) {return}
	defer {testing.expect(t, p.clipboard_set_text(&platform, previous)); delete(previous)}
	if !testing.expect(t, p.clipboard_set_text(&platform, "before")) {return}
	for write in ([?]bool{true, false}) {
		lock := Clipboard_Lock{ready = w.CreateEventW(nil, true, false, nil)}
		if !testing.expect(t, lock.ready != nil) {return}
		defer testing.expect(t, bool(w.CloseHandle(lock.ready)))
		worker := thread.create(hold_clipboard)
		if !testing.expect(t, worker != nil) {return}
		worker.data = &lock
		thread.start(worker)
		ready := w.WaitForSingleObject(lock.ready, 2000) == w.WAIT_OBJECT_0
		ok := false
		text := ""
		if ready {
			if write {ok = p.clipboard_set_text(&platform, "after")}
			else {text, ok = p.clipboard_get_text(&platform, context.allocator)}
		}
		thread.join(worker)
		thread.destroy(worker)
		testing.expect(t, ready && lock.opened && lock.signaled && lock.closed)
		testing.expect(t, ok)
		if !write {testing.expect_value(t, text, "after"); delete(text)}
	}
}
