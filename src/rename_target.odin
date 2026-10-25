package main

import "aio:settings"
import "core:strings"

Rename_Kind :: enum {Tab, Pane, Workspace}

Rename_Target :: struct {
	kind: Rename_Kind,
	id:   u32,
}

Rename_Outcome :: enum {
	Saved,
	Empty,   // Workspace names cannot be empty; tab and pane names can restore automatic titles.
	Missing, // The target no longer exists.
	Failed,  // The cleaned name could not be stored.
}

// Resolves the target by id at commit, so a target closed while the field is open reports .Missing
// instead of writing through a stale pointer. w presents the field: a tab target belongs to its
// rail, and tab and pane names refresh its titles; workspace names repaint every window.
@(require_results)
rename_target_commit :: proc(
	app: ^App,
	w: ^Window,
	target: Rename_Target,
	value: string,
) -> Rename_Outcome {
	destination := rename_target_destination(app, w, target)
	if destination == nil {return .Missing}
	clean := settings.display_title(strings.trim_space(value), context.temp_allocator)
	if clean == "" && target.kind == .Workspace {return .Empty}
	name, err := strings.clone(clean)
	if err != nil {return .Failed}
	delete(destination^)
	destination^ = name
	switch target.kind {
	case .Tab, .Pane:
		for tab in w.workspace.tabs {tab_update_title(app, tab)}
		window_update_title(app, w)
		w.dirty = true
	case .Workspace:
		for window in app.windows {window_relayout(app, window)}
		workspace_pickers_refresh(app)
	}
	return .Saved
}

@(private)
rename_target_destination :: proc(app: ^App, w: ^Window, target: Rename_Target) -> ^string {
	switch target.kind {
	case .Tab:
		for tab in w.workspace.tabs {
			if tab.id == target.id {return &tab.name}
		}
	case .Pane:
		if entry := session_find(app, target.id); entry != nil {return &entry.name}
	case .Workspace:
		if workspace := workspace_find(app, target.id); workspace != nil {return &workspace.name}
	}
	return nil
}
