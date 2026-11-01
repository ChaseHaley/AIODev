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
			s, diagnostics, err := settings.parse(fmt.tprintf("status.notify_%s = %s\n", names[i], channel))
			if !testing.expect_value(t, err, nil) {continue}
			testing.expect_value(t, len(diagnostics), 0)
			c := app.status_notification_channels(&s.status, state)
			values := [5]bool{c.banner, c.tray, c.flash, c.sound, c.notice}
			for value, index in values {testing.expect_value(t, value, index == selected)}
			entry := settings.schema_find(fmt.tprintf("status.notify_%s", names[i]))
			testing.expect_value(t, settings.value_text(&s, entry^), channel)
			settings.diagnostics_destroy(&diagnostics)
			settings.destroy(&s)
		}
	}
}

@(test)
status_channel_sets_accept_combinations_and_none :: proc(t: ^testing.T) {
	s, diagnostics, err := settings.parse(
		"status.notify_done = sound,  flash ,banner\nstatus.notify_blocked = none\nstatus.notify_error = bell\n",
	)
	if !testing.expect_value(t, err, nil) {return}
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&diagnostics)
	testing.expect_value(t, len(diagnostics), 1)
	testing.expect_value(t, app.status_notification_channels(&s.status, .Done),
	                     app.Status_Notification_Channels{banner = true, flash = true, sound = true})
	testing.expect_value(t, settings.value_text(&s, settings.schema_find("status.notify_done")^), "banner, flash, sound")
	testing.expect_value(t, app.status_notification_channels(&s.status, .Blocked), app.Status_Notification_Channels{})
	// An unknown channel keeps the default rather than silencing the state.
	testing.expect_value(t, app.status_notification_channels(&s.status, .Error),
	                     app.Status_Notification_Channels{banner = true, sound = true})
}

@(test)
status_legacy_toggles_migrate_into_channel_sets :: proc(t: ^testing.T) {
	source := "# Enable configured notifications when a program needs you.\n" +
		"status.notify_blocked = false\n" +
		"# Flash the taskbar button while the window is unfocused.\n" +
		"status.flash_blocked = true\n" +
		"status.notify_error = true\n" +
		"status.sound_error = false\n" +
		"status.notice_error = true\n" +
		"status.tray_done = true\n" +
		"status.notify_working = true\n" +
		"font.size = 13\n"
	updated, migrated, err := settings.migrate_settings_text(source)
	if !testing.expect_value(t, err, nil) {return}
	defer delete(updated)
	testing.expect(t, migrated)
	testing.expect_value(t, updated,
		"# How to notify you when a program needs you.\n" +
		"status.notify_blocked = none\n" +
		"status.notify_error = banner, notice\n" +
		"status.notify_done = none\n" +
		"status.notify_working = banner, sound\n" +
		"font.size = 13\n")
	s, diagnostics, parse_error := settings.parse(updated)
	if !testing.expect_value(t, parse_error, nil) {return}
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&diagnostics)
	testing.expect_value(t, len(diagnostics), 0)
	again, again_migrated, again_error := settings.migrate_settings_text(updated)
	testing.expect_value(t, again_error, nil)
	testing.expect(t, !again_migrated)
	delete(again)
}
