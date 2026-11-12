package main

import "aio:layout"
import "aio:render"
import "aio:ui"
import "core:log"

// What tab `index` of the window's workspace shows in the strip and in the rail: its title, the
// focused pane's content icon or program badge with the most telling other pane's stacked behind it,
// and its program status.
tab_tile :: proc(app: ^App, w: ^Window, index: int) -> (ui.Tab_Tile, render.Build_Status) {
	tab := w.workspace.tabs[index]
	status := status_tab_mark(app, w, w.workspace, index)
	t := ui.Tab_Tile {
		title        = tab_display_title(tab, index + 1),
		status       = status,
		status_phase = status_phase(app, w, status),
		status_slot  = app.settings.status.enabled && app.settings.status.tab_indicators,
		selected     = index == w.workspace.selected,
		marked       = tab_marked_shown(w, index),
	}
	front, has_front := layout.focused_content(&tab.tree)
	if !has_front {return t, .Ok}
	behind, stacked := tab_pane_behind(app, tab, index)
	size := (stacked ? ui.TAB_STACK_MARK : ui.ICON_BUTTON) * w.scale
	result: render.Build_Status
	t.badge, result = tab_content_badge(app, front, size)
	if result == .Ok && stacked {t.behind, result = tab_content_badge(app, behind.content, size)}
	return t, result
}

@(private = "file")
tab_content_badge :: proc(
	app: ^App,
	content: layout.Content,
	size: f32,
) -> (
	ui.Tab_Badge,
	render.Build_Status,
) {
	badge, result := content_badge(app, workspace_session_for_content(app, content), content.kind, size)
	return {icon = badge.icon, shell = badge.glyph, atlas = badge.atlas}, result
}

// How much a pane says about what its tab is for, least first.
Pane_Interest :: enum u8 {
	Shell,
	Document,
	Program,
	// A coding agent, or any program reporting its status.
	Agent,
}

@(private = "file")
pane_interest :: proc(app: ^App, pane: Workspace_Pane) -> Pane_Interest {
	entry := pane.session
	if !pane_owns_session(pane.content.kind) {return .Document}
	if entry == nil {return .Shell}
	for record in entry.statuses {if status_shown(app, record) {return .Agent}}
	program := program_adopted(entry)
	if program == nil {return .Shell}
	return program.launch.harness != .None ? .Agent : .Program
}

// The pane a tab with several panes stacks behind its focused one: the most telling of the others,
// then the one whose status comes first, then the first in the layout. False for a tab of one pane.
tab_pane_behind :: proc(app: ^App, tab: ^Tab, index: int) -> (best: Workspace_Pane, found: bool) {
	best_interest: Pane_Interest
	best_status: Status_Summary
	walk := workspace_tab_panes(app, &tab.tree, index)
	for pane, ok := workspace_pane_next(&walk); ok; pane, ok = workspace_pane_next(&walk) {
		if pane.node == tab.tree.focus {continue}
		interest := pane_interest(app, pane)
		status: Status_Summary
		status_summary_add(app, &status, pane.session)
		if found {
			if interest < best_interest {continue}
			if interest == best_interest &&
			   !(status.found && (!best_status.found || status_before(status.top, best_status.top))) {continue}
		}
		best, best_interest, best_status, found = pane, interest, status, true
	}
	return
}

// Tab presentation indexed by tab position: both arrays stay aligned with the workspace tab list. The
// strip's new-tab button and profile chevron keep their own controls.
Tab_Presentation :: struct {
	tab_controls:     [dynamic]ui.Control_Motion,
	tab_positions:    [dynamic]ui.Motion,
	new_tab_control:  ui.Control_Motion,
	profiles_control: ui.Control_Motion,
}

// The window's tab chrome beside the per-tab arrays, which Window embeds: the selection underline's
// motion, the strip control or rail row under the pointer, and a Close press held on a tab.
Tab_Chrome_State :: struct {
	tab_underline:   ui.Motion,
	tab_hover:       Tab_Chrome_Target,
	tab_close_armed: ui.Armed(int),
}

// The window shows its workspace afresh: the underline rests on the selected tab, and no hover or
// Close press carries over.
tab_chrome_reset :: proc(w: ^Window) {
	selected := f32(w.workspace.selected)
	w.tab_underline = {value = selected, target = selected}
	tab_chrome_forget_hover(w)
	ui.armed_cancel(&w.tab_close_armed)
}

// The tabs moved under the pointer: no control hovers, and a held press stops drawing pressed.
tab_chrome_forget_hover :: proc(w: ^Window) {
	w.tab_hover = nil
	gesture_tab_unpress(w)
}

tab_presentation_init :: proc(presentation: ^Tab_Presentation) {
	presentation.tab_controls = make([dynamic]ui.Control_Motion)
	presentation.tab_positions = make([dynamic]ui.Motion)
}

tab_presentation_destroy :: proc(presentation: ^Tab_Presentation) {
	delete(presentation.tab_controls)
	delete(presentation.tab_positions)
	presentation^ = {}
}

// Selection keeps the geometry and control storage until relayout reconciles it with a new
// workspace, so this resets the entries without releasing them.
tab_presentation_clear :: proc(presentation: ^Tab_Presentation) {
	clear(&presentation.tab_controls)
	clear(&presentation.tab_positions)
	presentation.new_tab_control, presentation.profiles_control = {}, {}
}

// Grows or shrinks both arrays to the tab count. Only entries beyond the previous length start
// at their own index, so reordering and resizing keep an animating position on its tab.
@(require_results)
tab_presentation_resize :: proc(presentation: ^Tab_Presentation, tab_count: int) -> bool {
	appended := len(presentation.tab_positions)
	if resize(&presentation.tab_controls, tab_count) != nil {return false}
	if resize(&presentation.tab_positions, tab_count) != nil {return false}
	for &position, i in presentation.tab_positions {
		if i < appended {continue}
		position.value, position.target = f32(i), f32(i)
	}
	return true
}

// Advances the window's tab motion: tabs easing into their slots, the ghost of tabs arriving from
// another window, the selection underline and the strip controls. True when the window must draw again.
tab_presentation_animate :: proc(app: ^App, w: ^Window, frame: ui.Frame_Time) -> bool {
	changed := false
	// D-069: dragged tabs follow the pointer (tab_drag_follow_pointer); the others, and every tab once
	// dropped, settle into their slots, opening the gap another window's drag asks for.
	following := tab_drag_active(w)
	for &position, i in w.tab_positions {
		if i >= len(w.workspace.tabs) {continue}
		if !following || !w.workspace.tabs[i].marked {
			gap := i >= w.tab_incoming.slot ? w.tab_incoming.count : 0
			ui.motion_target(&position, f32(i + gap), ui.REORDER_DURATION, .Decelerate, app.animations)
		}
		changed = ui.motion_update(&position, frame) || changed
	}
	changed = ui.motion_update(&w.tab_incoming.ghost, frame) || changed
	selected := f32(w.workspace.selected)
	ui.motion_target(&w.tab_underline, selected, ui.REORDER_DURATION, .Decelerate, app.animations)
	for &control, i in w.tab_controls {
		changed = tab_strip_control_update(app, w, &control, Tab_Chrome_Tab{i}, frame) || changed
	}
	changed = tab_strip_control_update(app, w, &w.new_tab_control, Tab_Chrome_New{}, frame) || changed
	changed = tab_strip_control_update(app, w, &w.profiles_control, Tab_Chrome_Profiles{}, frame) || changed
	return ui.motion_update(&w.tab_underline, frame) || changed
}

tab_presentation_animating :: proc(w: ^Window) -> bool {
	if ui.motion_active(w.tab_underline) || ui.motion_active(w.tab_incoming.ghost) {return true}
	for control in w.tab_controls {if ui.control_active(control) {return true}}
	if ui.control_active(w.new_tab_control) || ui.control_active(w.profiles_control) {return true}
	for position in w.tab_positions {if ui.motion_active(position) {return true}}
	return false
}

// A strip control hovers while the pointer is over it, and draws a held strip press while it hovers.
@(private = "file")
tab_strip_control_update :: proc(
	app: ^App,
	w: ^Window,
	control: ^ui.Control_Motion,
	target: Tab_Chrome_Target,
	frame: ui.Frame_Time,
) -> bool {
	hovered := w.tabs_horizontal && w.tab_hover == target
	pressed := hovered && gesture_tab_pressed(w) != nil
	return ui.control_update(control, hovered, pressed, app.animations, frame)
}

// Relayout fits the presentation to the tab count. Only the strip draws its hover and presses from the
// positions, so a count change while it shows forgets them. A failed resize leaves the arrays as they
// were: drawing and tab_presentation_animate bound every index by the tab count instead.
tab_presentation_fit :: proc(w: ^Window) {
	tab_count := w.workspace != nil ? len(w.workspace.tabs) : 0
	if tab_count != len(w.tab_positions) && w.tabs_horizontal {tab_chrome_forget_hover(w)}
	if !tab_presentation_resize(&w.presentation, tab_count) {
		log.error("resizing tab presentation values failed")
	}
}

@(require_results)
tab_presentation_reserve :: proc(presentation: ^Tab_Presentation, tab_count: int) -> bool {
	return reserve(&presentation.tab_controls, tab_count) == nil &&
		reserve(&presentation.tab_positions, tab_count) == nil
}

// Tabs arriving at `at` start settled in the gap opened for them, while the tabs after it keep their motion.
// Capacity was reserved. A window yet to lay out has nothing to shift; its next relayout sizes the arrays.
tab_presentation_insert :: proc(presentation: ^Tab_Presentation, at, count: int) {
	if at > len(presentation.tab_positions) {return}
	for i in 0 ..< count {
		place := f32(at + i)
		inject_at(&presentation.tab_controls, at + i, ui.Control_Motion{})
		inject_at(&presentation.tab_positions, at + i, ui.Motion{value = place, target = place})
	}
}

// Moves both presentation values with the tab, keeping every motion field it already has.
tab_presentation_move :: proc(presentation: ^Tab_Presentation, from, to: int) {
	if from == to || from < 0 || to < 0 {return}
	if from >= len(presentation.tab_positions) || to >= len(presentation.tab_positions) {return}
	control := presentation.tab_controls[from]
	position := presentation.tab_positions[from]
	ordered_remove(&presentation.tab_controls, from)
	ordered_remove(&presentation.tab_positions, from)
	inject_at(&presentation.tab_controls, to, control)
	inject_at(&presentation.tab_positions, to, position)
}

// Removes both presentation values for a closed tab.
tab_presentation_remove :: proc(presentation: ^Tab_Presentation, index: int) {
	if index < 0 {return}
	if index < len(presentation.tab_positions) {ordered_remove(&presentation.tab_positions, index)}
	if index < len(presentation.tab_controls) {ordered_remove(&presentation.tab_controls, index)}
}
