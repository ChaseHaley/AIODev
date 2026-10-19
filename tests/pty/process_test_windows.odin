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
