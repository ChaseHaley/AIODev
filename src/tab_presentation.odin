package main

import "aio:ui"
import "aio:layout"
import "core:time"

// How long a reordered tab takes to ease into its slot (D-069). Workspace rows settling after a reorder
// share it, so both lists move alike.
TAB_REORDER_DURATION :: 140 * time.Millisecond

tab_content_icon :: proc(tab: ^Tab) -> ui.Icon {
	if int(tab.tree.focus) >= len(tab.tree.nodes) {return .None}
	pane, ok := tab.tree.nodes[tab.tree.focus].(layout.Pane)
	return ok ? content_tab_icon(pane.content.kind) : .None
}

// Tab presentation indexed by tab position: both arrays stay aligned with the workspace tab list. The
// strip's new-tab button and profile chevron keep their own controls.
Tab_Presentation :: struct {
	tab_controls:     [dynamic]ui.Control_Motion,
	tab_positions:    [dynamic]ui.Motion,
	new_tab_control:  ui.Control_Motion,
	profiles_control: ui.Control_Motion,
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
