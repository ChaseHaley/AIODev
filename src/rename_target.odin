package main

import "core:strings"

// What a rename names. A tab is found within its workspace and a pane by its terminal session, so the
// window that presents the field need not hold the target.
Rename_Target :: union {
	Rename_Tab_Target,
	Rename_Pane_Target,
	Rename_Workspace_Target,
}

Rename_Tab_Target :: struct {
	workspace, tab: u32,
}

Rename_Pane_Target :: struct {
	session: u32,
}

Rename_Workspace_Target :: struct {
	workspace: u32,
}

// What an empty name means to the editor that typed it. Every editor cleans the name the same way.
Rename_Intent :: enum {
	// A tab or pane: empty restores the automatic title.
	Automatic_Title,
	// The workspace chip: empty keeps the current name, and the chip closes.
	Workspace_Chip,
	// The picker's row editor: empty is refused, and the editor stays open with its error.
	Workspace_Row,
}

Rename_Outcome :: enum {
	Saved,
	Empty,   // A row editor's workspace name cannot be empty.
	Missing, // The target no longer exists.
	Failed,  // The cleaned name could not be stored.
}

// A name as typed, cleaned as every rename stores it.
rename_clean :: proc(value: string) -> string {
	return display_title(strings.trim_space(value), context.temp_allocator)
}

// Resolves the target by id at commit, so a target closed while the field is open reports .Missing
// instead of writing through a stale pointer. Tab and pane names refresh the titles of every window that
// shows them; workspace names repaint every window. An empty name under .Workspace_Chip saves nothing.
@(require_results)
rename_target_commit :: proc(
	app: ^App,
	target: Rename_Target,
	value: string,
	intent: Rename_Intent,
) -> Rename_Outcome {
	destination := rename_target_destination(app, target)
	if destination == nil {return .Missing}
	clean := rename_clean(value)
	if clean == "" {
		switch intent {
		case .Automatic_Title:
		case .Workspace_Chip: return .Saved
		case .Workspace_Row: return .Empty
		}
	}
	name, err := strings.clone(clean)
	if err != nil {return .Failed}
	delete(destination^)
	destination^ = name
	switch t in target {
	case Rename_Tab_Target:
		workspace := workspace_find(app, t.workspace)
		for tab in workspace.tabs {tab_update_title(app, tab)}
		if owner := window_for_workspace(app, workspace); owner != nil {
			window_update_title(app, owner)
			owner.dirty = true
		}
	case Rename_Pane_Target:
		session_titles_changed(app, t.session)
	case Rename_Workspace_Target:
		for window in app.windows {window_relayout(app, window)}
		workspace_mutation_finish(app, workspace_find(app, t.workspace), {.Names})
	}
	return .Saved
}

// Names a workspace's tab as its rename field does; an empty name restores the automatic title.
@(require_results)
tab_name_set :: proc(app: ^App, workspace: ^Workspace, tab: ^Tab, name: string) -> bool {
	target := Rename_Tab_Target{workspace.id, tab.id}
	return rename_target_commit(app, target, name, .Automatic_Title) == .Saved
}

// The name a target stores, or nil when it no longer exists.
@(private)
rename_target_destination :: proc(app: ^App, target: Rename_Target) -> ^string {
	switch t in target {
	case Rename_Tab_Target:
		workspace := workspace_find(app, t.workspace)
		if workspace == nil {return nil}
		if index := tab_index_by_id(workspace, t.tab); index >= 0 {return &workspace.tabs[index].name}
	case Rename_Pane_Target:
		if entry := session_find(app, t.session); entry != nil {return &entry.name}
	case Rename_Workspace_Target:
		if workspace := workspace_find(app, t.workspace); workspace != nil {return &workspace.name}
	}
	return nil
}
