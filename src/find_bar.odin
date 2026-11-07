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

// Opens find, gives an open bar back the keyboard, or closes a bar that has it.
find_toggle :: proc(app: ^App, w: ^Window, target: Find_Target) {
	t := app.settings.terminal
	switch {
	case !ui.find_is_open(&w.find):
		ui.find_open(&w.find, &app.find_history, t.find_keep_query, t.find_select_query)
		on_find_outcome(app, w, target, .Changed)
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

find_options :: proc(w: ^Window) -> search.Options {
	return {case_sensitive = w.find.case_sensitive, regex = w.find.regex}
}

on_find_outcome :: proc(app: ^App, w: ^Window, target: Find_Target, outcome: ui.Find_Outcome) {
	if outcome == .None {
		return
	}
	w.dirty = true
	if target == nil {
		return
	}
	step: search.Step
	switch outcome {
	case .None, .Moved, .Case_Toggle, .Regex_Toggle, .Close:
		return
	case .Changed:
		find_target_set(target, ui.field_string(&w.find.query), find_options(w))
		return
	case .Closed:
		find_close(app, w, target)
		return
	case .Next:
		step = .Next
	case .Previous:
		step = .Previous
	case .Up:
		step = .Up
	case .Down:
		step = .Down
	}
	ui.find_history_add(&app.find_history, &w.find)
	// A terminal reads from its newest line up and a document from its first line down, so Enter
	// follows the target's reading order while the bar's arrows always point the way they move.
	summary, _ := find_target_summary(target)
	find_target_select(w, target, search.moves_up(summary.order, step))
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
	if outcome == .Closed {key_suppress(w, e)}
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
