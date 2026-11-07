package main

import "aio:settings"
import "aio:term"
import "aio:ui"
import "core:fmt"
import "core:strings"
import "core:time"

// How AIODev presents each program status state (WORK-341): urgency, Activity section, attention,
// marks, notice kind, taskbar role and wording. Every surface classifies a record here.

// Lower ranks need the user sooner. Finished work the user has seen ranks below anything live.
Status_Rank :: enum u8 {
	Blocked,
	Failed,
	Done,
	Working,
	Idle,
	Failed_Seen,
	Done_Seen,
}

// The Activity panel's Dense sections. Its Needs_You excludes Done, which next-attention, the inbox
// pill and the picker count as needing the user.
Status_Section :: enum u8 {
	Needs_You,
	Working,
	Finished,
	Idle,
}

// What a record contributes to its window's taskbar button.
Status_Taskbar_Role :: enum u8 {
	None,
	Failed,
	Blocked,
	Working,
}

Status_Presentation :: struct {
	rank:      Status_Rank,
	section:   Status_Section,
	// Next-attention walks these, and the pill and picker count them as needing the user.
	attention: bool,
	// Finished work the user has looked at. Tab and pill marks leave it to the lists.
	seen:      bool,
	notice:    ui.Notice_Kind,
	taskbar:   Status_Taskbar_Role,
	mark:      ui.Status_Mark,
}

// One row per state; the compiler requires every state. `mark.urgent` inks a headline in the state's
// colour rather than muted, for blocked and failed work whether seen or not.
@(private, rodata)
STATUS_PRESENTATIONS := [term.Program_Status_State]Status_Presentation {
	.Idle       = {rank = .Idle, section = .Idle, notice = .Info, mark = {glyph = .Idle}},
	.Working    = {
		rank = .Working,
		section = .Working,
		notice = .Info,
		taskbar = .Working,
		mark = {glyph = .Working},
	},
	.Done       = {
		rank = .Done,
		section = .Finished,
		attention = true,
		notice = .Success,
		mark = {glyph = .Done},
	},
	.Blocked    = {
		rank = .Blocked,
		section = .Needs_You,
		attention = true,
		notice = .Warning,
		taskbar = .Blocked,
		mark = {glyph = .Blocked, urgent = true},
	},
	.Error      = {
		rank = .Failed,
		section = .Needs_You,
		attention = true,
		notice = .Error,
		taskbar = .Failed,
		mark = {glyph = .Error, urgent = true},
	},
	.Done_Seen  = {
		rank = .Done_Seen,
		section = .Finished,
		seen = true,
		notice = .Success,
		mark = {glyph = .Done},
	},
	.Error_Seen = {
		rank = .Failed_Seen,
		section = .Finished,
		seen = true,
		notice = .Error,
		mark = {glyph = .Error, urgent = true},
	},
}

// A blocked program's mark says what it needs.
@(private, rodata)
STATUS_BLOCKED_GLYPHS := [term.Program_Status_Kind]ui.Status_Glyph {
	.None       = .Blocked,
	.Permission = .Permission,
	.Question   = .Question,
	.Auth       = .Auth,
}

STATUS_EMPTY_TEXT :: "Nothing is reporting status."

@(private, rodata)
status_section_names := [Status_Section]string {
	.Needs_You = "Needs you",
	.Working   = "Working",
	.Finished  = "Finished",
	.Idle      = "Idle",
}

status_presentation :: proc(record: term.Program_Status) -> Status_Presentation {
	p := STATUS_PRESENTATIONS[record.state]
	if record.state == .Blocked {p.mark.glyph = STATUS_BLOCKED_GLYPHS[record.kind]}
	p.mark.progress, p.mark.dim = record.progress, p.seen
	return p
}

// More urgent first, then newer first.
status_before :: proc(a, b: term.Program_Status) -> bool {
	ra, rb := STATUS_PRESENTATIONS[a.state].rank, STATUS_PRESENTATIONS[b.state].rank
	if ra != rb {return ra < rb}
	return time.diff(b.updated_at, a.updated_at) > 0
}

// The settings that govern a state, the same for finished work whether seen or not.
@(private)
status_state_settings :: proc(
	s: ^settings.Status_Settings,
	state: term.Program_Status_State,
) -> (
	shown: bool,
	channels: settings.Status_Channels,
) {
	switch state {
	case .Idle:
		return s.show_idle, s.notify_idle
	case .Working:
		return s.show_working, s.notify_working
	case .Blocked:
		return s.show_blocked, s.notify_blocked
	case .Done, .Done_Seen:
		return s.show_done, s.notify_done
	case .Error, .Error_Seen:
		return s.show_error, s.notify_error
	}
	return false, {}
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
	shown, _ := status_state_settings(s, record.state)
	return shown && !status_app_ignored(s.ignore_apps, record.app)
}

// "40%" in `buffer`, which holds at least four bytes; progress is 0..100.
status_progress_text :: proc(progress: i8, buffer: []u8) -> string {
	n := int(progress)
	i := len(buffer)
	i -= 1
	buffer[i] = '%'
	for {
		i -= 1
		buffer[i] = u8('0' + n % 10)
		n /= 10
		if n == 0 {break}
	}
	return string(buffer[i:])
}

// A short label for the state: what a blocked program needs, or a percentage while working.
status_headline :: proc(mark: ui.Status_Mark, buffer: []u8) -> string {
	switch mark.glyph {
	case .None:
		return ""
	case .Idle:
		return "Idle"
	case .Working:
		if mark.progress >= 0 && len(buffer) >= 4 {return status_progress_text(mark.progress, buffer)}
		return "Working"
	case .Blocked:
		return "Needs you"
	case .Permission:
		return "Needs permission"
	case .Question:
		return "Has a question"
	case .Auth:
		return "Needs sign-in"
	case .Done:
		return "Done"
	case .Error:
		return "Failed"
	}
	return ""
}

// The workspace picker's summary of what a workspace's programs report.
status_picker_text :: proc(app: ^App, workspace: ^Workspace) -> string {
	if !app.settings.status.workspace_picker {return ""}
	summary := status_workspace_summary(app, workspace)
	@(static, rodata)
	ranks := [4]Status_Rank{.Blocked, .Failed, .Done, .Working}
	@(static, rodata)
	labels := [4]string{"need you", "failed", "done", "working"}
	parts: [4]string
	count := 0
	for rank, i in ranks {
		n := summary.counts[rank]
		if n == 0 {continue}
		// Only "need you" is a verb phrase that agrees with its count.
		parts[count] = fmt.tprintf("%d %s", n, n == 1 && rank == .Blocked ? "needs you" : labels[i])
		count += 1
	}
	return strings.join(parts[:count], " · ", context.temp_allocator)
}
