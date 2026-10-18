package commands_test

import "core:testing"
import "aio:commands"

@(test)
leader_shortcuts_are_opt_in_and_distinct_from_direct_chords :: proc(t: ^testing.T) {
	r := commands.create()
	defer commands.destroy(&r)
	direct, ok := commands.parse_shortcut("Ctrl+T")
	testing.expect(t, ok)
	leader, leader_ok := commands.parse_shortcut("Leader+Ctrl+T")
	testing.expect(t, leader_ok)
	testing.expect_value(t, commands.register(&r, {
		id = 1, name = "direct", title = "Direct", shortcuts = {{0 = direct}, 1},
	}), commands.Error.None)
	testing.expect_value(t, commands.register(&r, {
		id = 2, name = "leader", title = "Leader", shortcuts = {{0 = leader}, 1},
	}), commands.Error.None)
	testing.expect_value(t, commands.find_by_shortcut(&r, direct).id, commands.Command_Id(1))
	testing.expect_value(t, commands.find_by_shortcut(&r, leader).id, commands.Command_Id(2))
	buffer: [128]u8
	label, err := commands.shortcut_label(leader, buffer[:])
	testing.expect_value(t, err, commands.Error.None)
	testing.expect_value(t, label, "Leader+Ctrl+T")
	_, duplicate := commands.parse_shortcut("Leader+Leader+T")
	testing.expect(t, !duplicate)
}
