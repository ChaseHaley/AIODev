package main

import "aio:commands"
import "aio:layout"
import "aio:render"
import "aio:ui"

// Why the window would refuse a pane header button for a pane. A refused button draws disabled, takes no
// press, and its tooltip says why.
Pane_Header_Refusal :: enum u8 {
	None,
	// A pane would end up below the minimum pane size.
	Minimum,
	// Floating would leave the tab without a tiled pane.
	Last_Tiled,
	// Only terminal panes can have a linked window.
	Not_Linkable,
	// Linking would leave this window without a pane of the tab.
	Keeps_One,
}

@(rodata)
PANE_HEADER_REFUSAL_TEXT := [Pane_Header_Refusal]string {
	.None         = "",
	.Minimum      = "Too small to split: a pane would be below the minimum pane size.",
	.Last_Tiled   = "The tab keeps one tiled pane; split it before floating this one.",
	.Not_Linkable = "Only a terminal pane can have a linked window.",
	.Keeps_One    = "A tab must keep one pane in this window.",
}

// Measures, on copies of the window's tree, which of `pane`'s header buttons the window would refuse.
// Every relayout stores the answer in the pane's view, so drawing and pointer handling only read it.
pane_header_refusals :: proc(
	app: ^App,
	w: ^Window,
	pane: layout.Pane_Rect,
) -> (
	refused: [Pane_Header_Button]Pane_Header_Refusal,
) {
	if _, refusal := pane_trial_split_minimum(app, w, pane.node, .Right); refusal != .None {
		refused[.Split_Right] = refusal
	}
	if _, refusal := pane_trial_split_minimum(app, w, pane.node, .Down); refusal != .None {
		refused[.Split_Down] = refusal
	}
	if !pane.floating {
		refused[.Dock] = pane_trial_float(w, pane.node)
		refused[.Linked_Window] = pane_trial_link(w, pane)
	}
	return
}

// The refusal the window stored for a header button, from its last relayout.
pane_header_refused :: proc(
	w: ^Window,
	pane: layout.Pane_Rect,
	button: Pane_Header_Button,
) -> Pane_Header_Refusal {
	view := pane_view(w, pane.content)
	return view != nil ? view.header_refused[button] : .None
}

// A pane header button's tooltip card: under the label, a picture of the window as the button would leave
// it, measured on a copy of the window's tree, and a sentence telling the button apart from its neighbours.
// A refused button shows why instead of a picture.
pane_header_card :: proc(
	app: ^App,
	w: ^Window,
	pane: layout.Pane_Rect,
	button: Pane_Header_Button,
) -> Tooltip_Card {
	if refusal := pane_header_refused(w, pane, button); refusal != .None {
		return {description = PANE_HEADER_REFUSAL_TEXT[refusal]}
	}
	switch button {
	case .Documents, .Close:
	case .Split_Right:
		return pane_preview_split(app, w, pane.node, .Right, "A new pane to the right of this one.")
	case .Split_Down:
		return pane_preview_split(app, w, pane.node, .Down, "A new pane below this one.")
	case .Zoom:
		return pane_preview_view(app, w, pane.node, .Toggle_Zoom)
	case .Fill_Window:
		return pane_preview_view(app, w, pane.node, .Toggle_Fill)
	case .Dock:
		return pane_preview_float(app, w, pane.node)
	case .Linked_Window:
		return pane_preview_linked(app, w, pane)
	}
	return {}
}

// The window as it shows `trial`, with `fill` and `solo` as its view, and `node` as the button's pane.
@(private = "file")
pane_preview_of :: proc(
	app: ^App,
	w: ^Window,
	trial: ^layout.Layout,
	fill: layout.Pane_Fill,
	solo: bool,
	node: layout.Node_Id,
) -> ui.Pane_Preview {
	g := window_geometry(app, w, fill)
	rects := make([dynamic]layout.Pane_Rect, 0, len(trial.nodes), context.temp_allocator)
	layout.place_shown(trial, g, solo, &rects)
	return pane_preview_rects(w, g.tiled, window_title_height_in(w, fill), rects[:], node)
}

@(private = "file")
pane_preview_rects :: proc(
	w: ^Window,
	content: layout.Rect,
	title: f32,
	rects: []layout.Pane_Rect,
	node: layout.Node_Id,
) -> ui.Pane_Preview {
	panes := make([]render.Rect, len(rects), context.temp_allocator)
	chosen := -1
	for pane, i in rects {
		panes[i] = {pane.rect.x, pane.rect.y, pane.rect.width, pane.rect.height}
		if pane.node == node {chosen = i}
	}
	return {
		size = {f32(w.width), f32(w.height)},
		title = title,
		content = {content.x, content.y, content.width, content.height},
		panes = panes,
		pane = chosen,
	}
}

// Splitting ends any zoom or fill, so a split is placed in the split view, the panes in `after` and the new
// one `added`. Refused with .Minimum when a pane would fall below the minimum size, as the split itself is.
@(private = "file")
Split_Trial :: struct {
	after: [dynamic]layout.Pane_Rect,
	added: layout.Node_Id,
}

@(private = "file")
pane_trial_split_minimum :: proc(
	app: ^App,
	w: ^Window,
	node: layout.Node_Id,
	direction: layout.Direction,
) -> (
	Split_Trial,
	Pane_Header_Refusal,
) {
	tree := window_tree(w)
	trial, copy_error := layout.clone(tree, context.temp_allocator)
	if copy_error != nil {return {added = layout.INVALID_NODE}, .None}
	added, split_error := layout.split_direction(
		&trial, node, direction, commands.SPLIT_DEFAULT.ratio, PANE_MEASUREMENT_CONTENT,
	)
	if split_error != nil {return {added = layout.INVALID_NODE}, .None}
	g := window_geometry(app, w, .None)
	after := make([dynamic]layout.Pane_Rect, 0, len(trial.nodes), context.temp_allocator)
	before := make([dynamic]layout.Pane_Rect, 0, len(tree.nodes), context.temp_allocator)
	layout.place_shown(&trial, g, false, &after)
	layout.place_shown(tree, g, false, &before)
	if !pane_minimum_allows(app, w, after[:], before[:], false) {return {after, added}, .Minimum}
	return {after, added}, .None
}

@(private = "file")
pane_preview_split :: proc(
	app: ^App,
	w: ^Window,
	node: layout.Node_Id,
	direction: layout.Direction,
	description: string,
) -> Tooltip_Card {
	split, _ := pane_trial_split_minimum(app, w, node, direction)
	if split.added == layout.INVALID_NODE {return {description = description}}
	g := window_geometry(app, w, .None)
	preview := pane_preview_rects(w, g.tiled, window_title_height_in(w, .None), split.after[:], split.added)
	return {description = description, preview = preview}
}

// Zoom and Fill window follow the one view table, so the picture shows the view the button leads to.
@(private = "file")
pane_preview_view :: proc(
	app: ^App,
	w: ^Window,
	node: layout.Node_Id,
	event: layout.Pane_View_Event,
) -> Tooltip_Card {
	to := layout.PANE_VIEW_TRANSITIONS[pane_view_current(w)][event]
	description: string
	switch to {
	case .Split:
		description = "Show the tab's other panes again."
	case .Zoom:
		description = "This pane fills the tab. The tab bar and panels stay."
	case .Fill, .Fill_Over_Zoom:
		description = "This pane covers the window. The tabs and panels slide away."
	case .Screen, .Screen_Over_Zoom:
		description = "This pane covers the screen."
	}
	trial, copy_error := layout.clone(window_tree(w), context.temp_allocator)
	if copy_error != nil {return {description = description}}
	// The view shows the focused pane, and pressing the header focuses its pane first.
	trial.focus = node
	fill, _ := layout.pane_view_parts(to)
	preview := pane_preview_of(app, w, &trial, fill, to != .Split, node)
	return {description = description, preview = preview}
}

// Floats `node` on a copy of the window's tree, as Float would; .Last_Tiled when the tab would keep none.
@(private = "file")
pane_trial_float_layout :: proc(
	w: ^Window,
	node: layout.Node_Id,
) -> (
	layout.Layout,
	Pane_Header_Refusal,
	bool,
) {
	tree := window_tree(w)
	trial, copy_error := layout.clone(tree, context.temp_allocator)
	if copy_error != nil {return {}, .None, false}
	if !layout.set_floating(&trial, node, true, floating_bounds_new(w, tree)) {return {}, .Last_Tiled, false}
	return trial, .None, true
}

@(private = "file")
pane_trial_float :: proc(w: ^Window, node: layout.Node_Id) -> Pane_Header_Refusal {
	_, refusal, _ := pane_trial_float_layout(w, node)
	return refusal
}

// Floating, like linking, changes which panes the tiling shows, which ends any zoom or fill.
@(private = "file")
pane_preview_float :: proc(app: ^App, w: ^Window, node: layout.Node_Id) -> Tooltip_Card {
	description := "Lift this pane above the tab, in this window, to move and size freely."
	trial, _, floated := pane_trial_float_layout(w, node)
	if !floated {return {description = description}}
	return {description = description, preview = pane_preview_of(app, w, &trial, .None, false, node)}
}

// Links `pane` on a copy of the window's tree, as Linked window would. A linked window's own button
// returns the pane to its tab, which is never refused.
@(private = "file")
pane_trial_link_layout :: proc(
	w: ^Window,
	pane: layout.Pane_Rect,
) -> (
	layout.Layout,
	Pane_Header_Refusal,
	bool,
) {
	if window_linked(w) {return {}, .None, false}
	if !CONTENT_POLICY[pane.content.kind].linkable {return {}, .Not_Linkable, false}
	trial, copy_error := layout.clone(window_tree(w), context.temp_allocator)
	if copy_error != nil {return {}, .None, false}
	if !layout.set_linked(&trial, pane.node, true) {return {}, .Keeps_One, false}
	return trial, .None, true
}

@(private = "file")
pane_trial_link :: proc(w: ^Window, pane: layout.Pane_Rect) -> Pane_Header_Refusal {
	_, refusal, _ := pane_trial_link_layout(w, pane)
	return refusal
}

// The pane leaves for a window of its own, sized as it is now; this window shows the panes it keeps.
@(private = "file")
pane_preview_linked :: proc(app: ^App, w: ^Window, pane: layout.Pane_Rect) -> Tooltip_Card {
	if window_linked(w) {return {description = "Put this pane back in its tab's window."}}
	description := "Move this pane to a window of its own. It stays part of this tab."
	trial, _, linked := pane_trial_link_layout(w, pane)
	if !linked {return {description = description}}
	preview := pane_preview_of(app, w, &trial, .None, false, layout.INVALID_NODE)
	preview.away = {pane.rect.width, pane.rect.height}
	return {description = description, preview = preview}
}
