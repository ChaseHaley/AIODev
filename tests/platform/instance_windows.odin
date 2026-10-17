package platform_test

import "core:fmt"
import "core:os"
import "core:testing"
import p "aio:platform"

@(test)
instance_running_lifecycle :: proc(t: ^testing.T) {
	buffer: [128]u8
	id := fmt.bprintf(buffer[:], "AIODev.Test.Instance.%d", os.get_pid())
	running, err := p.instance_running(id)
	testing.expect_value(t, err, p.Error.None)
	if !testing.expect(t, !running) { return }
	platform: p.Platform
	if !testing.expect_value(t, p.init(&platform, id), p.Init_Result.Primary) { return }
	defer testing.expect_value(t, p.destroy(&platform), p.Error.None)
	for _ in 0..<2 {
		running, err = p.instance_running(id)
		testing.expect_value(t, err, p.Error.None)
		testing.expect(t, running)
	}
	other_buffer: [128]u8
	other := fmt.bprintf(other_buffer[:], "%s.Other", id)
	running, err = p.instance_running(other)
	testing.expect_value(t, err, p.Error.None)
	testing.expect(t, !running)
	events, poll_error := p.poll_events(&platform)
	testing.expect_value(t, poll_error, p.Error.None)
	for event in events {
		_, activated := event.(p.Activate_Request_Event)
		testing.expect(t, !activated)
	}
	testing.expect_value(t, p.destroy(&platform), p.Error.None)
	running, err = p.instance_running(id)
	testing.expect_value(t, err, p.Error.None)
	testing.expect(t, !running)
}

@(test)
instance_running_invalid_ids :: proc(t: ^testing.T) {
	for id in ([]string{"", `bad\id`, "bad/id", "bad\x00id", "\xff",
		"123456789012345678901234567890123456789012345678901234567890"+
		"123456789012345678901234567890123456789012345678901234567890X"}) {
		running, err := p.instance_running(id)
		testing.expect_value(t, err, p.Error.Invalid_Argument)
		testing.expect(t, !running)
	}
}
