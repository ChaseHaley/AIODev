package main

import platform_api "aio:platform"
import "aio:glyphs"
import "aio:render"
import "aio:term"
import "aio:ui"
import "core:fmt"
import "core:log"
import "core:strings"
import "core:time"

// Program status (OSC 7501) as AIODev presents it. Each session's records are copied when they
// change, so drawing reads Session_Entry.statuses without taking the session lock. Only reports
// reach these surfaces; nothing is inferred from screen contents or titles.

@(private)
STATUS_SPIN_INTERVAL :: 80 * time.Millisecond
@(private)
STATUS_SPIN_PERIOD_MS :: 1200
// At most one notice per pane in this interval keeps a chatty program from flooding the notices.
@(private)
STATUS_NOTICE_INTERVAL :: 5 * time.Second
@(private)
STATUS_NOTICE_DURATION :: 8 * time.Second

Status_Summary :: struct {
	top:                                  term.Program_Status,
	session:                              u32,
	found:                                bool,
	blocked, failed, done, working, idle: int,
}

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
		term.set_program_status_enabled(entry.session, app.settings.status.enabled)
		status_refresh(app, &entry)
	}
	for w in app.windows {status_taskbar_update(app, w, true)}
	mark_all_dirty(app)
}

status_app_ignored :: proc(list, name: string) -> bool {
	if name == "" || list == "" {return false}
	rest := list
	for part in strings.split_iterator(&rest, ",") {
		if strings.equal_fold(strings.trim_space(part), name) {return true}
	}
	return false
}

status_shown :: proc(app: ^App, record: term.Program_Status) -> bool {
	s := &app.settings.status
	if !s.enabled {return false}
	shown := false
	switch record.state {
	case .Idle:
		shown = s.show_idle
	case .Working:
		shown = s.show_working
	case .Blocked:
		shown = s.show_blocked
	case .Done:
		shown = s.show_done
	case .Error:
		shown = s.show_error
	}
	return shown && !status_app_ignored(s.ignore_apps, record.app)
}

status_mark :: proc(record: term.Program_Status) -> ui.Status_Mark {
	glyph: ui.Status_Glyph
	switch record.state {
	case .Idle:
		glyph = .Idle
	case .Working:
		glyph = .Working
	case .Blocked:
		switch record.kind {
		case .None:
			glyph = .Blocked
		case .Permission:
			glyph = .Permission
		case .Question:
			glyph = .Question
		case .Auth:
			glyph = .Auth
		}
	case .Done:
		glyph = .Done
	case .Error:
		glyph = .Error
	}
	return {glyph, record.progress, record.seen}
}

// Lower ranks need the user sooner. Finished work the user has seen ranks below anything live.
status_rank :: proc(record: term.Program_Status) -> int {
	switch record.state {
	case .Blocked:
		return 0
	case .Error:
		return record.seen ? 5 : 1
	case .Done:
		return record.seen ? 6 : 2
	case .Working:
		return 3
	case .Idle:
		return 4
	}
	return 7
}

status_attention :: proc(record: term.Program_Status) -> bool {
	return status_rank(record) <= 2
}

@(private)
status_before :: proc(a, b: term.Program_Status) -> bool {
	ra, rb := status_rank(a), status_rank(b)
	if ra != rb {return ra < rb}
	return time.diff(b.updated_at, a.updated_at) > 0
}

status_summary_add :: proc(app: ^App, summary: ^Status_Summary, entry: ^Session_Entry) {
	if entry == nil {return}
	for record in entry.statuses {
		if !status_shown(app, record) {continue}
		switch record.state {
		case .Blocked:
			summary.blocked += 1
		case .Error:
			if !record.seen {summary.failed += 1}
		case .Done:
			if !record.seen {summary.done += 1}
		case .Working:
			summary.working += 1
		case .Idle:
			summary.idle += 1
		}
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

// The workspace picker's summary of what a workspace's programs report.
status_picker_text :: proc(app: ^App, workspace: ^Workspace) -> string {
	if !app.settings.status.workspace_picker {return ""}
	summary := status_workspace_summary(app, workspace)
	parts: [4]string
	count := 0
	counts := [4]int{summary.blocked, summary.failed, summary.done, summary.working}
	labels := [4]string{"need you", "failed", "done", "working"}
	for n, i in counts {
		if n == 0 {continue}
		parts[count] = fmt.tprintf("%d %s", n, n == 1 && i == 0 ? "needs you" : labels[i])
		count += 1
	}
	return strings.join(parts[:count], " · ", context.temp_allocator)
}

status_needs :: proc(summary: Status_Summary) -> int {
	return summary.blocked + summary.failed + summary.done
}

// The mark a tab or row shows for a summary. Finished work already seen is left to the lists.
status_indicator :: proc(summary: Status_Summary) -> (ui.Status_Mark, bool) {
	if !summary.found || status_rank(summary.top) >= 5 {return {}, false}
	return status_mark(summary.top), true
}

// The spinner position for a mark this frame draws. Drawing a spinner keeps the window repainting
// while system animations are on; a still spinner is drawn otherwise.
status_phase :: proc(app: ^App, w: ^Window, mark: ui.Status_Mark) -> f32 {
	if mark.glyph != .Working || mark.progress >= 0 || !app.animations {return 0}
	w.status_spinning = true
	elapsed := time.tick_now()._nsec / 1_000_000
	return f32(elapsed % STATUS_SPIN_PERIOD_MS) / STATUS_SPIN_PERIOD_MS
}

status_mark_draw :: proc(app: ^App, w: ^Window, area: render.Rect, mark: ui.Status_Mark) -> glyphs.Result {
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

// Repaints a window that drew a spinner at a low fixed rate; a window without one costs nothing.
status_spin_tick :: proc(w: ^Window, now: time.Tick) {
	if !w.status_spinning {
		w.status_spin_deadline = {}
		return
	}
	if w.status_spin_deadline == {} || time.tick_diff(w.status_spin_deadline, now) >= 0 {
		if w.status_spin_deadline != {} {w.dirty = true}
		w.status_spin_deadline = time.tick_add(now, STATUS_SPIN_INTERVAL)
	}
}

status_pane_title :: proc(entry: ^Session_Entry) -> string {
	return entry.name != "" ? entry.name : pane_header_title(&entry.header)
}

status_record_name :: proc(entry: ^Session_Entry, record: term.Program_Status) -> string {
	if record.title != "" {return record.title}
	if record.app != "" {return record.app}
	return status_pane_title(entry)
}

@(private)
status_tab_title :: proc(workspace: ^Workspace, tab: int) -> string {
	title := workspace.tabs[tab].title
	return title != "" ? title : fmt.tprintf("Tab %d", tab + 1)
}

// Where a session lives, for lists and notices that must say which pane they mean.
status_crumb :: proc(app: ^App, entry: ^Session_Entry) -> string {
	for workspace in app.workspaces {
		pane, ok := workspace_first_session(app, workspace, entry.id)
		if !ok {continue}
		tab := status_tab_title(workspace, pane.tab)
		if tab_pane_count(workspace.tabs[pane.tab]) > 1 {
			return fmt.tprintf("%s › %s › %s", workspace.name, tab, status_pane_title(entry))
		}
		return fmt.tprintf("%s › %s", workspace.name, tab)
	}
	return status_pane_title(entry)
}

status_workspace_of :: proc(app: ^App, session: u32) -> ^Workspace {
	for workspace in app.workspaces {
		if _, ok := workspace_first_session(app, workspace, session); ok {return workspace}
	}
	return nil
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
status_focus_leave :: proc(app: ^App, w: ^Window) {
	if app.settings.status.keep_finished != .Focus {return}
	if entry := focused_session(app, w); entry != nil {term.program_status_dismiss_finished(entry.session)}
}

@(private)
status_notify_wanted :: proc(app: ^App, record: term.Program_Status) -> bool {
	s := &app.settings.status
	#partial switch record.state {
	case .Blocked:
		return s.notify_blocked
	case .Error:
		return s.notify_error
	case .Done:
		return s.notify_done
	}
	return false
}

@(private)
status_notify_changes :: proc(app: ^App, entry: ^Session_Entry, previous: []term.Program_Status) {
	if !app.settings.status.enabled {return}
	for record in entry.statuses {
		if !status_notify_wanted(app, record) || !status_shown(app, record) {continue}
		changed := true
		for old in previous {
			if old.id == record.id {
				changed = old.state != record.state || old.kind != record.kind
				break
			}
		}
		if !changed || (!app.settings.status.notify_focused && status_watched(app, entry)) {continue}
		now := time.tick_now()
		if entry.status_notified != {} &&
		   time.tick_diff(entry.status_notified, now) < STATUS_NOTICE_INTERVAL {return}
		entry.status_notified = now
		status_notice(app, entry, record)
		return
	}
}

@(private)
status_notice :: proc(app: ^App, entry: ^Session_Entry, record: term.Program_Status) {
	buffer: [8]u8
	headline := ui.status_headline(status_mark(record), buffer[:])
	text := fmt.tprintf("%s: %s", status_record_name(entry, record), headline)
	if record.message != "" {text = fmt.tprintf("%s · %s", text, record.message)}
	text = fmt.tprintf("%s (%s)", text, status_crumb(app, entry))
	kind: ui.Notice_Kind = record.state == .Error ? .Error : record.state == .Done ? .Success : .Warning
	ui.notices_put(&app.notices, u32(Notice_Key.Program_Status), kind, text, STATUS_NOTICE_DURATION)
	mark_all_dirty(app)
	target := window_for_workspace(app, status_workspace_of(app, entry.id))
	if target == nil && len(app.windows) > 0 {target = app.windows[0]}
	if target != nil && !target.focused &&
	   platform_api.window_flash(&app.platform, target.id) != .None {
		log.error("flashing the window for program status failed")
	}
}

// Shows the pane a record came from, switching workspace, tab and focus as needed.
status_reveal :: proc(app: ^App, w: ^Window, session: u32) -> bool {
	for workspace in app.workspaces {
		if !workspace_eligible(app, workspace) {continue}
		pane, ok := workspace_first_session(app, workspace, session)
		if !ok {continue}
		if !workspace_select(app, w, workspace) {return false}
		owner := window_for_workspace(app, workspace)
		if owner == nil {return false}
		if owner.workspace.selected != pane.tab {tab_select(app, owner, pane.tab)}
		pane_focus(app, owner, pane.node)
		status_focus_enter(app, owner)
		owner.dirty = true
		return true
	}
	return false
}

status_in_scope :: proc(app: ^App, w: ^Window, workspace: ^Workspace) -> bool {
	return app.settings.status.scope == .All || workspace == w.workspace
}

// Moves to the most urgent record that needs the user, skipping the pane already in view so
// repeating the command walks the queue.
status_next_attention :: proc(app: ^App, w: ^Window) {
	current := focused_session(app, w)
	best: term.Program_Status
	session: u32
	found := false
	for workspace in app.workspaces {
		if !workspace_eligible(app, workspace) || !status_in_scope(app, w, workspace) {continue}
		walk := workspace_session_panes(app, workspace)
		for pane, ok := workspace_pane_next(&walk); ok; pane, ok = workspace_pane_next(&walk) {
			entry := pane.session
			if entry == nil || entry == current {continue}
			for record in entry.statuses {
				if !status_shown(app, record) || !status_attention(record) {continue}
				if !found || status_before(record, best) {
					best, session, found = record, entry.id, true
				}
			}
		}
	}
	if !found {
		notify(app, .Info, "No program needs you.")
		return
	}
	if !status_reveal(app, w, session) {notify(app, .Error, "Could not show that pane.")}
}

// Dismisses finished work everywhere in the window's overview scope.
status_dismiss_finished :: proc(app: ^App, w: ^Window) {
	for workspace in app.workspaces {
		if !status_in_scope(app, w, workspace) {continue}
		walk := workspace_session_panes(app, workspace)
		for pane, ok := workspace_pane_next(&walk); ok; pane, ok = workspace_pane_next(&walk) {
			if pane.session != nil {term.program_status_dismiss_finished(pane.session.session, true)}
		}
	}
}

// Mirrors the window's workspace on its taskbar button: failures, then blocked work, then the
// least advanced job. Only a change reaches the shell.
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
				#partial switch record.state {
				case .Error:
					failed ||= !record.seen
				case .Blocked:
					blocked = true
				case .Working:
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
	if !force && state == w.taskbar_state && percent == w.taskbar_percent {return}
	w.taskbar_state, w.taskbar_percent = state, percent
	if platform_api.window_set_progress(&app.platform, w.id, state, percent) != .None {
		log.error("updating taskbar progress failed")
	}
}
