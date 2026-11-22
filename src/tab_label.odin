package main

import "aio:layout"
import "cosmos:render"
import "aio:settings"
import "aio:ui"
import "core:log"

// A tab's label, by the tab's id: the focused pane it shows, and its turn while focus moves to another of the
// tab's panes (WORK-483). The label turns from what it showed to the pane focus moved to: its marks swivel
// and its title slides the way a Zoom view slides between the two panes (pane_side), with the Tab Label
// motion settings. A tab seen for the first time, as after a workspace switch or in a new window, shows its
// label without turning, and switching tabs turns nothing, as no tab's focus moves.
Tab_Label :: struct {
	id:          u32,
	// The focused pane the label shows, and the pane its last draw stacked behind it.
	front:       layout.Content,
	behind:      Maybe(layout.Content),
	// The pane the label turns away from, with the pane stacked behind it then.
	from:        layout.Content,
	from_behind: Maybe(layout.Content),
	// See ui.Tab_Turn.
	toward:      [2]f32,
	start:       [2]f32,
	// The turn's progress from 0 to 1, still when the label rests.
	turn:        ui.Motion,
	// The latest update found the tab in the workspace; a tab gone takes its label with it.
	seen:        bool,
}

tab_label_find :: proc(w: ^Window, id: u32) -> ^Tab_Label {
	for &label in w.tab_labels {if label.id == id {return &label}}
	return nil
}

tab_labels_turning :: proc(w: ^Window) -> bool {
	for label in w.tab_labels {if ui.motion_active(label.turn) {return true}}
	return false
}

// Turns the label of each tab whose focus moved since the last update, then advances every turn; true when
// one moved. A tab seen for the first time gains a label at rest.
tab_labels_update :: proc(app: ^App, w: ^Window, frame: ui.Frame_Time, animate: bool) -> bool {
	if w.workspace == nil {return false}
	for &label in w.tab_labels {label.seen = false}
	changed := false
	for tab in w.workspace.tabs {
		front, has_front := layout.focused_content(&tab.tree)
		if !has_front {continue}
		label := tab_label_find(w, tab.id)
		if label == nil {
			rest := Tab_Label {
				id    = tab.id,
				front = front,
				turn  = {value = 1, target = 1},
				seen  = true,
			}
			if _, err := append(&w.tab_labels, rest); err != nil {log.error("adding a tab's label failed")}
			continue
		}
		label.seen = true
		if label.front != front {tab_label_retarget(app, w, tab, label, front, animate)}
		changed = ui.motion_update(&label.turn, frame) || changed
	}
	#reverse for label, i in w.tab_labels {if !label.seen {unordered_remove(&w.tab_labels, i)}}
	return changed
}

// Focus moved from the pane the label shows to `front`. The face drawn now goes on turning from the width it
// has: before halfway that is the pane the label was turning from, which keeps turning away, now toward
// `front`, unless focus went back to it; otherwise it is the pane focus just left, which turns away in its
// place. Its title goes on from where it is drawn. A pane no longer in the tab is not turned from.
@(private = "file")
tab_label_retarget :: proc(
	app: ^App,
	w: ^Window,
	tab: ^Tab,
	label: ^Tab_Label,
	front: layout.Content,
	animate: bool,
) {
	shown, shown_behind := label.front, label.behind
	label.front, label.behind = front, nil
	p := ui.motion_active(label.turn) ? clamp(label.turn.value, 0, 1) : 1
	from, from_behind, progress := label.from, label.from_behind, p
	// Where the title turning away draws now, in title boxes from its place.
	at := label.start * (1 - p) - label.toward * p
	if p >= 0.5 || front == label.from {
		from, from_behind, progress = shown, shown_behind, 1 - p
		at = label.toward * (1 - p)
	}
	label.turn = {value = 1, target = 1}
	if progress >= 1 || layout.find_content(&tab.tree, from) == layout.INVALID_NODE {return}
	if behind, stacked := from_behind.?; stacked {
		if layout.find_content(&tab.tree, behind) == layout.INVALID_NODE {from_behind = nil}
	}
	toward, sided := pane_side(app, w, &tab.tree, pane_motion_key(from), pane_motion_key(front)).?
	if !sided {toward = {1, 0}}
	label.from, label.from_behind, label.toward = from, from_behind, toward
	label.start = (at + toward * progress) / (1 - progress)
	motion := settings.motion_resolve(&app.settings, .Tab_Label)
	duration := settings.motion_duration(&app.settings, motion)
	label.turn = {value = progress, target = progress}
	ui.motion_target_curve(&label.turn, 1, duration, motion.curve, animate && motion.on && duration > 0)
}

// Fills in `t`'s turn while tab `index`'s label turns, and notes the pane drawn behind its focused `front`
// for the next turn to start from. Marks stand for panes, so a turn between panes whose labels look alike
// still spins them.
tab_label_turn_shown :: proc(
	app: ^App,
	w: ^Window,
	index: int,
	front: layout.Content,
	behind: Maybe(layout.Content),
	t: ^ui.Tab_Tile,
) -> render.Build_Status {
	tab := w.workspace.tabs[index]
	label := tab_label_find(w, tab.id)
	if label == nil || label.front != front {return .Ok}
	label.behind = behind
	if !ui.motion_active(label.turn) {return .Ok}
	from_behind, stacked := label.from_behind.?
	turn := ui.Tab_Turn {
		turning  = true,
		title    = tab_display_title_with(app, tab, label.from, index + 1),
		progress = label.turn.value,
		toward   = label.toward,
		start    = label.start,
	}
	result: render.Build_Status
	turn.badge, turn.behind, result = tab_marks(app, w, label.from, from_behind, stacked)
	if result != .Ok {return result}
	t.turn = turn
	return .Ok
}
