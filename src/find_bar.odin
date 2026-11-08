package main

import "aio:input"
import "aio:markdown"
import "aio:platform"
import "aio:search"
import "aio:term"
import "aio:ui"
import "core:fmt"
import "core:strings"

// Pastes the clipboard's first line into the find bar.
find_paste :: proc(app: ^App, w: ^Window) {
	text, ok := platform.clipboard_get_text(&app.platform, context.temp_allocator)
	if !ok || len(text) == 0 {
		return
	}
	line := text
	if end := strings.index_any(text, "\r\n"); end >= 0 {
		line = text[:end]
	}
	on_find_outcome(app, w, find_target(app, w), ui.find_text(&w.find, line))
}

// What the window's find bar searches: whatever its focused pane shows.
Find_Target :: union {
	^Session_Entry,
	^Markdown_Pane,
}

@(require_results)
find_target :: proc(app: ^App, w: ^Window) -> Find_Target {
	if pane := markdown_focused(app, w); pane != nil {return pane}
	if entry := focused_session(app, w); entry != nil {return entry}
	return nil
}

@(private)
find_target_set :: proc(target: Find_Target, needle: string, options: search.Options = {}) {
	switch t in target {
	case ^Session_Entry:
		if t != nil {term.search_set_needle(t.session, needle, options)}
	case ^Markdown_Pane:
		if t != nil {markdown.search_set(&t.search, needle, options)}
	}
}

// Moves the target's selection up or down the screen; each backend wraps at either end.
@(private)
find_target_select :: proc(w: ^Window, target: Find_Target, up: bool) {
	switch t in target {
	case ^Session_Entry:
		if t != nil {term.search_select(t.session, up)}
	case ^Markdown_Pane:
		if t != nil {markdown_find_select(w, t, up)}
	}
}

@(require_results)
find_target_summary :: proc(target: Find_Target) -> (summary: search.Summary, ok: bool) {
	switch t in target {
	case ^Session_Entry:
		if t != nil {return term.search_summary(t.session), true}
	case ^Markdown_Pane:
		if t != nil {return markdown_find_summary(t), true}
	}
	return {}, false
}

// Both scanners participate in the same wake and update policy. A document that is missing or
// unreadable waits for a successful reload before its search can continue.
@(private)
find_target_pending :: proc(target: Find_Target) -> bool {
	switch t in target {
	case ^Session_Entry:
		return t != nil && term.search_pending(t.session)
	case ^Markdown_Pane:
		return t != nil && markdown_document(t) != nil && markdown.search_pending(&t.search)
	}
	return false
}

@(require_results)
find_pending :: proc(app: ^App) -> bool {
	for &entry in app.sessions {if find_target_pending(&entry) {return true}}
	for pane in app.markdown_panes {if find_target_pending(pane) {return true}}
	return false
}

@(private)
find_target_tick :: proc(app: ^App, target: Find_Target) {
	if !find_target_pending(target) {return}
	before, _ := find_target_summary(target)
	switch t in target {
	case ^Session_Entry:
		term.search_update(t.session)
	case ^Markdown_Pane:
		markdown.search_update(&t.search, markdown_document(t), search.STEP_BUDGET)
	}
	after, _ := find_target_summary(target)
	if after != before {mark_all_dirty(app)}
}

find_tick :: proc(app: ^App) {
	for &entry in app.sessions {find_target_tick(app, &entry)}
	for pane in app.markdown_panes {find_target_tick(app, pane)}
}

// Opens find, gives an open bar back the keyboard, or closes a bar that has it.
find_toggle :: proc(app: ^App, w: ^Window, target: Find_Target) {
	t := app.settings.terminal
	switch {
	case !ui.find_is_open(&w.find):
		ui.find_open(&w.find, &app.find_history, t.find_keep_query, t.find_select_query)
		on_find_outcome(app, w, target, ui.Find_Change.Changed)
	case !ui.find_has_keyboard(&w.find):
		ui.find_focus(&w.find, t.find_select_query)
	case:
		find_close(app, w, target)
	}
	w.dirty = true
}

// Ends the search and leaves the viewport where the search put it.
find_close :: proc(app: ^App, w: ^Window, target: Find_Target) {
	ui.find_close(&w.find, &app.find_history)
	w.dirty = true
	find_target_set(target, "")
}

on_find_outcome :: proc(app: ^App, w: ^Window, target: Find_Target, outcome: ui.Find_Outcome) {
	switch change in outcome {
	case ui.Find_Change:
		if change == .None {return}
		w.dirty = true
		if target == nil {return}
		switch change {
		case .None, .Moved:
		case .Changed:
			find_target_set(target, ui.field_string(&w.find.query), w.find.options)
		case .Closed:
			find_close(app, w, target)
		}
	case search.Step:
		w.dirty = true
		if target == nil {return}
		ui.find_history_add(&app.find_history, &w.find)
		// Enter follows the target's reading order; the bar's arrows always move up or down.
		summary, _ := find_target_summary(target)
		find_target_select(w, target, search.moves_up(summary.order, change))
	}
}

// A key while the bar has the keyboard edits the query; none reach the pane.
find_bar_key :: proc(app: ^App, w: ^Window, e, logical: input.Key_Event) {
	outcome: ui.Find_Outcome
	switch clipboard_chord(logical) {
	case .Copy:
		clipboard_copy(app, ui.field_selected_text(&w.find.query))
	case .Cut:
		if clipboard_copy(app, ui.field_selected_text(&w.find.query)) {outcome = ui.find_text(&w.find, "")}
	case .Paste:
		find_paste(app, w)
	case .None:
		outcome = ui.find_key(&w.find, logical, &app.find_history)
	}
	if outcome == ui.Find_Outcome(ui.Find_Change.Closed) {key_suppress(w, e)}
	on_find_outcome(app, w, find_target(app, w), outcome)
}

// The find bar's match count: "3 of 17" once a match is selected. A search that failed has found nothing.
find_presentation :: proc(w: ^Window, target: Find_Target) -> (label: string, enabled: bool) {
	s, ok := find_target_summary(target)
	if !ok || len(w.find.query.bytes) == 0 { return "0 of 0", false }
	switch s.progress {
	case .Invalid:
		return "Invalid expression", false
	case .Searching:
		return fmt.tprintf("%d of %d · Searching…", s.selected + 1, s.total), s.total > 0
	case .Off, .Complete, .Failed:
	}
	if s.total == 0 { return "0 of 0", false }
	return fmt.tprintf("%d of %d", s.selected + 1, s.total), true
}

find_controls :: proc(w: ^Window, target: Find_Target) -> (l: ui.Find_Layout, enabled: bool) {
	label, available := find_presentation(w, target)
	text := ui.text_styled(&w.ui_text, .Detail)
	return ui.find_layout(f32(w.width), w.scale, ui.text_width(&text, label)), available
}

when AIO_CONTROL {
	// The find bar's keys. find.count is the bar's own label; find.matches keeps the earlier wording
	// ("1 match", "N matches") that live journeys check, from the same summary.
	find_bar_state_report :: proc(r: ^State_Report, app: ^App, w: ^Window) {
		target := find_target(app, w)
		label, _ := find_presentation(w, target)
		matches := ""
		if s, ok := find_target_summary(target); ok && len(w.find.query.bytes) > 0 {
			switch {
			case s.selected >= 0: matches = fmt.tprintf("%d of %d", s.selected + 1, s.total)
			case s.total == 1: matches = "1 match"
			case s.total > 0: matches = fmt.tprintf("%d matches", s.total)
			case s.progress == .Searching: matches = "Searching…"
			case: matches = "No matches"
			}
		}
		open := ui.find_is_open(&w.find)
		state_value(r, "find.open", open)
		state_value(r, "find.focused", ui.find_has_keyboard(&w.find))
		state_value(r, "find.case_sensitive", w.find.options.case_sensitive)
		state_value(r, "find.regex", w.find.options.regex)
		state_text(r, "find.query", ui.field_string(&w.find.query))
		state_text(r, "find.matches", matches)
		state_text(r, "find.count", label)
		if open {
			controls, _ := find_controls(w, target)
			state_rect(r, "find.older", controls.up)
			state_rect(r, "find.newer", controls.down)
			state_rect(r, "find.close", controls.close)
		} else {
			state_text(r, "find.older", "")
			state_text(r, "find.newer", "")
			state_text(r, "find.close", "")
		}
	}
}

// Find bar pointer surface

@(private)
find_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	if !ui.find_is_open(&w.find) {return false}
	l, _ := find_controls(w, find_target(app, w))
	return ui.find_contains(l, x, y)
}

@(private)
find_pointer_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: input.Mouse_Move_Event) {
	if owner != .Find || !ui.find_is_open(&w.find) {
		if w.find.hover != .None {w.find.hover, w.dirty = .None, true}
		if owner == .Find {pointer_set(app, w, .Arrow)}
		return
	}
	x, y := f32(e.x), f32(e.y)
	l, available := find_controls(w, find_target(app, w))
	if ui.find_hover(&w.find, l, available, x, y) {w.dirty = true}
	pointer_set(app, w, ui.find_pointer(l, available, x, y))
}

@(private)
find_tooltip :: proc(_: ^App, w: ^Window, _, _: f32) -> string {
	#partial switch w.find.hover {
	case .Case_Toggle: return "Match case"
	case .Regex_Toggle: return "Use regular expression"
	case .Up: return "Previous match"
	case .Down: return "Next match"
	case .Close: return "Close find"
	case:
	}
	return ""
}

@(private)
find_pointer_cancel :: proc(_: ^App, w: ^Window) {
	ui.armed_cancel(&w.find.armed)
	w.find.hover = .None
}

@(private)
find_press :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) {
	target := find_target(app, w)
	l, enabled := find_controls(w, target)
	on_find_outcome(app, w, target, ui.find_mouse(&w.find, l, enabled, e.button, true, f32(e.x), f32(e.y)))
}

@(private)
find_release :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) -> bool {
	if e.button != .Left || !ui.find_is_open(&w.find) || !ui.armed_down(w.find.armed) {return false}
	target := find_target(app, w)
	l, enabled := find_controls(w, target)
	on_find_outcome(app, w, target, ui.find_mouse(&w.find, l, enabled, e.button, false, f32(e.x), f32(e.y)))
	return true
}

@(private)
find_leave :: proc(_: ^App, w: ^Window) {
	w.find.hover = .None
}
