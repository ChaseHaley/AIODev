package main

import "aio:layout"
import "aio:render"
import "aio:ui"
import "core:log"

// What tab `index` of the window's workspace shows in the strip and in the rail: its title, the
// focused pane's content icon or program badge with the most telling other pane's stacked behind it,
// its program status, and its label's turn while focus moves between its panes (tab_label.odin).
tab_tile :: proc(app: ^App, w: ^Window, index: int) -> (ui.Tab_Tile, render.Build_Status) {
	tab := w.workspace.tabs[index]
	status := status_tab_mark(app, w, w.workspace, index)
	t := ui.Tab_Tile {
		title        = tab_display_title(tab, index + 1),
		status       = status,
		status_phase = status_phase(app, w, status),
		status_slot  = app.settings.status.enabled && .Tabs in app.settings.status.surfaces,
		selected     = index == w.workspace.selected,
		marked       = tab_marked_shown(w, index),
	}
	t.tray, t.tray_ends = tab_tray(app, w, index)
	t.tray_state = tab_group_state(w, tab_laid_group(w, index))
	front, has_front := layout.focused_content(&tab.tree)
	if !has_front {return t, .Ok}
	behind, stacked := tab_pane_behind(app, tab, index)
	result: render.Build_Status
	t.badge, t.behind, result = tab_marks(app, w, front, behind.content, stacked)
	if result != .Ok {return t, result}
	back: Maybe(layout.Content)
	if stacked {back = behind.content}
	return t, tab_label_turn_shown(app, w, index, front, back, &t)
}

// The badges of a label showing `front`, stacked over `behind` when `stacked`.
tab_marks :: proc(
	app: ^App,
	w: ^Window,
	front, behind: layout.Content,
	stacked: bool,
) -> (
	badge, back: ui.Tab_Badge,
	result: render.Build_Status,
) {
	size := (stacked ? ui.TAB_STACK_MARK : ui.ICON_BUTTON) * w.scale
	badge = tab_content_badge(app, front, size) or_return
	if stacked {back = tab_content_badge(app, behind, size) or_return}
	return
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
	badge, result := content_badge(app, workspace_session_for_content(app, content), content, size)
	return {icon = badge.icon, shell = badge.glyph, atlas = badge.atlas, pane = pane_motion_key(content)}, result
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

// A tab's hover and press motion in the strip, by the tab's id, so it stays with the tab wherever the tab
// moves.
Tab_Control :: struct {
	id:      u32,
	control: ui.Control_Motion,
}

// Tab presentation. Positions and offsets are indexed by tab position and stay aligned with the workspace tab
// list; hover and press motion is keyed by tab id. The strip's new-tab button and profile chevron keep their
// own controls.
Tab_Presentation :: struct {
	// The motion of each tab hovered or pressed, or easing back to rest after it, in no particular order. A
	// tab at rest has no entry.
	tab_controls:     [dynamic]Tab_Control,
	// Each tab's place in slots: strip tab widths, or rail rows.
	tab_positions:    [dynamic]ui.Motion,
	// Each tab's strip offset in DIPs, for the group chips before it.
	tab_offsets:      [dynamic]ui.Motion,
	// What each tab's label shows and how it turns, by the tab's id, in no particular order; see Tab_Label.
	tab_labels:       [dynamic]Tab_Label,
	new_tab_control:  ui.Control_Motion,
	profiles_control: ui.Control_Motion,
	// The orientation the motions last aimed for, none before the first. Slots mean different things in the
	// strip and the rail.
	horizontal:       Maybe(bool),
	// The next update puts every tab straight in its place instead of easing it there: after a change of
	// orientation or workspace.
	jump:             bool,
	// The group whose tabs are sliding into or out of its chip, until they rest, and how open it is on the
	// way, 1 open to 0 folded, which the rail's tray follows as it gathers into the chip. While it folds, the
	// strip's tab width and end and the rail's footer, in pixels, ease from where they were with the tabs.
	folding:          u32,
	fold:             ui.Motion,
	strip_width:      ui.Motion,
	strip_end:        ui.Motion,
	rail_footer:      ui.Motion,
}

// The window's tab chrome beside the per-tab arrays, which Window embeds: the selection underline's
// motion, the strip control or rail row under the pointer, and a Close press held on a tab, by tab id.
Tab_Chrome_State :: struct {
	tab_underline:        ui.Motion,
	// The underline's strip offset in DIPs, as tab_offsets.
	tab_underline_offset: ui.Motion,
	tab_hover:            Tab_Chrome_Target,
	tab_close_armed:      ui.Armed(u32),
}

// The window shows its workspace afresh: the underline rests on the selected tab, and no hover or
// Close press carries over.
tab_chrome_reset :: proc(w: ^Window) {
	selected := f32(w.workspace.selected)
	w.tab_underline = {value = selected, target = selected}
	w.presentation.jump = true
	tab_chrome_forget_hover(w)
	ui.armed_cancel(&w.tab_close_armed)
}

// The tabs moved under the pointer: no control hovers, and a held press stops drawing pressed.
tab_chrome_forget_hover :: proc(w: ^Window) {
	w.tab_hover = nil
	gesture_tab_unpress(w)
}

tab_presentation_init :: proc(presentation: ^Tab_Presentation) {
	presentation.tab_controls = make([dynamic]Tab_Control)
	presentation.tab_positions = make([dynamic]ui.Motion)
	presentation.tab_offsets = make([dynamic]ui.Motion)
	presentation.tab_labels = make([dynamic]Tab_Label)
}

tab_presentation_destroy :: proc(presentation: ^Tab_Presentation) {
	delete(presentation.tab_controls)
	delete(presentation.tab_positions)
	delete(presentation.tab_offsets)
	delete(presentation.tab_labels)
	presentation^ = {}
}

// Selection keeps the geometry and control storage until relayout reconciles it with a new
// workspace, so this resets the entries without releasing them.
tab_presentation_clear :: proc(presentation: ^Tab_Presentation) {
	clear(&presentation.tab_controls)
	clear(&presentation.tab_positions)
	clear(&presentation.tab_offsets)
	clear(&presentation.tab_labels)
	presentation.new_tab_control, presentation.profiles_control = {}, {}
}

// Grows or shrinks the position arrays to the tab count. Only entries beyond the previous length start at
// their own index, so reordering and resizing keep an animating position on its tab.
@(require_results)
tab_presentation_resize :: proc(presentation: ^Tab_Presentation, tab_count: int) -> bool {
	appended := len(presentation.tab_positions)
	if resize(&presentation.tab_positions, tab_count) != nil {return false}
	if resize(&presentation.tab_offsets, tab_count) != nil {return false}
	for &position, i in presentation.tab_positions {
		if i < appended {continue}
		position.value, position.target = f32(i), f32(i)
		presentation.tab_offsets[i] = {}
	}
	return true
}

// Advances the window's tab motion: tabs easing into their slots, the ghost of tabs arriving from
// another window, the selection underline, the strip controls and labels turning to another pane. True when
// the window must draw again.
tab_presentation_animate :: proc(app: ^App, w: ^Window, frame: ui.Frame_Time) -> bool {
	changed := false
	if shown, aimed := w.presentation.horizontal.?; aimed && shown != w.tabs_horizontal {
		w.presentation.jump = true
	}
	w.presentation.horizontal = w.tabs_horizontal
	animate := app.animations && !w.presentation.jump
	w.presentation.jump = false
	layout := tab_layout(app, w, w.tabs_horizontal)
	// D-069: dragged tabs follow the pointer (tab_drag_follow_pointer); the others, and every tab once
	// dropped, settle into their slots, opening the gap another window's drag asks for.
	following := tab_drag_active(w)
	for &position, i in w.tab_positions {
		if i >= len(layout.places) || i >= len(w.tab_offsets) {continue}
		offset := &w.tab_offsets[i]
		if !following || !w.workspace.tabs[i].marked {
			gap := i >= w.tab_incoming.slot ? w.tab_incoming.count : 0
			place := layout.places[i]
			ui.motion_target(&position, place.slot + f32(gap), ui.REORDER_DURATION, .Decelerate, animate)
			ui.motion_target(offset, place.offset, ui.REORDER_DURATION, .Decelerate, animate)
		}
		changed = ui.motion_update(&position, frame) || changed
		changed = ui.motion_update(offset, frame) || changed
	}
	if group := tab_group_find(w.workspace, w.folding); group != nil {
		ui.motion_target(&w.fold, group.folded ? 0 : 1, ui.REORDER_DURATION, .Decelerate, animate)
	}
	changed = ui.motion_update(&w.fold, frame) || changed
	changed = tab_fold_room_animate(app, w, frame, animate) || changed
	changed = rail_scroll_animate(app, w, frame) || changed
	if !tab_presentation_animating(w) {w.folding = 0}
	changed = ui.motion_update(&w.tab_incoming.ghost, frame) || changed
	if selected := w.workspace.selected; selected >= 0 && selected < len(layout.places) {
		place := layout.places[selected]
		ui.motion_target(&w.tab_underline, place.slot, ui.REORDER_DURATION, .Decelerate, animate)
		ui.motion_target(&w.tab_underline_offset, place.offset, ui.REORDER_DURATION, .Decelerate, animate)
	}
	changed = tab_controls_update(app, w, frame) || changed
	changed = tab_strip_control_update(app, w, &w.new_tab_control, Tab_Chrome_New{}, frame) || changed
	changed = tab_strip_control_update(app, w, &w.profiles_control, Tab_Chrome_Profiles{}, frame) || changed
	changed = ui.motion_update(&w.tab_underline_offset, frame) || changed
	changed = tab_labels_update(app, w, frame, animate) || changed
	return ui.motion_update(&w.tab_underline, frame) || changed
}

tab_presentation_animating :: proc(w: ^Window) -> bool {
	if ui.motion_active(w.tab_underline) || ui.motion_active(w.tab_incoming.ghost) {return true}
	if ui.motion_active(w.fold) || ui.motion_active(w.strip_width) || ui.motion_active(w.strip_end) {return true}
	if ui.motion_active(w.rail_footer) {return true}
	if ui.motion_active(w.tab_underline_offset) {return true}
	for entry in w.tab_controls {if ui.control_active(entry.control) {return true}}
	if ui.control_active(w.new_tab_control) || ui.control_active(w.profiles_control) {return true}
	for position in w.tab_positions {if ui.motion_active(position) {return true}}
	for offset in w.tab_offsets {if ui.motion_active(offset) {return true}}
	return tab_labels_turning(w)
}

// Holds the strip's tab width and end, or the rail's footer, where they show now, so a fold starting eases
// them from there to where the tabs will rest (WORK-454); the other layout's are cleared.
tab_fold_room_hold :: proc(app: ^App, w: ^Window) {
	if w.tabs_horizontal {
		bar := window_tab_bar(app, w)
		w.strip_width = {value = bar.tab_width, target = bar.tab_width}
		w.strip_end = {value = bar.end, target = bar.end}
		w.rail_footer = {}
		return
	}
	w.strip_width, w.strip_end = {}, {}
	layout, ok := rail_layout_query(w)
	footer := ok ? layout.footer.y - layout.area.y : 0
	w.rail_footer = {value = footer, target = footer}
}

// Eases the strip's tab width and end, or the rail's footer, to where they rest, while a group folds.
@(private = "file")
tab_fold_room_animate :: proc(app: ^App, w: ^Window, frame: ui.Frame_Time, animate: bool) -> bool {
	if w.folding == 0 {return false}
	if w.tabs_horizontal {
		rest := window_tab_bar_rest(app, w)
		ui.motion_target(&w.strip_width, rest.tab_width, ui.REORDER_DURATION, .Decelerate, animate)
		ui.motion_target(&w.strip_end, rest.end, ui.REORDER_DURATION, .Decelerate, animate)
		width := ui.motion_update(&w.strip_width, frame)
		return ui.motion_update(&w.strip_end, frame) || width
	}
	rest, ok := rail_layout_rest(w)
	if !ok {return false}
	ui.motion_target(&w.rail_footer, rest.footer.y - rest.area.y, ui.REORDER_DURATION, .Decelerate, animate)
	return ui.motion_update(&w.rail_footer, frame)
}

// The motion tab `id` draws its hover and press with, or nil while it rests.
tab_control_find :: proc(presentation: ^Tab_Presentation, id: u32) -> ^Tab_Control {
	for &entry in presentation.tab_controls {if entry.id == id {return &entry}}
	return nil
}

// Eases each tab's hover and press by the tab's id. The hovered tab gains an entry, and an entry goes once
// its motion rests at zero, so a tab that closed or left the workspace takes its entry with it.
@(private = "file")
tab_controls_update :: proc(app: ^App, w: ^Window, frame: ui.Frame_Time) -> bool {
	hovered, on_tab := w.tab_hover.(Tab_Chrome_Tab)
	if on_tab && w.tabs_horizontal && tab_control_find(&w.presentation, hovered.id) == nil {
		if _, err := append(&w.tab_controls, Tab_Control{id = hovered.id}); err != nil {
			log.error("adding a tab's hover motion failed")
		}
	}
	changed := false
	#reverse for &entry, i in w.tab_controls {
		changed = tab_strip_control_update(app, w, &entry.control, Tab_Chrome_Tab{entry.id}, frame) || changed
		c := entry.control
		if !ui.control_active(c) && c.hover.value == 0 && c.press.value == 0 {unordered_remove(&w.tab_controls, i)}
	}
	return changed
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

// Relayout fits the positions to the tab count, with tabs that arrived resting in their places. A count
// change while the strip shows moves tabs under a still pointer, so the strip forgets its hover and press
// until the pointer moves. A failed resize leaves the arrays as they were: drawing and
// tab_presentation_animate bound every index by the tab count instead.
tab_presentation_fit :: proc(app: ^App, w: ^Window) {
	tab_count := w.workspace != nil ? len(w.workspace.tabs) : 0
	appended := len(w.tab_positions)
	if tab_count != appended && w.tabs_horizontal {tab_chrome_forget_hover(w)}
	if !tab_presentation_resize(&w.presentation, tab_count) {
		log.error("resizing tab presentation values failed")
		return
	}
	if appended >= tab_count {return}
	places := tab_layout(app, w, w.tabs_horizontal).places
	for i in appended ..< min(tab_count, len(places)) {
		w.tab_positions[i] = {value = places[i].slot, target = places[i].slot}
		w.tab_offsets[i] = {value = places[i].offset, target = places[i].offset}
	}
}

@(require_results)
tab_presentation_reserve :: proc(presentation: ^Tab_Presentation, tab_count: int) -> bool {
	return reserve(&presentation.tab_positions, tab_count) == nil &&
		reserve(&presentation.tab_offsets, tab_count) == nil
}

// Tabs arriving at `at` start settled in the gap opened for them, while the tabs after it keep their motion.
// Capacity was reserved. A window yet to lay out has nothing to shift; its next relayout sizes the arrays.
tab_presentation_insert :: proc(presentation: ^Tab_Presentation, at, count: int) {
	if at > len(presentation.tab_positions) {return}
	for i in 0 ..< count {
		place := f32(at + i)
		inject_at(&presentation.tab_positions, at + i, ui.Motion{value = place, target = place})
		offset := at + i > 0 ? presentation.tab_offsets[at + i - 1] : ui.Motion{}
		inject_at(&presentation.tab_offsets, at + i, ui.Motion{value = offset.value, target = offset.target})
	}
}

// Moves the position values with the tab, keeping every motion field they already have. Hover and press
// motion follow the tab by id and need no move.
tab_presentation_move :: proc(presentation: ^Tab_Presentation, from, to: int) {
	if from == to || from < 0 || to < 0 {return}
	if from >= len(presentation.tab_positions) || to >= len(presentation.tab_positions) {return}
	if from >= len(presentation.tab_offsets) || to >= len(presentation.tab_offsets) {return}
	position := presentation.tab_positions[from]
	offset := presentation.tab_offsets[from]
	ordered_remove(&presentation.tab_positions, from)
	ordered_remove(&presentation.tab_offsets, from)
	inject_at(&presentation.tab_positions, to, position)
	inject_at(&presentation.tab_offsets, to, offset)
}

// Removes the position values for a closed tab. Its hover motion, keyed by id, eases out on its own.
tab_presentation_remove :: proc(presentation: ^Tab_Presentation, index: int) {
	if index < 0 {return}
	if index < len(presentation.tab_positions) {ordered_remove(&presentation.tab_positions, index)}
	if index < len(presentation.tab_offsets) {ordered_remove(&presentation.tab_offsets, index)}
}
