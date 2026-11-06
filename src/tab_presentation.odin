package main

import "aio:ui"
import "aio:layout"

tab_content_icon :: proc(tab: ^Tab) -> ui.Icon {
	if int(tab.tree.focus) >= len(tab.tree.nodes) {return .None}
	pane, ok := tab.tree.nodes[tab.tree.focus].(layout.Pane)
	if !ok {return .None}
	switch pane.content.kind {
	case .Terminal: return .None
	case .Settings: return .Settings
	case .Markdown: return .Markdown
	}
	return .None
}

// Tab presentation indexed by tab position. Both arrays stay aligned with the
// workspace tab list; controls carry one extra trailing entry for the new-tab button and one
// for the profile chevron.
Tab_Presentation :: struct {
	tab_controls:  [dynamic]ui.Control_Motion,
	tab_positions: [dynamic]ui.Motion,
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
}

// Grows or shrinks both arrays to the tab count. Only entries beyond the previous length start
// at their own index, so reordering and resizing keep an animating position on its tab.
@(require_results)
tab_presentation_resize :: proc(presentation: ^Tab_Presentation, tab_count: int) -> bool {
	appended := len(presentation.tab_positions)
	if resize(&presentation.tab_controls, tab_count + 2) != nil {return false}
	if resize(&presentation.tab_positions, tab_count) != nil {return false}
	for &position, i in presentation.tab_positions {
		if i < appended {continue}
		position.value, position.target = f32(i), f32(i)
	}
	return true
}

@(require_results)
tab_presentation_reserve :: proc(presentation: ^Tab_Presentation, tab_count: int) -> bool {
	return reserve(&presentation.tab_controls, tab_count + 2) == nil &&
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

// Removes both presentation values for a closed tab; the trailing controls stay last.
tab_presentation_remove :: proc(presentation: ^Tab_Presentation, index: int) {
	if index < 0 {return}
	if index < len(presentation.tab_positions) {ordered_remove(&presentation.tab_positions, index)}
	if index < len(presentation.tab_controls) {ordered_remove(&presentation.tab_controls, index)}
}
