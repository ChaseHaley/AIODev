package app_test

import "core:testing"
import "core:fmt"
import app "../../src"
import "aio:settings"
import "aio:term"

@(test)
status_notifications_default_to_windows_banners_without_flashing :: proc(t: ^testing.T) {
	s, err := settings.defaults()
	if !testing.expect_value(t, err, nil) {return}
	defer settings.destroy(&s)
	for state in ([2]term.Program_Status_State{.Blocked, .Error}) {
		c := app.status_notification_channels(&s.status, state)
		testing.expect(t, c.banner && c.sound)
		testing.expect(t, !c.tray && !c.flash && !c.notice)
	}
	for state in ([3]term.Program_Status_State{.Idle, .Working, .Done}) {
		testing.expect_value(t, app.status_notification_channels(&s.status, state), app.Status_Notification_Channels{})
	}
	s.status.enabled = false
	testing.expect_value(t, app.status_notification_channels(&s.status, .Blocked), app.Status_Notification_Channels{})
}

@(test)
status_channels_round_trip_and_route_independently_for_every_state :: proc(t: ^testing.T) {
	states := [5]term.Program_Status_State{.Idle, .Working, .Done, .Blocked, .Error}
	names := [5]string{"idle", "working", "done", "blocked", "error"}
	channels := [5]string{"banner", "tray", "flash", "sound", "notice"}
	for state, i in states {
		for channel, selected in channels {
			text := fmt.tprintf("status.notify_%s = true\n", names[i])
			for other in channels {
				text = fmt.tprintf("%sstatus.%s_%s = %s\n", text, other, names[i], other == channel ? "true" : "false")
			}
			s, diagnostics, err := settings.parse(text)
			if !testing.expect_value(t, err, nil) {continue}
			testing.expect_value(t, len(diagnostics), 0)
			c := app.status_notification_channels(&s.status, state)
			values := [5]bool{c.banner, c.tray, c.flash, c.sound, c.notice}
			for value, index in values {testing.expect_value(t, value, index == selected)}
			settings.diagnostics_destroy(&diagnostics)
			settings.destroy(&s)
		}
	}
}

@(test)
status_legacy_switch_disables_every_channel :: proc(t: ^testing.T) {
	s, diagnostics, err := settings.parse("status.notify_blocked = false\nstatus.flash_blocked = true\n")
	if !testing.expect_value(t, err, nil) {return}
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&diagnostics)
	testing.expect_value(t, len(diagnostics), 0)
	testing.expect_value(t, app.status_notification_channels(&s.status, .Blocked), app.Status_Notification_Channels{})
}
