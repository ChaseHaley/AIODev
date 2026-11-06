package main

// Where a window is in its life. window_prepare starts every window Preparing; window_commit and
// window_close (window.odin) and the linked-window transitions in pane_links.odin are the only other
// writers, so a window is in exactly one of these and every side effect of a change has one home.
Window_Phase :: enum u8 {
	// The zero value, so a window built as a plain value is an ordinary one.
	Shown,
	// Created hidden and nobody's window yet: one being opened, or a tear-off preview a drop may still
	// discard. It takes no input and is never drawn.
	Preparing,
	// A linked window whose tab is off screen. Only linked windows hide; the others close instead.
	Hidden,
	// window_close has begun, so whatever it sets off sees a window on its way out.
	Closing,
}

// A linked window shows part of a tab instead of a workspace; see pane_links.odin. w.workspace is then
// a private view of those panes, and `workspace` is the id of the workspace that really holds them.
Window_Link :: struct {
	workspace: u32,
	// Requests the show that next puts the window on screen carries out.
	activate, maximize: bool,
}

window_linked :: proc(w: ^Window) -> bool {
	return w.link != nil
}

// 0 for a window that is not linked.
window_link_workspace :: proc(w: ^Window) -> u32 {
	link, linked := w.link.?
	return linked ? link.workspace : 0
}

// Windows reports a minimized window's client area as 0×0, and window_resize keeps what it reports.
window_minimized :: proc(w: ^Window) -> bool {
	return w.width <= 0 || w.height <= 0
}

// On screen with room to draw: the windows that present frames and may hold the notices.
window_drawable :: proc(w: ^Window) -> bool {
	return w.phase == .Shown && !window_minimized(w)
}

// The first window that shows a workspace of its own, which is what callers mean by the app's window.
window_primary :: proc(app: ^App) -> ^Window {
	for w in app.windows {
		if !window_linked(w) {return w}
	}
	return nil
}

// Every workspace window has been hidden to the tray, so only the tray icon reopens the app.
app_tray_only :: proc(app: ^App) -> bool {
	return window_primary(app) == nil
}
