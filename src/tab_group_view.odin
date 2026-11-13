package main

import "aio:render"
import "aio:ui"

// Where a tab rests before its motion: `slot` counts the strip's tab widths or the rail's rows before it,
// and `offset` the strip DIPs of the group chips before it, its own group's included.
Tab_Place :: struct {
	slot, offset: f32,
}

// A group's chip, where a run of its tabs starts: just before tab `first`, the run's first laid-out tab. The
// strip gives it `width` DIPs, margins included; the rail gives it the row above that tab.
Tab_Run :: struct {
	group: ^Tab_Group,
	first: int,
	width: f32,
}

// The tabs' places and the group chips among them, in the strip or the rail, in temporary memory. `slots`
// counts the strip's shown tabs, or the rail's rows, and `chips` the strip DIPs all chips take.
Tab_Layout :: struct {
	places: []Tab_Place,
	runs:   []Tab_Run,
	slots:  int,
	chips:  f32,
}

// Lays out w's tabs for the strip, or for the rail, where each chip takes a row; only the strip measures its
// chips, with `app`. A folded group's tabs take no slot. Dragged tabs neither start nor end a group's run,
// so a group they pass over keeps one chip.
tab_layout :: proc(app: ^App, w: ^Window, horizontal: bool) -> Tab_Layout {
	workspace := w.workspace
	if workspace == nil {return {}}
	places, err := make([]Tab_Place, len(workspace.tabs), context.temp_allocator)
	if err != nil {return {}}
	runs := make([dynamic]Tab_Run, 0, len(workspace.groups), context.temp_allocator)
	dragging := tab_drag_active(w)
	result := Tab_Layout{places = places}
	previous: u32
	for tab, i in workspace.tabs {
		group := tab_group_find(workspace, tab.group)
		carried := dragging && tab.marked
		if !carried {
			if group != nil && tab.group != previous {
				width: f32
				if horizontal {
					width = ui.tab_chip_width(&w.ui_text, tab_chip(app, w, group), w.scale) / w.scale
					width += 2 * ui.TAB_CHIP_MARGIN
					result.chips += width
				} else {
					result.slots += 1
				}
				append(&runs, Tab_Run{group, i, width})
			}
			previous = tab.group
		}
		places[i] = {f32(result.slots), horizontal ? result.chips : 0}
		if carried || group == nil || !group.folded {result.slots += 1}
	}
	result.runs = runs[:]
	return result
}

// Group `group`'s chip: its name, its colour in the theme, and, folded, its tab count and the most urgent
// status of its tabs. The spinner's phase is drawing's to add.
tab_chip :: proc(app: ^App, w: ^Window, group: ^Tab_Group) -> ui.Tab_Chip {
	chip := ui.Tab_Chip {
		name   = group.name,
		color  = tab_group_color(app, group),
		folded = group.folded,
	}
	if !group.folded {return chip}
	summary: Status_Summary
	for tab, i in w.workspace.tabs {
		if tab.group != group.id {continue}
		chip.count += 1
		if !app.settings.status.enabled || !app.settings.status.tab_indicators {continue}
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

// The colour of tab `index`'s group band, transparent for an ungrouped tab.
tab_band_color :: proc(app: ^App, w: ^Window, index: int) -> render.Color {
	group := tab_group_of(w.workspace, index)
	if group == nil {return {}}
	return tab_group_color(app, group)
}

// Run `run`'s chip in the strip, before its first tab as that tab moves.
tab_chip_strip_rect :: proc(w: ^Window, bar: ui.Tab_Bar, run: Tab_Run) -> render.Rect {
	margin := ui.TAB_CHIP_MARGIN * w.scale
	right := tab_strip_x(w, bar, run.first) - margin
	width := run.width * w.scale - 2 * margin
	return {right - width, 0, width, bar.height}
}

// Run `run`'s chip in the rail, in the row above its first tab as that tab moves.
tab_chip_rail_rect :: proc(w: ^Window, layout: ui.Rail_Layout, run: Tab_Run) -> render.Rect {
	row := rail_tab_rect(w, layout, run.first)
	row.y -= layout.row_height
	return row
}

// Draws a chip and its hover, `rect` being its room in the strip or its row in the rail.
tab_chip_draw :: proc(app: ^App, w: ^Window, run: Tab_Run, rect: render.Rect) -> render.Build_Status {
	chip := tab_chip(app, w, run.group)
	chip.status_phase = status_phase(app, w, chip.status)
	r := rect
	r.width = min(r.width, ui.tab_chip_width(&w.ui_text, chip, w.scale))
	hover := f32(int(w.tab_hover == Tab_Chrome_Group{run.group.id}))
	return ui.tab_chip_draw(&w.list, &w.ui_text, app.theme, r, chip, hover, w.scale)
}

when AIO_CONTROL {
	// The shown workspace's groups, in the order their chips show: group.N's id, name, colour, fold, tab
	// count and chip, in the strip or the rail.
	tab_groups_state_report :: proc(r: ^State_Report, app: ^App, w: ^Window) {
		state_value(r, "groups.count", len(w.workspace.groups))
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
