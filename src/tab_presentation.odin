package main

import "aio:ui"

// Presentation values indexed by tab position. Both arrays stay aligned with the workspace tab
// list; controls carry one extra trailing entry for the new-tab button.
Tab_Presentation :: struct {
	tab_controls: [dynamic]ui.Control_Motion,
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

// Grows or shrinks both arrays to `tab_count` tabs. Only entries beyond the previous length start
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

// Removes both presentation values for a closed tab; the trailing new-tab control stays last.
tab_presentation_remove :: proc(presentation: ^Tab_Presentation, index: int) {
	if index < 0 {return}
	if index < len(presentation.tab_positions) {ordered_remove(&presentation.tab_positions, index)}
	if index < len(presentation.tab_controls) {ordered_remove(&presentation.tab_controls, index)}
}

// The selected tab after the tab at `from` moves to `to`.
tab_presentation_selected_after_move :: proc(selected, from, to: int) -> int {
	switch {
	case selected == from:
		return to
	case from < selected && selected <= to:
		return selected - 1
	case to <= selected && selected < from:
		return selected + 1
	}
	return selected
}

// The selected tab after `index` closes, clamped to the `count` tabs that remain.
tab_presentation_selected_after_remove :: proc(selected, index, count: int) -> int {
	shifted := index < selected ? selected - 1 : selected
	return clamp(shifted, 0, max(0, count - 1))
}
