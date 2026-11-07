package main

import "aio:platform"
import "core:log"

// The notification area icon: its menu, its events, and hiding windows to it and showing them again.

@(private)
TRAY_OPEN :: 1
@(private)
TRAY_QUIT :: 2

// Shows the icon with its menu. A failure is logged: the app still runs, only without the tray.
tray_init :: proc(app: ^App) {
	if platform.tray_create(&app.platform, app.app_id) != .None {
		log.error("creating the tray icon failed")
	}
	tray_menu := [?]platform.Tray_Menu_Item {
		{id = TRAY_OPEN, title = "Open AIODev"},
		{id = TRAY_QUIT, title = "Quit"},
	}
	if platform.tray_set_menu(&app.platform, tray_menu[:]) != .None {
		log.error("setting the tray menu failed")
	}
}

tray_destroy :: proc(app: ^App) {
	if platform.tray_destroy(&app.platform) != .None {
		log.error("removing the tray icon failed")
	}
}

// A click on the icon, a row of its menu, or a click on one of its notifications. Token 0 is the
// hide-to-tray hint, which reopens the app; every other token is a status notification.
tray_event :: proc(app: ^App, event: platform.Event) {
	#partial switch e in event {
	case platform.Tray_Event:
		show_window(app)
	case platform.Tray_Notification_Event:
		if e.token == 0 {
			show_window(app)
		} else {
			status_notification_clicked(app, u32(e.token))
		}
	case platform.Tray_Menu_Event:
		switch e.id {
		case TRAY_OPEN:
			show_window(app)
		case TRAY_QUIT:
			app_quit(app)
		}
	}
}

show_window :: proc(app: ^App) {
	if len(app.workspaces) == 0 {return}
	if app_tray_only(app) {
		workspace := app.workspaces[0]
		if len(workspace.tabs) == 0 {
			if _, created := tab_create(app, workspace); !created {
				notify(app, .Error, "Could not create a tab.")
				return
			}
		}
		if !window_open(app, workspace) {
			notify(app, .Error, "Could not open the AIODev window.")
			return
		}
	}
	_ = window_activate(app, window_primary(app))
}

hide_to_tray :: proc(app: ^App, w: ^Window) {
	focus_leave(app, w)
	window_close(app, w)
	if !app_tray_only(app) {return}
	if app.settings.window.tray_notification && !app.tray_hint_shown {
		app.tray_hint_shown = true
		text := "Your shell keeps running. Click the tray icon to reopen AIODev, or use Quit to exit."
		if platform.tray_notify(&app.platform, "AIODev is still running", text) != .None {
			log.error("showing the tray notification failed")
		}
	}
}
