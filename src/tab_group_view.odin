package main

import "aio:render"
import "aio:ui"

// Where a tab rests before its motion: `slot` counts the strip's tab widths or the rail's rows before it,
// and `offset` the strip DIPs of the group chips before it, its own group's included.
Tab_Place :: struct {
	slot, offset: f32,
}

// A group's chip, where a run of its tabs starts: just before tab `first`, the run's first laid-out tab at
// rest, less `lead` tabs dragged into the run's start. The strip gives it `width` DIPs, margins included;
// the rail gives it the row above. A `carried` chip rides before the tabs of a whole group being dragged,
// and keeps its room where the group would drop, so the tabs take as much room in all as at rest.
Tab_Run :: struct {
	group:   ^Tab_Group,
	first:   int,
	lead:    int,
	width:   f32,
	carried: bool,
}

// The tabs' places and the group chips among them, in the strip or the rail, in temporary memory. `slots`
// counts the strip's shown tabs, or the rail's rows, and `chips` the strip DIPs all chips take.
Tab_Layout :: struct {
	places: []Tab_Place,
	runs:   []Tab_Run,
	slots:  int,
	chips:  f32,
}

// Lays out w's tabs for the strip, or for the rail, where each chip takes a row; only the strip measures
// its chips, with `app`. A folded group's tabs take no slot. Tabs dragged on their own lie in the group
// they would join (tab_laid_group), so the gap they leave opens on that group's tray, after its chip; a
// whole group being dragged carries its own chip.
tab_layout :: proc(app: ^App, w: ^Window, horizontal: bool) -> Tab_Layout {
	workspace := w.workspace
	if workspace == nil {return {}}
	places, err := make([]Tab_Place, len(workspace.tabs), context.temp_allocator)
	if err != nil {return {}}
	runs := make([dynamic]Tab_Run, 0, len(workspace.groups), context.temp_allocator)
	_, carry := tab_drag_state(w)
	whole := carry != nil && carry.whole
	result := Tab_Layout{places = places}
	previous, previous_carried: u32
	for tab, i in workspace.tabs {
		id := tab_laid_group(w, i)
		group := tab_group_find(workspace, id)
		carried := whole && tab.marked
		if group != nil && id != (carried ? previous_carried : previous) {
			width: f32
			if horizontal {
				chip := tab_chip(app, w, group, group.folded)
				width = ui.tab_chip_width(&w.ui_text, chip, w.scale) / w.scale
				if naming, editor := group_name_editing(w); naming == group && !editor {
					width = max(width, GROUP_NAME_MIN_WIDTH)
				}
				width += 2 * ui.TAB_CHIP_MARGIN
			}
			if horizontal {result.chips += width} else {result.slots += 1}
			append(&runs, Tab_Run{group = group, first = i, width = width, carried = carried})
		}
		if carried {previous_carried = id} else {previous = id}
		places[i] = {f32(result.slots), horizontal ? result.chips : 0}
		if group == nil || !group.folded {result.slots += 1}
	}
	// The dragged tabs follow the pointer, so a run they start takes its chip's place from its first tab at
	// rest.
	if carry != nil && !whole {
		for &run in runs {
			for run.first + 1 < len(workspace.tabs) && workspace.tabs[run.first].marked &&
			    tab_laid_group(w, run.first + 1) == run.group.id {
				run.first += 1
				run.lead += 1
			}
		}
	}
	result.runs = runs[:]
	// Chips take at most half the strip, shrinking together and fading their names, so tabs stay usable.
	if horizontal && result.chips > 0 {
		strip := (f32(w.width) - window_caption_reserve(w) - workspace_button_width(app, w)) / w.scale
		budget := max(0, strip / 2)
		if result.chips > budget {
			factor := budget / result.chips
			for &place in places {place.offset *= factor}
			for &run in result.runs {run.width *= factor}
			result.chips = budget
		}
	}
	return result
}

// Whether every tab of group `id` is marked, as when its chip is dragged.
tab_group_carried_whole :: proc(workspace: ^Workspace, id: u32) -> bool {
	for tab in workspace.tabs {if tab.group == id && !tab.marked {return false}}
	return true
}

// Group `group`'s chip: its name, as typed while it is being named, its colour in the theme, and, shown
// `folded`, its tab count and the most urgent status of its tabs. The spinner's phase is drawing's to add.
tab_chip :: proc(app: ^App, w: ^Window, group: ^Tab_Group, folded: bool) -> ui.Tab_Chip {
	chip := ui.Tab_Chip {
		name   = group.name,
		color  = tab_group_color(app, group),
		folded = folded,
	}
	if naming, _ := group_name_editing(w); naming == group {chip.name = ui.field_string(&w.rename)}
	if !folded {return chip}
	summary: Status_Summary
	for tab, i in w.workspace.tabs {
		if tab.group != group.id {continue}
		chip.count += 1
		if !app.settings.status.enabled || .Tabs not_in app.settings.status.surfaces {continue}
		walk := tab_session_panes(app, &tab.tree, i)
		for pane, ok := workspace_pane_next(&walk); ok; pane, ok = workspace_pane_next(&walk) {
			status_summary_add(app, &summary, pane.session)
		}
	}
	chip.status, _ = status_indicator(summary)
	return chip
}

tab_group_color :: proc(app: ^App, group: ^Tab_Group) -> render.Color {
	return workspace_icon_tint(group.color, app.theme.text)
}

// Whether group `group` shows its tray: while unfolded, and while its tabs slide into the chip as it folds.
tab_group_tray_shown :: proc(w: ^Window, group: ^Tab_Group) -> bool {
	return !group.folded || w.folding == group.id
}

// The group tab `index` lies in: its own, or for a tab dragged on its own, the group it would join if dropped
// now (WORK-459).
tab_laid_group :: proc(w: ^Window, index: int) -> u32 {
	tab := w.workspace.tabs[index]
	if _, carry := tab_drag_state(w); carry != nil && !carry.whole && tab.marked {return carry.group}
	return tab.group
}

// The part of a group's tray at tab `index`'s place among the tabs at rest: transparent outside a group, else
// its group's colour, closing the tray at the last tab of its group laid out together. A dragged tab's place
// is the gap it leaves.
tab_tray_place :: proc(app: ^App, w: ^Window, index: int) -> (render.Color, ui.Tray_Ends) {
	workspace := w.workspace
	id := tab_laid_group(w, index)
	group := tab_group_find(workspace, id)
	if group == nil || !tab_group_tray_shown(w, group) {return {}, {}}
	// A whole group being dragged rides apart from the others, so each side's run ends at its own last tab.
	_, carry := tab_drag_state(w)
	apart := carry != nil && carry.whole
	marked := workspace.tabs[index].marked
	next := index + 1
	for next < len(workspace.tabs) && apart && workspace.tabs[next].marked != marked {next += 1}
	ends: ui.Tray_Ends
	if next >= len(workspace.tabs) || tab_laid_group(w, next) != id {ends = {.End}}
	return tab_group_color(app, group), ends
}

// Tab `index`'s part of a group's tray (WORK-454), drawn with the tab. A tab dragged on its own carries a
// tray of the group it would join if dropped now, so the drop's outcome shows before the release.
tab_tray :: proc(app: ^App, w: ^Window, index: int) -> (render.Color, ui.Tray_Ends) {
	if _, carry := tab_drag_state(w); carry != nil && !carry.whole && w.workspace.tabs[index].marked {
		_, reordering := carry.destination.(Drop_Reorder)
		group := tab_group_find(w.workspace, carry.group)
		if !reordering || group == nil {return {}, {}}
		return tab_group_color(app, group), {.Start, .End}
	}
	return tab_tray_place(app, w, index)
}

// Draws run `run`'s chip at `chip` in the strip, on the start of its group's tray, which takes the chip's
// room and the margin after it.
tab_chip_strip_draw :: proc(
	app: ^App,
	w: ^Window,
	bar: ui.Tab_Bar,
	run: Tab_Run,
	chip: render.Rect,
) -> render.Build_Status {
	if tab_group_tray_shown(w, run.group) {
		y, height := ui.tab_tray_band(bar.height, w.scale)
		slice := render.Rect{chip.x, y, chip.width + ui.TAB_CHIP_MARGIN * w.scale, height}
		color, state := tab_group_color(app, run.group), tab_group_state(w, run.group.id)
		if ui.tab_tray_draw(&w.list, slice, color, {.Start}, state, false, w.scale) != .None {
			return .Ok
		}
	}
	return tab_chip_draw(app, w, run, chip)
}

// Run `run`'s chip in the strip, before its first tab at rest as that tab moves, and the tabs dragged into
// the run's start.
tab_chip_strip_rect :: proc(w: ^Window, bar: ui.Tab_Bar, run: Tab_Run) -> render.Rect {
	margin := ui.TAB_CHIP_MARGIN * w.scale
	right := tab_strip_x(w, bar, run.first) - f32(run.lead) * bar.tab_width - margin
	width := max(0, run.width * w.scale - 2 * margin)
	return {right - width, 0, width, bar.height}
}

// While tab `index`'s group folds or unfolds, its tabs slide into or out of the chip, shown only between the
// group's first tab, which rides on the chip, and whatever follows the group, so they vanish into the chip
// as that closes up and come out of it as it opens. False when the tab is not sliding so.
tab_fold_clip :: proc(app: ^App, w: ^Window, index: int) -> (clip: render.Rect, sliding: bool) {
	workspace := w.workspace
	if w.folding == 0 || index >= len(workspace.tabs) || workspace.tabs[index].group != w.folding {return}
	if tab_drag_active(w) {return}
	first, next := index, index + 1
	for first > 0 && workspace.tabs[first - 1].group == w.folding {first -= 1}
	for next < len(workspace.tabs) && workspace.tabs[next].group == w.folding {next += 1}
	if w.tabs_horizontal {
		bar := window_tab_bar(app, w)
		left := tab_strip_x(w, bar, first)
		right := next < len(workspace.tabs) ? tab_strip_x(w, bar, next) : bar.x + bar.width
		return {left, 0, max(0, right - left), bar.height}, true
	}
	rail, ok := rail_layout_query(w)
	if !ok {return}
	top := max(rail_tab_rect(w, rail, first).y, rail.list.y)
	bottom := next < len(workspace.tabs) ? rail_tab_rect(w, rail, next).y : rail.list.y + rail.list.height
	bottom = min(bottom, rail.list.y + rail.list.height)
	return {rail.list.x, top, rail.list.width, max(0, bottom - top)}, true
}

// Group `id`'s chip where it shows, in the strip or the rail; empty while it shows none.
tab_group_chip_rect :: proc(app: ^App, w: ^Window, id: u32) -> render.Rect {
	if w.tabs_horizontal {
		bar := window_tab_bar(app, w)
		for run in tab_layout(app, w, true).runs {
			if run.group.id == id && !run.carried {return tab_chip_strip_rect(w, bar, run)}
		}
		return {}
	}
	rail, ok := rail_layout_query(w)
	if !ok {return {}}
	for run in tab_layout(nil, w, false).runs {
		if run.group.id == id && !run.carried {return tab_chip_rail_rect(w, rail, run)}
	}
	return {}
}

// Run `run`'s chip in the rail, in the row above its first tab at rest as that tab moves, and the tabs
// dragged into the run's start.
tab_chip_rail_rect :: proc(w: ^Window, layout: ui.Rail_Layout, run: Tab_Run) -> render.Rect {
	row := rail_tab_rect(w, layout, run.first)
	row.y -= f32(1 + run.lead) * layout.row_height
	return row
}

// Draws a chip and its hover, `rect` being its room in the strip or its row in the rail. A `bare` chip lies
// on the tray that folds into it, which stands in for its own tint and outline.
tab_chip_draw :: proc(
	app: ^App,
	w: ^Window,
	run: Tab_Run,
	rect: render.Rect,
	bare := false,
) -> render.Build_Status {
	chip := tab_chip(app, w, run.group, run.group.folded)
	chip.status_phase = status_phase(app, w, chip.status)
	chip.bare = bare
	r := rect
	r.width = min(r.width, ui.tab_chip_width(&w.ui_text, chip, w.scale))
	return ui.tab_chip_draw(&w.list, &w.ui_text, app.theme, r, chip, tab_group_state(w, run.group.id), w.scale)
}

// The group whose chip is held, pressed or dragging its group; 0 for none.
tab_group_held :: proc(w: ^Window) -> u32 {
	#partial switch d in w.drag {
	case Drag_Pressed:
		if grab, ok := d.grab.(Tab_Grab); ok {return grab.chip}
	case Drag_Active:
		if carry, ok := d.carry.(Tab_Carry); ok {return carry.grab.chip}
	}
	return 0
}

// How strongly group `id` shows its outline (WORK-454): its chip held, under the pointer, or neither.
tab_group_state :: proc(w: ^Window, id: u32) -> ui.Tray_State {
	if id == 0 {return .Rest}
	if tab_group_held(w) == id {return .Pressed}
	if w.tab_hover == (Tab_Chrome_Group{id}) {return .Hover}
	return .Rest
}

when AIO_CONTROL {
	// The shown workspace's groups, in the order their chips show: group.N's id, name, colour, fold, tab
	// count and chip, in the strip or the rail.
	tab_groups_state_report :: proc(r: ^State_Report, app: ^App, w: ^Window) {
		state_value(r, "groups.count", len(w.workspace.groups))
		naming, editor := group_name_editing(w)
		state_value(r, "group_name.open", naming != nil)
		state_value(r, "group_name.editor", editor)
		overlay, _ := w.overlay.(Overlay_Group_Name)
		state_value(r, "group_name.error", overlay.error)
		state_rect(r, "group_name.field", naming != nil ? group_name_field_rect(app, w) : render.Rect{})
		for color in 1 ..< len(WORKSPACE_ICON_COLORS) {
			swatch := editor ? group_name_swatch_rect(app, w, color) : render.Rect{}
			state_rect(r, state_key("group_name.swatch.%d", color), swatch)
		}
		bar := window_tab_bar(app, w)
		rail, _ := rail_layout_query(w)
		@(static, rodata) colors := WORKSPACE_ICON_COLORS
		for run, i in tab_layout(app, w, w.tabs_horizontal).runs {
			n := i + 1
			_, count := tab_group_span(w.workspace, run.group.id)
			chip := w.tabs_horizontal ? tab_chip_strip_rect(w, bar, run) : tab_chip_rail_rect(w, rail, run)
			state_value(r, state_key("group.%d.id", n), run.group.id)
			state_text(r, state_key("group.%d.name", n), run.group.name)
			state_text(r, state_key("group.%d.color", n), colors[run.group.color].name)
			state_value(r, state_key("group.%d.folded", n), run.group.folded)
			state_value(r, state_key("group.%d.tabs", n), count)
			state_rect(r, state_key("group.%d.chip", n), chip)
		}
	}
}
