package main

import platform_api "aio:platform"
import "aio:render"
import "aio:settings"
import "aio:term"
import "aio:ui"
import "core:fmt"
import "core:log"
import "core:time"

// Program status (OSC 7501) as AIODev presents it. Each session's records are copied when they
// change, so drawing reads Session_Entry.statuses without taking the session lock. Only reports
// reach these surfaces; nothing is inferred from screen contents or titles. status_model.odin
// classifies each record.

@(private)
STATUS_SPIN_PERIOD_MS :: 1200
// At most one notification per pane in this interval keeps a chatty program from flooding them.
@(private)
STATUS_NOTICE_INTERVAL :: 5 * time.Second

// Shown records counted by rank; `needs` counts those that need the user, and `top` is the most
// urgent.
Status_Summary :: struct {
	top:     term.Program_Status,
	session: u32,
	found:   bool,
	counts:  [Status_Rank]int,
	needs:   int,
}

// What a window last told its taskbar button, and for which workspace, so only a change reaches
// the shell.
Status_Taskbar :: struct {
	workspace: ^Workspace,
	state:     platform_api.Progress_State,
	percent:   int,
}

// Keeps the previous snapshot when reading the session's records fails (retained: the next change
// reads them again).
status_refresh :: proc(app: ^App, entry: ^Session_Entry) {
	next, err := term.program_status(entry.session)
	if err != nil {return}
	previous := entry.statuses
	entry.statuses = next
	status_notify_changes(app, entry, previous)
	term.destroy_program_status(previous)
}

status_release :: proc(entry: ^Session_Entry) {
	term.destroy_program_status(entry.statuses)
	entry.statuses = nil
}

// Turning the protocol on or off reaches every live session at once.
status_apply_settings :: proc(app: ^App) {
	for &entry in app.sessions {
		term.configure(entry.session, session_options(app))
		status_refresh(app, &entry)
	}
	for w in app.windows {status_taskbar_update(app, w, true)}
	mark_all_dirty(app)
}

status_summary_add :: proc(app: ^App, summary: ^Status_Summary, entry: ^Session_Entry) {
	if entry == nil {return}
	for record in entry.statuses {
		if !status_shown(app, record) {continue}
		p := status_presentation(record)
		summary.counts[p.rank] += 1
		if p.attention {summary.needs += 1}
		if !summary.found || status_before(record, summary.top) {
			summary.top, summary.session, summary.found = record, entry.id, true
		}
	}
}

status_tab_summary :: proc(app: ^App, workspace: ^Workspace, tab: int) -> Status_Summary {
	summary: Status_Summary
	if !app.settings.status.enabled || workspace == nil || tab < 0 || tab >= len(workspace.tabs) {
		return summary
	}
	walk := tab_session_panes(app, &workspace.tabs[tab].tree, tab)
	for pane, ok := workspace_pane_next(&walk); ok; pane, ok = workspace_pane_next(&walk) {
		status_summary_add(app, &summary, pane.session)
	}
	return summary
}

status_workspace_summary :: proc(app: ^App, workspace: ^Workspace) -> Status_Summary {
	summary: Status_Summary
	if !app.settings.status.enabled || workspace == nil {return summary}
	walk := workspace_session_panes(app, workspace)
	for pane, ok := workspace_pane_next(&walk); ok; pane, ok = workspace_pane_next(&walk) {
		status_summary_add(app, &summary, pane.session)
	}
	return summary
}

// The mark a tab or row shows for a summary. Finished work already seen is left to the lists.
status_indicator :: proc(summary: Status_Summary) -> (ui.Status_Mark, bool) {
	if !summary.found {return {}, false}
	p := status_presentation(summary.top)
	if p.seen {return {}, false}
	return p.mark, true
}

// The spinner position for a mark this frame draws. Drawing a spinner keeps the window repainting
// while system animations are on; a still spinner is drawn otherwise. Retained as a draw-time
// flag: only drawing knows which marks are visible this frame.
status_phase :: proc(app: ^App, w: ^Window, mark: ui.Status_Mark) -> f32 {
	if mark.glyph != .Working || mark.progress >= 0 || !app.animations {return 0}
	w.status_spinning = true
	period := i64(STATUS_SPIN_PERIOD_MS) * i64(time.Millisecond)
	return f32(f64(time.tick_now()._nsec % period) / f64(period))
}

status_mark_draw :: proc(
	app: ^App,
	w: ^Window,
	area: render.Rect,
	mark: ui.Status_Mark,
) -> render.Build_Status {
	phase := status_phase(app, w, mark)
	return ui.status_glyph_draw(&w.list, &w.ui_text, app.theme, area, mark, phase, w.scale)
}

// The mark a tab shows, or none when tab indicators are off or the tab is the one in view.
status_tab_mark :: proc(app: ^App, w: ^Window, workspace: ^Workspace, tab: int) -> ui.Status_Mark {
	s := &app.settings.status
	if !s.enabled || !s.tab_indicators {return {}}
	if workspace == w.workspace && tab == workspace.selected && !s.active_tab_indicator {return {}}
	mark, _ := status_indicator(status_tab_summary(app, workspace, tab))
	return mark
}

// Queue the next frame immediately. window_render waits on the swap chain before sampling the
// phase, so display refresh paces animation without a timer cap or an extra sleep after Present.
status_spin_active :: proc(w: ^Window) -> bool {
	return w.status_spinning && window_drawable(w)
}

status_spin_tick :: proc(w: ^Window) {
	if status_spin_active(w) {w.dirty = true}
}

status_record_name :: proc(entry: ^Session_Entry, record: term.Program_Status) -> string {
	if record.title != "" {return record.title}
	if record.app != "" {return record.app}
	return session_display_title(entry)
}

status_watched :: proc(app: ^App, entry: ^Session_Entry) -> bool {
	for w in app.windows {
		if w.focused && focused_session(app, w) == entry {return true}
	}
	return false
}

// Looking at a pane acknowledges its finished work.
status_focus_enter :: proc(app: ^App, w: ^Window) {
	if !w.focused {return}
	if entry := focused_session(app, w); entry != nil {term.program_status_acknowledge(entry.session)}
}

// Leaving a pane removes the finished work the user saw there, unless it waits for a dismissal.
status_focus_leave :: proc(app: ^App, entry: ^Session_Entry) {
	if app.settings.status.keep_finished != .Focus {return}
	term.program_status_dismiss_finished(entry.session)
}

Status_Notification_Channels :: struct {
	banner, tray, flash, sound, notice: bool,
}

// A pure routing policy shared by transition eligibility and delivery.
status_notification_channels :: proc(
	s: ^settings.Status_Settings,
	state: term.Program_Status_State,
) -> Status_Notification_Channels {
	if !s.enabled {return {}}
	_, set := status_state_settings(s, state)
	return {.Banner in set, .Tray in set, .Flash in set, .Sound in set, .Notice in set}
}

@(private)
status_notify_wanted :: proc(app: ^App, record: term.Program_Status) -> bool {
	c := status_notification_channels(&app.settings.status, record.state)
	return c.banner || c.tray || c.flash || c.sound || c.notice
}

// A pane notifies at most once an interval, for the newest change that wants a notification. Once
// it has, the throttle drops every other change in the interval, those in the same refresh included:
// they are not queued, and the overviews still show each record. Seeing finished work changes no
// report, so it never notifies.
@(private)
status_notify_changes :: proc(app: ^App, entry: ^Session_Entry, previous: []term.Program_Status) {
	if !app.settings.status.enabled {return}
	if !app.settings.status.notify_focused && status_watched(app, entry) {return}
	now := time.tick_now()
	if entry.status_notified != {} && time.tick_diff(entry.status_notified, now) < STATUS_NOTICE_INTERVAL {
		return
	}
	for record in entry.statuses {
		if !status_notify_wanted(app, record) || !status_shown(app, record) {continue}
		reported := term.program_status_reported(record.state)
		changed := true
		for old in previous {
			if old.id == record.id {
				changed = term.program_status_reported(old.state) != reported || old.kind != record.kind
				break
			}
		}
		if !changed {continue}
		entry.status_notified = now
		status_notice(app, entry, record)
		return
	}
}

@(private)
status_notice :: proc(app: ^App, entry: ^Session_Entry, record: term.Program_Status) {
	p := status_presentation(record)
	buffer: [8]u8
	headline := status_headline(p.mark, buffer[:])
	title := fmt.tprintf("%s: %s", status_record_name(entry, record), headline)
	text := session_location(app, entry)
	if record.message != "" {text = fmt.tprintf("%s · %s", record.message, text)}
	c := status_notification_channels(&app.settings.status, record.state)
	// The sound rides on the first notification Windows shows, and plays on its own when none does.
	sound := c.sound
	token := platform_api.Notification_Token(entry.id)
	if c.banner {
		// Unavailable: notifications could not start, which the first banner already reported.
		result := platform_api.notification_show(&app.platform, title, text, token, sound)
		if result == .None {
			sound = false
		} else if result != .Unavailable {
			notify(app, .Error, "Windows could not show a status notification. Check notification settings.")
		}
	}
	if c.tray {
		if platform_api.tray_notify(&app.platform, title, text, token, sound) == .None {
			sound = false
		} else {
			notify(app, .Error, "Windows could not show a tray notification.")
		}
	}
	if sound && platform_api.notification_sound() != .None {
		log.error("playing program status sound failed")
	}
	if c.notice {notify(app, p.notice, fmt.tprintf("%s: %s", title, text))}
	target := session_window(app, entry.id, window_primary(app))
	if c.flash && target != nil && !target.focused &&
	   platform_api.window_flash(&app.platform, target.id) != .None {
		log.error("flashing the window for program status failed")
	}
}

// A click on a status notification jumps to the pane that sent it, reopening a window if all
// were hidden to the tray.
status_notification_clicked :: proc(app: ^App, session: u32) {
	if app_tray_only(app) {show_window(app)}
	if app_tray_only(app) {return}
	target := session_window(app, session, window_primary(app))
	if !window_activate(app, target) {return}
	_ = session_show(app, target, session)
}

status_in_scope :: proc(app: ^App, w: ^Window, workspace: ^Workspace) -> bool {
	return app.settings.status.scope == .All || workspace == w.workspace
}

// The panes with a session in every workspace of a window's status scope, in workspace and tab
// order. Each caller states whether workspaces workspace_eligible refuses are skipped.
Status_Scope_Walk :: struct {
	app:           ^App,
	w:             ^Window,
	eligible_only: bool,
	next:          int,
	panes:         Workspace_Pane_Walk,
}

status_scope_walk :: proc(app: ^App, w: ^Window, eligible_only: bool) -> Status_Scope_Walk {
	return {app = app, w = w, eligible_only = eligible_only}
}

@(require_results)
status_scope_next :: proc(
	walk: ^Status_Scope_Walk,
) -> (
	pane: Workspace_Pane,
	workspace: ^Workspace,
	ok: bool,
) {
	for {
		if walk.panes.workspace != nil {
			for p, more := workspace_pane_next(&walk.panes); more; p, more = workspace_pane_next(&walk.panes) {
				if p.session != nil {return p, walk.panes.workspace, true}
			}
		}
		if walk.next >= len(walk.app.workspaces) {return}
		candidate := walk.app.workspaces[walk.next]
		walk.next += 1
		walk.panes = {}
		if walk.eligible_only && !workspace_eligible(walk.app, candidate) {continue}
		if !status_in_scope(walk.app, walk.w, candidate) {continue}
		walk.panes = workspace_session_panes(walk.app, candidate)
	}
}

// One pane's records that settings show, with what an overview names and places them by. The
// records are a temp copy in the session's order, so an overview may sort them; their strings borrow
// from the session's snapshot, so the projection lives for one frame or event at most.
Status_Scope_Records :: struct {
	session:   u32,
	records:   []term.Program_Status,
	crumb:     string,
	workspace: string,
}

Status_Scope_Records_Walk :: struct {
	scope:   Status_Scope_Walk,
	enabled: bool,
}

// The panes in a window's status scope that show any record, for the inbox and the Activity panel.
status_scope_records :: proc(app: ^App, w: ^Window) -> Status_Scope_Records_Walk {
	return {scope = status_scope_walk(app, w, eligible_only = true), enabled = app.settings.status.enabled}
}

@(require_results)
status_scope_records_next :: proc(
	walk: ^Status_Scope_Records_Walk,
) -> (
	shown: Status_Scope_Records,
	ok: bool,
) {
	if !walk.enabled {return}
	app := walk.scope.app
	for pane, workspace, more := status_scope_next(&walk.scope);
	    more;
	    pane, workspace, more = status_scope_next(&walk.scope) {
		entry := pane.session
		if len(entry.statuses) == 0 {continue}
		records := make([dynamic]term.Program_Status, 0, len(entry.statuses), context.temp_allocator)
		for record in entry.statuses {
			if status_shown(app, record) {append(&records, record)}
		}
		if len(records) == 0 {continue}
		crumb := session_location_at(workspace, pane.tab, entry)
		return {entry.id, records[:], crumb, workspace.name}, true
	}
	return
}

// Moves to the most urgent record that needs the user, skipping the pane already in view so
// repeating the command walks the queue.
status_next_attention :: proc(app: ^App, w: ^Window) {
	current := focused_session(app, w)
	best: term.Program_Status
	session: u32
	found := false
	walk := status_scope_walk(app, w, eligible_only = true)
	for pane, _, ok := status_scope_next(&walk); ok; pane, _, ok = status_scope_next(&walk) {
		entry := pane.session
		if entry == current {continue}
		for record in entry.statuses {
			if !status_shown(app, record) || !status_presentation(record).attention {continue}
			if !found || status_before(record, best) {
				best, session, found = record, entry.id, true
			}
		}
	}
	if !found {
		notify(app, .Info, "No program needs you.")
		return
	}
	_ = session_show(app, w, session)
}

// Dismisses finished work everywhere in the window's overview scope. Unlike the inbox that offers
// it, it also reaches workspaces workspace_eligible refuses (retained pending the owner's call).
status_dismiss_finished :: proc(app: ^App, w: ^Window) {
	walk := status_scope_walk(app, w, eligible_only = false)
	for pane, _, ok := status_scope_next(&walk); ok; pane, _, ok = status_scope_next(&walk) {
		term.program_status_dismiss_finished(pane.session.session, true)
	}
}

// Shows a window's newly selected workspace on its taskbar button.
status_taskbar_follow :: proc(app: ^App, w: ^Window) {
	if w.taskbar.workspace == w.workspace {return}
	w.taskbar.workspace = w.workspace
	status_taskbar_update(app, w)
}

// Mirrors the window's workspace on its taskbar button: failures, then blocked work, then the
// least advanced job. Progress is 0..100 or negative for none, so 101 means no determinate job.
// Only a change reaches the shell.
status_taskbar_update :: proc(app: ^App, w: ^Window, force := false) {
	state := platform_api.Progress_State.None
	percent := 0
	s := &app.settings.status
	if s.enabled && s.taskbar && w.workspace != nil {
		failed, blocked, working, indeterminate := false, false, false, false
		least := 101
		walk := workspace_session_panes(app, w.workspace)
		for pane, ok := workspace_pane_next(&walk); ok; pane, ok = workspace_pane_next(&walk) {
			if pane.session == nil {continue}
			for record in pane.session.statuses {
				if !status_shown(app, record) {continue}
				switch status_presentation(record).taskbar {
				case .None:
				case .Failed:
					failed ||= s.taskbar_error
				case .Blocked:
					blocked ||= s.taskbar_blocked
				case .Working:
					if !s.taskbar_working {continue}
					working = true
					if record.progress >= 0 {
						least = min(least, int(record.progress))
					} else {
						indeterminate = true
					}
				}
			}
		}
		switch {
		case failed:
			state, percent = .Error, 100
		case blocked:
			state, percent = .Paused, least <= 100 ? least : 100
		case working && least <= 100:
			state, percent = .Normal, least
		case working && indeterminate:
			state = .Indeterminate
		}
	}
	if !force && state == w.taskbar.state && percent == w.taskbar.percent {return}
	w.taskbar.state, w.taskbar.percent = state, percent
	// Unavailable: the taskbar list could not start, which its first use already logged.
	if err := platform_api.window_set_progress(&app.platform, w.id, state, percent);
	   err != .None && err != .Unavailable {
		log.error("updating taskbar progress failed")
	}
}
