package main

import "aio:layout"

// One pane reached by walking a workspace's tabs and their layout nodes.
Workspace_Pane :: struct {
	tab:     int,
	node:    layout.Node_Id,
	content: layout.Content,
	session: ^Session_Entry,
}

// Every pane a workspace shows, and the subset that owns a runtime.
Workspace_Pane_Counts :: struct {
	tabs, panes, sessions: int,
}

// Which panes a walk yields. The Terminal/other content rule lives here, so callers ask for
// the panes they act on instead of deciding what a pane is.
Workspace_Pane_Scope :: enum {
	All,
	Sessions,
	Other,
}

// Walks a workspace's tabs in order, then each tab's nodes in order. A walk over one tab has
// no workspace and starts at its tree.
Workspace_Pane_Walk :: struct {
	app:       ^App,
	workspace: ^Workspace,
	tree:      ^layout.Layout,
	tab:       int,
	node:      int,
	scope:     Workspace_Pane_Scope,
}

@(private)
pane_owns_session :: proc(kind: layout.Content_Kind) -> bool {
	return kind == .Terminal
}

@(private)
pane_scope_includes :: proc(scope: Workspace_Pane_Scope, kind: layout.Content_Kind) -> bool {
	switch scope {
	case .All:
		return true
	case .Sessions:
		return pane_owns_session(kind)
	case .Other:
		return !pane_owns_session(kind)
	}
	return false
}

// The live runtime behind content, or nil when the content owns no session.
workspace_session_for_content :: proc(app: ^App, content: layout.Content) -> ^Session_Entry {
	if app == nil || !pane_owns_session(content.kind) {return nil}
	return session_find(app, content.id)
}

// Every pane in the workspace, in tab order.
workspace_panes :: proc(app: ^App, workspace: ^Workspace) -> Workspace_Pane_Walk {
	return {app = app, workspace = workspace, scope = .All}
}

// Every Terminal pane, the content that owns a runtime.
workspace_session_panes :: proc(app: ^App, workspace: ^Workspace) -> Workspace_Pane_Walk {
	return {app = app, workspace = workspace, scope = .Sessions}
}

// Every Terminal pane in one tab tree.
tab_session_panes :: proc(
	app: ^App,
	tree: ^layout.Layout,
	tab: int,
) -> Workspace_Pane_Walk {
	return {app = app, tree = tree, tab = tab, scope = .Sessions}
}

// Every pane in one tab tree that is not Terminal.
tab_other_panes :: proc(
	app: ^App,
	tree: ^layout.Layout,
	tab: int,
) -> Workspace_Pane_Walk {
	return {app = app, tree = tree, tab = tab, scope = .Other}
}

// Advances to the next pane the walk's scope yields. Returns false when no tab or node remains.
@(require_results)
workspace_pane_next :: proc(walk: ^Workspace_Pane_Walk) -> (pane: Workspace_Pane, ok: bool) {
	for {
		if walk.tree == nil {
			if walk.workspace == nil || walk.tab >= len(walk.workspace.tabs) {return {}, false}
			walk.tree = &walk.workspace.tabs[walk.tab].tree
			walk.node = 0
		}
		for walk.node < len(walk.tree.nodes) {
			node := walk.tree.nodes[walk.node]
			node_id := layout.Node_Id(walk.node)
			walk.node += 1
			candidate, is_pane := node.(layout.Pane)
			if !is_pane ||
			   !pane_scope_includes(walk.scope, candidate.content.kind) {continue}
			return Workspace_Pane{
				tab = walk.tab,
				node = node_id,
				content = candidate.content,
				session = workspace_session_for_content(walk.app, candidate.content),
			}, true
		}
		if walk.workspace == nil {return {}, false}
		walk.tab += 1
		walk.tree = nil
	}
}

// Counts every pane as a pane, and only Terminal panes as sessions.
@(require_results)
workspace_pane_counts :: proc(workspace: ^Workspace) -> Workspace_Pane_Counts {
	counts := Workspace_Pane_Counts{tabs = len(workspace.tabs)}
	walk := workspace_panes(nil, workspace)
	for pane, ok := workspace_pane_next(&walk); ok; pane, ok = workspace_pane_next(&walk) {
		counts.panes += 1
		if pane_owns_session(pane.content.kind) {counts.sessions += 1}
	}
	return counts
}

// Every pane in one tab, including the panes that own no session.
@(require_results)
tab_pane_count :: proc(tab: ^Tab) -> int {
	count := 0
	for node in tab.tree.nodes {if _, ok := node.(layout.Pane); ok {count += 1}}
	return count
}

// The first Terminal pane carrying `session`, with the tab and node identity mutation needs.
@(require_results)
workspace_first_session :: proc(
	app: ^App,
	workspace: ^Workspace,
	session: u32,
) -> (Workspace_Pane, bool) {
	walk := workspace_session_panes(app, workspace)
	for pane, ok := workspace_pane_next(&walk); ok; pane, ok = workspace_pane_next(&walk) {
		if pane.content.id == session {return pane, true}
	}
	return {}, false
}

// The Terminal pane at a tab's node, when that node is content that owns a session.
@(require_results)
workspace_session_pane_at :: proc(
	app: ^App,
	workspace: ^Workspace,
	tab: int,
	node: layout.Node_Id,
) -> (Workspace_Pane, bool) {
	if workspace == nil || tab < 0 || tab >= len(workspace.tabs) {return {}, false}
	tree := &workspace.tabs[tab].tree
	if int(node) >= len(tree.nodes) {return {}, false}
	pane, ok := tree.nodes[node].(layout.Pane)
	if !ok || !pane_owns_session(pane.content.kind) {return {}, false}
	return Workspace_Pane{
		tab = tab,
		node = node,
		content = pane.content,
		session = workspace_session_for_content(app, pane.content),
	}, true
}

// The Terminal pane a tab focuses, or false when the focus is not session content.
@(require_results)
workspace_focused_session_pane :: proc(
	app: ^App,
	workspace: ^Workspace,
	tab: int,
) -> (Workspace_Pane, bool) {
	if workspace == nil || tab < 0 || tab >= len(workspace.tabs) {return {}, false}
	focus := workspace.tabs[tab].tree.focus
	return workspace_session_pane_at(app, workspace, tab, focus)
}
