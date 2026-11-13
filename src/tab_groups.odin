package main

import "aio:commands"
import "core:slice"
import "core:strings"

// A name and a colour a person gives a run of adjacent tabs (D-093). A group is a label, not a container: it
// keeps no tab of its own and changes no shortcut. Its tabs are always adjacent, which tab_groups_tidy
// restores after any change to the tab list.
Tab_Group :: struct {
	id:     u32,
	// Owned. Empty draws the chip as a dot of its colour.
	name:   string,
	// An index into WORKSPACE_ICON_COLORS from 1: groups take the workspace icon colours.
	color:  int,
	// The chip stands in for the group's tabs, which neither draw nor take clicks.
	folded: bool,
}

tab_group_destroy :: proc(group: ^Tab_Group) {
	delete(group.name)
	group.name = ""
}

tab_group_find :: proc(workspace: ^Workspace, id: u32) -> ^Tab_Group {
	if workspace == nil || id == 0 {return nil}
	for &group in workspace.groups {if group.id == id {return &group}}
	return nil
}

// The group of tab `index`, or nil when it has none.
tab_group_of :: proc(workspace: ^Workspace, index: int) -> ^Tab_Group {
	if index < 0 || index >= len(workspace.tabs) {return nil}
	return tab_group_find(workspace, workspace.tabs[index].group)
}

// Whether tab `index` shows in the strip or the rail: a folded group shows only its chip.
tab_shown :: proc(workspace: ^Workspace, index: int) -> bool {
	group := tab_group_of(workspace, index)
	return group == nil || !group.folded
}

// The first tab of group `id`, -1 when it has none, and how many tabs it has.
tab_group_span :: proc(workspace: ^Workspace, id: u32) -> (first, count: int) {
	first = -1
	for tab, i in workspace.tabs {
		if tab.group != id {continue}
		if first < 0 {first = i}
		count += 1
	}
	return
}

// Restores what groups are after any change to the tab list. A tab naming no group has none; ungrouped tabs
// between two tabs of one group join it, as a tab opened inside a group does; a group's tabs after its first
// run leave it; and a group left without tabs goes.
tab_groups_tidy :: proc(workspace: ^Workspace) {
	tabs := workspace.tabs[:]
	for tab in tabs {if tab_group_find(workspace, tab.group) == nil {tab.group = 0}}
	for i := 0; i < len(tabs); {
		if tabs[i].group != 0 {i += 1; continue}
		end := i
		for end < len(tabs) && tabs[end].group == 0 {end += 1}
		if i > 0 && end < len(tabs) && tabs[i - 1].group == tabs[end].group {
			for tab in tabs[i:end] {tab.group = tabs[end].group}
		}
		i = end
	}
	for tab, i in tabs {
		if tab.group == 0 || i > 0 && tabs[i - 1].group == tab.group {continue}
		for earlier in tabs[:i] {
			if earlier.group == tab.group {
				// The first tab of a later run: it and the rest of that run leave the group.
				group := tab.group
				for later in tabs[i:] {
					if later.group != group {break}
					later.group = 0
				}
				break
			}
		}
	}
	for i := len(workspace.groups) - 1; i >= 0; i -= 1 {
		if _, count := tab_group_span(workspace, workspace.groups[i].id); count > 0 {continue}
		tab_group_destroy(&workspace.groups[i])
		ordered_remove(&workspace.groups, i)
	}
	// Whatever moved, the shown tab never ends up folded away.
	selected := workspace.selected
	if selected >= 0 && selected < len(tabs) {_ = tab_group_reveal(workspace, selected)}
}

// What a block of tabs that just moved together keeps or joins, where it now lies. Landing between two tabs
// of one group joins that group, and a block holding all of a group keeps it, moving it as a whole; any
// other tab leaves its group. A drag decides as it goes instead (tab_drag_group).
tab_groups_settle :: proc(workspace: ^Workspace, moved: []^Tab) {
	if len(moved) == 0 {return}
	first, _ := slice.linear_search(workspace.tabs[:], moved[0])
	last, _ := slice.linear_search(workspace.tabs[:], moved[len(moved) - 1])
	left := first > 0 ? workspace.tabs[first - 1].group : 0
	right := last + 1 < len(workspace.tabs) ? workspace.tabs[last + 1].group : 0
	if left != 0 && left == right {
		for tab in moved {tab.group = left}
	} else {
		tab_groups_keep_whole(workspace, moved)
	}
	tab_groups_tidy(workspace)
}

// Every tab of `moved` leaves its group unless `moved` holds all of that group.
tab_groups_keep_whole :: proc(workspace: ^Workspace, moved: []^Tab) {
	keep := make([]bool, len(moved), context.temp_allocator)
	for tab, i in moved {
		if tab.group == 0 || keep == nil {continue}
		whole := true
		for other in workspace.tabs {
			if other.group == tab.group && !slice.contains(moved, other) {whole = false; break}
		}
		keep[i] = whole
	}
	for tab, i in moved {if keep == nil || !keep[i] {tab.group = 0}}
}

// A group of `source` the tabs `tabs` names wholly, as its id there and its id in `destination`.
Tab_Group_Carry :: struct {
	from, to: u32,
}

// Takes the groups whose every tab is among `tabs` from `source` to `destination`, where they keep their
// name, colour and fold under new ids; a tab leaving part of a group leaves the group. Room in
// destination.groups was reserved. The pairs are in temporary memory; when they cannot be made, every
// moved tab arrives ungrouped.
tab_groups_carry :: proc(source, destination: ^Workspace, tabs: []u32) -> []Tab_Group_Carry {
	carried := make([dynamic]Tab_Group_Carry, 0, len(source.groups), context.temp_allocator)
	for i := len(source.groups) - 1; i >= 0; i -= 1 {
		group := source.groups[i]
		whole := true
		for tab in source.tabs {
			if tab.group == group.id && !slice.contains(tabs, tab.id) {whole = false; break}
		}
		if !whole {continue}
		destination.next_group_id += 1
		if _, err := append(&carried, Tab_Group_Carry{group.id, destination.next_group_id}); err != nil {break}
		group.id = destination.next_group_id
		append(&destination.groups, group)
		ordered_remove(&source.groups, i)
	}
	return carried[:]
}

// The destination id of source group `id` in `carried`, 0 when the group did not move whole.
tab_group_carried :: proc(carried: []Tab_Group_Carry, id: u32) -> u32 {
	for pair in carried {if pair.from == id {return pair.to}}
	return 0
}

// The shown tab nearest `index`, looking right first as a close does, while treating the tabs of `hidden`
// as folded too. -1 when no tab shows.
tab_nearest_shown :: proc(workspace: ^Workspace, index: int, hidden: u32 = 0) -> int {
	shown :: proc(workspace: ^Workspace, i: int, hidden: u32) -> bool {
		return tab_shown(workspace, i) && (hidden == 0 || workspace.tabs[i].group != hidden)
	}
	for i in max(0, index) ..< len(workspace.tabs) {if shown(workspace, i, hidden) {return i}}
	for i := min(index, len(workspace.tabs)) - 1; i >= 0; i -= 1 {if shown(workspace, i, hidden) {return i}}
	return -1
}

// The shown tab `step` places on from `from`, wrapping, skipping folded groups; `from` when no other shows.
tab_shown_step :: proc(workspace: ^Workspace, from, step: int) -> int {
	count := len(workspace.tabs)
	if count == 0 {return from}
	i := from
	for _ in 0 ..< count {
		i = ((i + step) % count + count) % count
		if tab_shown(workspace, i) {return i}
	}
	return from
}

// A tab a person or a program shows is never folded away: showing it unfolds its group. True when it did.
tab_group_reveal :: proc(workspace: ^Workspace, index: int) -> bool {
	group := tab_group_of(workspace, index)
	if group == nil || !group.folded {return false}
	group.folded = false
	return true
}

// The tabs a group command takes from tab `index`: the marked tabs when it is one of several, else it alone,
// in tab order, in temporary memory.
tab_group_scope :: proc(workspace: ^Workspace, index: int) -> []^Tab {
	if index < 0 || index >= len(workspace.tabs) {return nil}
	if !workspace.tabs[index].marked || tabs_marked_count(workspace) < 2 {
		one := make([]^Tab, 1, context.temp_allocator)
		if one != nil {one[0] = workspace.tabs[index]}
		return one
	}
	scope := make([dynamic]^Tab, 0, len(workspace.tabs), context.temp_allocator)
	for tab in workspace.tabs {if tab.marked {append(&scope, tab)}}
	return scope[:]
}

// w's tabs with `block` brought together after the last other tab of group `after`, or, when no other tab
// has it, where the block's first tab was. In temporary memory.
@(private = "file")
tab_order_with_block :: proc(workspace: ^Workspace, block: []^Tab, after: u32) -> []^Tab {
	order := make([dynamic]^Tab, 0, len(workspace.tabs), context.temp_allocator)
	at := -1
	for tab in workspace.tabs {
		if slice.contains(block, tab) {
			if at < 0 && tab == block[0] {at = len(order)}
			continue
		}
		append(&order, tab)
		if after != 0 && tab.group == after {at = len(order)}
	}
	if len(order) + len(block) != len(workspace.tabs) {return nil}
	inject_at_elems(&order, max(0, at), ..block)
	return order[:]
}

// Puts w's tabs in `order`, a reordering of them, one tab_move at a time so their places animate there.
@(private = "file")
tab_order_apply :: proc(app: ^App, w: ^Window, order: []^Tab) {
	for tab, to in order {
		for current, from in w.workspace.tabs {if current == tab {tab_move(app, w, from, to); break}}
	}
}

// A colour no group of the workspace uses yet, in palette order, else the next in turn.
@(private = "file")
tab_group_next_color :: proc(workspace: ^Workspace) -> int {
	colors := len(WORKSPACE_ICON_COLORS) - 1
	for color in 1 ..= colors {
		used := false
		for group in workspace.groups {used ||= group.color == color}
		if !used {return color}
	}
	return len(workspace.groups) % colors + 1
}

// Gathers tab `index`, or the marked tabs it is one of, into a new group named `name` where the first of
// them was, or after the group that tab was in. Nil when it could not be made.
@(require_results)
tab_group_create :: proc(app: ^App, w: ^Window, index: int, name := "") -> ^Tab_Group {
	workspace := w.workspace
	block := tab_group_scope(workspace, index)
	if len(block) == 0 || reserve(&workspace.groups, len(workspace.groups) + 1) != nil {return nil}
	order := tab_order_with_block(workspace, block, block[0].group)
	if order == nil {return nil}
	owned, err := strings.clone(name)
	if err != nil {return nil}
	workspace.next_group_id += 1
	id := workspace.next_group_id
	append(&workspace.groups, Tab_Group{id = id, name = owned, color = tab_group_next_color(workspace)})
	tab_order_apply(app, w, order)
	for tab in block {tab.group = id}
	tab_groups_changed(app, w)
	return tab_group_find(workspace, id)
}

// Moves tab `index`, or the marked tabs it is one of, to the end of group `id`.
tab_group_add :: proc(app: ^App, w: ^Window, index: int, id: u32) {
	workspace := w.workspace
	if tab_group_find(workspace, id) == nil {return}
	block := tab_group_scope(workspace, index)
	order := tab_order_with_block(workspace, block, id)
	if order == nil {return}
	tab_order_apply(app, w, order)
	for tab in block {tab.group = id}
	if tab := selected_tab(workspace); tab != nil && slice.contains(block, tab) {
		_ = tab_group_reveal(workspace, workspace.selected)
	}
	tab_groups_changed(app, w)
}

// Takes tab `index`, or the marked tabs it is one of, out of their groups, each just after the rest of its
// group.
tab_group_remove :: proc(app: ^App, w: ^Window, index: int) {
	workspace := w.workspace
	scope := tab_group_scope(workspace, index)
	for grouped in scope {
		if grouped.group == 0 {continue}
		id := grouped.group
		block := make([dynamic]^Tab, 0, len(scope), context.temp_allocator)
		for tab in scope {if tab.group == id {append(&block, tab)}}
		order := tab_order_with_block(workspace, block[:], id)
		if order == nil {return}
		tab_order_apply(app, w, order)
		for tab in block {tab.group = 0}
	}
	tab_groups_changed(app, w)
}

// Folds or unfolds group `id`. Folding the group of the shown tab shows the nearest tab outside it first;
// with none to show, the group stays open. False when it did not change.
tab_group_fold :: proc(app: ^App, w: ^Window, id: u32, folded: bool) -> bool {
	workspace := w.workspace
	group := tab_group_find(workspace, id)
	if group == nil || group.folded == folded {return false}
	if folded && workspace.tabs[workspace.selected].group == id {
		next := tab_nearest_shown(workspace, workspace.selected, id)
		if next < 0 {
			notify(app, .Info, "Nothing else is open, so the group stays unfolded.")
			return false
		}
		group.folded = true
		tab_select(app, w, next)
	}
	group.folded = folded
	w.folding = id
	tab_groups_changed(app, w)
	return true
}

// Takes every tab out of group `id`, which goes; the tabs stay where they are.
tab_group_ungroup :: proc(app: ^App, w: ^Window, id: u32) {
	for tab in w.workspace.tabs {if tab.group == id {tab.group = 0}}
	tab_groups_changed(app, w)
}

// Closes every tab of group `id`, asking first as closing marked tabs does. The marks show the tabs closing
// until the question, if one asks, is answered, then come back.
tab_group_close :: proc(app: ^App, w: ^Window, id: u32) {
	restore, err := make([dynamic]u32, 0, len(w.workspace.tabs))
	if err != nil {
		notify(app, .Error, "Could not select the group's tabs.")
		return
	}
	for tab in w.workspace.tabs {if tab.marked {append(&restore, tab.id)}}
	first := -1
	for tab, i in w.workspace.tabs {
		tab.marked = tab.group == id
		if tab.marked && first < 0 {first = i}
	}
	// Closing every tab can retire the window, and the marks with it.
	window := w.id
	if first >= 0 {tab_close_request(app, w, first, &restore)}
	if current := window_find(app, window); current == w {
		tab_close_restore(w, &restore)
	} else {
		delete(restore)
	}
}

// Opens a tab at the end of group `id` and shows it.
tab_group_new_tab :: proc(app: ^App, w: ^Window, id: u32) {
	workspace := w.workspace
	if tab_group_find(workspace, id) == nil {return}
	count := len(workspace.tabs)
	tab_new(app, w)
	if len(workspace.tabs) == count {return}
	tab_group_add(app, w, len(workspace.tabs) - 1, id)
}

tab_group_color_set :: proc(app: ^App, w: ^Window, id: u32, color: int) {
	group := tab_group_find(w.workspace, id)
	if group == nil || color < 1 || color >= len(WORKSPACE_ICON_COLORS) {return}
	group.color = color
	tab_groups_changed(app, w)
}

// Moves tab `index` one step left (`step` -1) or right (+1), stepping over groups at their edges. A tab at
// the edge of its group leaves it where it is, and an ungrouped tab beside a group joins it where it is; a
// tab alone in its group moves with it, past a whole group at a time, as every tab does past a folded one.
tab_move_step :: proc(app: ^App, w: ^Window, index, step: int) {
	workspace := w.workspace
	if index < 0 || index >= len(workspace.tabs) {return}
	tab := workspace.tabs[index]
	own := 0
	if tab.group != 0 {_, own = tab_group_span(workspace, tab.group)}
	beside := index + step
	if beside < 0 || beside >= len(workspace.tabs) {
		if own > 1 {tab.group = 0}
	} else {
		next := workspace.tabs[beside]
		group := tab_group_find(workspace, next.group)
		switch {
		case own > 1 && next.group != tab.group:
			tab.group = 0
		case own <= 1 && group != nil && !group.folded && tab.group == 0:
			tab.group = next.group
		case group != nil && next.group != tab.group:
			first, count := tab_group_span(workspace, next.group)
			tab_move(app, w, index, step < 0 ? first : first + count - 1)
		case:
			tab_move(app, w, index, beside)
		}
	}
	tab_groups_changed(app, w)
}

// Groups changed in w's workspace: they are tidied, saved and drawn again.
tab_groups_changed :: proc(app: ^App, w: ^Window) {
	tab_groups_tidy(w.workspace)
	layout_state_touch(app)
	mark_all_dirty(app)
}

// The group commands, acting on tab `index` of w's workspace or on its group. `named_workspace` is the
// destination --workspace names for a move.
@(require_results)
tab_group_command :: proc(
	app: ^App,
	w: ^Window,
	action: Action,
	index: int,
	invocation: commands.Invocation,
	named_workspace: ^Workspace,
) -> Outcome {
	workspace := w.workspace
	if index < 0 || index >= len(workspace.tabs) {return outcome_failure(.Failed, "there is no tab")}
	named := .Text in invocation.given
	#partial switch action {
	case .New_Tab_Group:
		group := tab_group_create(app, w, index, named ? rename_clean(invocation.text) : "")
		if group == nil {return outcome_failure(.Failed, "could not make the group")}
		if !named {tab_group_name_begin(app, w, group.id, true)}
		return {}
	case .Add_Tab_To_Group:
		for group in workspace.groups {
			if !strings.equal_fold(group.name, rename_clean(invocation.text)) {continue}
			tab_group_add(app, w, index, group.id)
			return {}
		}
		return outcome_failure(.Failed, "no group of that name")
	case .Remove_Tab_From_Group:
		tab_group_remove(app, w, index)
		return {}
	}
	group := tab_group_of(workspace, index)
	if group == nil {return outcome_failure(.Failed, "the tab is not in a group")}
	id := group.id
	#partial switch action {
	case .Rename_Tab_Group:
		target := Rename_Group_Target{workspace.id, id}
		if !named {
			tab_group_name_begin(app, w, id, false)
		} else if rename_target_commit(app, target, invocation.text, .Automatic_Title) != .Saved {
			return outcome_failure(.Failed, "could not rename the group")
		}
	case .Tab_Group_Color:
		@(static, rodata) colors := WORKSPACE_ICON_COLORS
		for color, i in colors[1:] {
			if !strings.equal_fold(color.name, invocation.text) {continue}
			tab_group_color_set(app, w, id, i + 1)
			return {}
		}
		return outcome_failure(.Failed, "no color of that name")
	case .Fold_Tab_Group:
		if !tab_group_fold(app, w, id, !group.folded) {
			return outcome_failure(.Failed, "nothing else is open, so the group stays unfolded")
		}
	case .Ungroup_Tabs:
		tab_group_ungroup(app, w, id)
	case .Close_Tab_Group:
		tab_group_close(app, w, id)
	case .New_Tab_In_Group:
		tab_group_new_tab(app, w, id)
	case .Move_Tab_Group_Workspace:
		request := workspace_move_group_request(w, id)
		if named_workspace == nil {
			workspace_move_picker_open(app, w, request)
		} else if named_workspace == workspace {
			return outcome_failure(.Failed, "the group is already in that workspace")
		} else if !workspace_move_content(app, w, request, named_workspace) {
			return outcome_failure(.Failed, "could not move the group to that workspace")
		}
	}
	return {}
}
