package pty_test

import "core:testing"
import "aio:pty"

@(test)
process_tree_tracks_children_and_shell_return :: proc(t: ^testing.T) {
	processes := [?]pty.Process_Info{
		{1, 0, "host"}, {2, 1, "pwsh.exe"}, {3, 2, "nvim.exe"},
		{4, 3, "rg.exe"}, {5, 1, "unrelated.exe"}, {6, 6, "self"}, {7, 8, "cycle"}, {8, 7, "cycle"},
	}
	testing.expect_value(t, pty.process_leaf(processes[:], 2), 3)
	testing.expect_value(t, pty.process_leaf(processes[:3], 2), 2)
	testing.expect_value(t, pty.process_leaf(processes[:2], 2), 1)
	testing.expect_value(t, pty.process_leaf(processes[:], 99), -1)
	testing.expect_value(t, pty.process_leaf(nil, 2), -1)
	testing.expect_value(t, pty.process_ancestor(processes[:], 3), 2)
	testing.expect_value(t, pty.process_ancestor(processes[:], 0), -1)
}
