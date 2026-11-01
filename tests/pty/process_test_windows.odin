package pty_test

import "core:testing"
import w "core:sys/windows"
import "aio:pty"

@(test)
process_snapshot_contains_current_process :: proc(t: ^testing.T) {
	snapshot, err := pty.process_snapshot()
	if !testing.expect_value(t, err, pty.Error.None) { return }
	defer pty.process_snapshot_destroy(snapshot)
	index := pty.process_leaf(snapshot, w.GetCurrentProcessId())
	if testing.expect(t, index >= 0) { testing.expect(t, snapshot[index].executable != "") }
}

@(test)
process_image_names_live_descendants_only :: proc(t: ^testing.T) {
	current := w.GetCurrentProcessId()
	path, ok := pty.process_image(current, current)
	if testing.expect(t, ok) {
		defer delete(path)
		testing.expect(t, len(path) > 3 && path[1] == ':', "a full image path")
	}
	// The parent was created before this process, so it cannot be its descendant.
	snapshot, err := pty.process_snapshot(context.temp_allocator)
	if !testing.expect_value(t, err, pty.Error.None) {return}
	for p in snapshot {
		if p.id != current {continue}
		parent_path, parent_ok := pty.process_image(p.parent, current)
		testing.expect(t, !parent_ok)
		delete(parent_path)
	}
	_, missing := pty.process_image(0xFFFFFFF0, current)
	testing.expect(t, !missing)
}
