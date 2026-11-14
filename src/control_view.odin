package main

import "aio:cli_protocol"
import "aio:layout"
import "core:math"

// The snapshot borrows titles and names; its arrays and tree nodes live until the tick ends.
control_view :: proc(app: ^App) -> Outcome {
	windows := make([dynamic]cli_protocol.View_Window_Report, 0, len(app.windows), context.temp_allocator)
	for w in app.windows {
		if w.phase == .Preparing || w.phase == .Closing {continue}
		workspace := window_link_workspace(w)
		if !window_linked(w) && w.workspace != nil {workspace = w.workspace.id}
		append(&windows, cli_protocol.View_Window_Report {
			id = u64(w.id),
			focused = w.focused,
			workspace = workspace,
			linked = window_linked(w),
		})
	}
	selected := window_focused_or_primary(app)
	workspaces := make(
		[dynamic]cli_protocol.View_Workspace_Report, 0, len(app.workspaces), context.temp_allocator,
	)
	for workspace in app.workspaces {
		if workspace.provisional {continue}
		w := window_for_workspace(app, workspace)
		report := cli_protocol.View_Workspace_Report {
			id = workspace.id,
			name = workspace.name,
			selected = selected != nil &&
				(selected.workspace == workspace || window_link_workspace(selected) == workspace.id),
			tabs = make([]cli_protocol.View_Tab_Report, len(workspace.tabs), context.temp_allocator),
		}
		for tab, index in workspace.tabs {
			shown := w != nil && w.phase == .Shown && workspace.selected == index
			report.tabs[index] = view_tab_report(tab, index, workspace.selected == index, shown ? w : nil)
		}
		append(&workspaces, report)
	}
	return {payload = Outcome_View(cli_protocol.View_Report {
		revision = app.events.revision,
		windows = windows[:],
		workspaces = workspaces[:],
		panes = pane_reports(app, nil),
	})}
}

@(private = "file")
view_tab_report :: proc(tab: ^Tab, index: int, selected: bool, w: ^Window) -> cli_protocol.View_Tab_Report {
	tree := &tab.tree
	nodes := make([]cli_protocol.View_Node_Report, len(tree.nodes), context.temp_allocator)
	used := 0
	report := cli_protocol.View_Tab_Report {
		id = tab.id,
		index = index + 1,
		name = tab.name,
		title = tab_display_title(tab, index + 1),
		group = tab.group,
		selected = selected,
		view = "split",
		root = view_node_report(tree, tree.root, false, nodes, &used),
	}
	if content, found := layout.focused_content(tree); found && content.kind == .Terminal {
		report.focused_pane = content.id
	}
	switch tree.fill {
	case .None:
		if tree.zoomed {report.view = "zoom"}
	case .Content:
		report.view = "fill"
	case .Screen:
		report.view = "fullscreen"
	}
	floats := make([dynamic]cli_protocol.View_Float_Report, context.temp_allocator)
	for value, id in tree.nodes {
		floating: layout.Float
		is_float := false
		#partial switch node in value {
		case layout.Pane:
			floating, is_float = node.float, node.floating
		case layout.Split:
			floating, is_float = node.float, node.floating
		}
		if !is_float {continue}
		root := view_node_report(tree, layout.Node_Id(id), true, nodes, &used)
		if root == 0 {continue}
		bounds := floating.bounds
		float_report := cli_protocol.View_Float_Report {
			bounds = {bounds.x, bounds.y, bounds.width, bounds.height},
			stack = floating.stack,
			minimized = floating.minimized,
			root = root,
		}
		if w != nil && w.metrics.cell_width > 0 && w.metrics.cell_height > 0 {
			area := floating_area(w)
			if rect, found := layout.float_rect(tree, layout.Node_Id(id), area); found {
				float_report.cells = [4]int {
					int(math.round((rect.x - area.x) / w.metrics.cell_width)),
					int(math.round((rect.y - area.y) / w.metrics.cell_height)),
					int(math.round(rect.width / w.metrics.cell_width)),
					int(math.round(rect.height / w.metrics.cell_height)),
				}
			}
		}
		append(&floats, float_report)
	}
	report.floats = floats[:]
	report.nodes = nodes[:used]
	return report
}

// A floating root is reported separately, while its old slot contributes nothing to the tiled tree.
// Nonterminal panes have a different id domain, so only terminal leaves enter this report. Returns the
// node's 1-based position in nodes, or 0 when nothing under it is reported.
@(private = "file")
view_node_report :: proc(
	tree: ^layout.Layout,
	id: layout.Node_Id,
	include_float: bool,
	nodes: []cli_protocol.View_Node_Report,
	used: ^int,
) -> int {
	if int(id) >= len(tree.nodes) {return 0}
	report: cli_protocol.View_Node_Report
	switch node in tree.nodes[id] {
	case layout.Vacant:
		return 0
	case layout.Pane:
		if (node.floating && !include_float) || node.content.kind != .Terminal {return 0}
		report.pane = node.content.id
	case layout.Split:
		if node.floating && !include_float {return 0}
		first := view_node_report(tree, node.first, false, nodes, used)
		second := view_node_report(tree, node.second, false, nodes, used)
		if first == 0 {return second}
		if second == 0 {return first}
		report.split = node.axis == .Horizontal ? "right" : "down"
		report.ratio, report.first, report.second = node.ratio, first, second
	}
	nodes[used^] = report
	used^ += 1
	return used^
}
