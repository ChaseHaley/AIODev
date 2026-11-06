package main

import "aio:layout"
import "aio:platform"
import "aio:pty"
import "core:encoding/json"
import "core:log"
import "core:math"
import "core:os"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

// The workspace, tab and split structure that survives a full exit or reboot (D-020). Panes come
// back as fresh shells in their saved directories; running programs are not resumed.
LAYOUT_STATE_VERSION :: 1
// Changes are written this long after the first one, so a burst of edits costs one write and a
// reboot loses at most this much.
LAYOUT_SAVE_DELAY :: 2 * time.Second
// A tree larger than any reachable layout is treated as damage rather than allocated.
LAYOUT_NODE_LIMIT :: 4096

Layout_State :: struct {
	version:          int,
	workspace_number: u32,
	workspaces:       []Saved_Workspace,
}

Saved_Workspace :: struct {
	name:     string,
	icon:     Workspace_Icon,
	selected: int,
	open:     bool,
	tabs:     []Saved_Tab,
	documents: []Document `json:"documents,omitempty"`,
}

// Nodes are stored root first; splits refer to their children by index.
Saved_Tab :: struct {
	name:   string `json:"name,omitempty"`,
	focus:  int,
	zoomed: bool,
	nodes:  []Saved_Node,
	documents: []Document `json:"documents,omitempty"`,
}

Saved_Node :: struct {
	split:     bool,
	axis:      layout.Axis,
	ratio:     f32,
	first:     int,
	second:    int,
	content:   layout.Content_Kind,
	profile:   string `json:"profile,omitempty"`,
	directory: string `json:"directory,omitempty"`,
	name:      string `json:"name,omitempty"`,
	// The file a Markdown pane shows.
	path:      string `json:"path,omitempty"`,
	keep_open: bool,
	// What the pane was running, shown above the fresh shell's prompt when it comes back.
	command:   string `json:"command,omitempty"`,
	linked:    bool,
	// A linked pane's window, as a slice because only an empty one is left out of the file.
	window:    []platform.Window_Placement `json:"window,omitempty"`,
	// A floating pane's place above the tiling, likewise a slice of at most one.
	float:     []Saved_Float `json:"float,omitempty"`,
	documents: []Document `json:"documents,omitempty"`,
}

// Bounds are fractions of the tab's content area; see layout.Float.
Saved_Float :: struct {
	x, y, width, height: f32,
	stack:               u64,
	minimized:           bool,
}

// The saved form of a floating pane's place, in temporary memory, or nil for a tiled pane.
@(private)
layout_float_encode :: proc(pane: layout.Pane) -> []Saved_Float {
	if !pane.floating {return nil}
	saved := make([]Saved_Float, 1, context.temp_allocator)
	b := pane.float.bounds
	saved[0] = {b.x, b.y, b.width, b.height, pane.float.stack, pane.float.minimized}
	return saved
}

@(private)
layout_float_decode :: proc(saved: Saved_Float) -> layout.Float {
	return {
		bounds = layout.float_bounds_clamp({saved.x, saved.y, saved.width, saved.height}),
		stack = saved.stack,
		minimized = saved.minimized,
	}
}

// Schedules a save check; repeated calls before it runs coalesce into one.
layout_state_touch :: proc(app: ^App) {
	if app.layout_path == "" || app.layout_deadline != {} {return}
	app.layout_deadline = time.tick_add(time.tick_now(), LAYOUT_SAVE_DELAY)
}

layout_state_tick :: proc(app: ^App) {
	if app.layout_deadline == {} || time.tick_diff(time.tick_now(), app.layout_deadline) > 0 {return}
	app.layout_deadline = {}
	layout_state_save(app)
}

// Writes the current structure when it differs from the last write. `fresh` reads running
// programs now even without icon polling, as on quit.
layout_state_save :: proc(app: ^App, fresh := false) {
	if app.layout_path == "" {return}
	text, ok := layout_state_encode(app, context.temp_allocator, fresh ? pane_processes(app) : nil)
	if !ok {log.error("encoding the workspace layout failed"); return}
	if text == app.layout_saved {return}
	if !layout_state_write(app.layout_path, text) {return}
	owned, err := strings.clone(text)
	if err != nil {return}
	delete(app.layout_saved)
	app.layout_saved = owned
}

@(require_results)
layout_state_encode :: proc(
	app: ^App,
	allocator := context.allocator,
	processes: []pty.Process_Info = nil,
) -> (
	string,
	bool,
) {
	workspaces := make([dynamic]Saved_Workspace, 0, len(app.workspaces), context.temp_allocator)
	for workspace in app.workspaces {
		if workspace.provisional || len(workspace.tabs) == 0 {continue}
		tabs := make([]Saved_Tab, len(workspace.tabs), context.temp_allocator)
		for tab, i in workspace.tabs {
			nodes := make([dynamic]Saved_Node, 0, len(tab.tree.nodes), context.temp_allocator)
			focus := 0
			if layout_node_encode(app, &tab.tree, tab.tree.root, &nodes, &focus, processes) < 0 {
				return "", false
			}
			tabs[i] = {
				name = tab.name,
				focus = focus,
				zoomed = tab.tree.zoomed,
				nodes = nodes[:],
				documents = tab.documents[:],
			}
		}
		append(
			&workspaces,
			Saved_Workspace {
				name = workspace.name,
				icon = workspace.icon,
				selected = workspace.selected,
				open = window_for_workspace(app, workspace) != nil,
				tabs = tabs,
				documents = workspace.documents[:],
			},
		)
	}
	state := Layout_State {
		version          = LAYOUT_STATE_VERSION,
		workspaces       = workspaces[:],
	}
	data, err := json.marshal(state, {pretty = true, use_enum_names = true}, allocator)
	if err != nil {return "", false}
	return string(data), true
}

@(private)
layout_node_encode :: proc(
	app: ^App,
	tree: ^layout.Layout,
	id: layout.Node_Id,
	nodes: ^[dynamic]Saved_Node,
	focus: ^int,
	processes: []pty.Process_Info,
) -> int {
	if int(id) >= len(tree.nodes) {return -1}
	index := len(nodes)
	switch node in tree.nodes[id] {
	case layout.Vacant:
		return -1
	case layout.Pane:
		saved := layout_pane_encode(app, node.content, processes)
		if node.linked {layout_link_encode(app, tree, id, &saved)}
		saved.float = layout_float_encode(node)
		append(nodes, saved)
		if id == tree.focus {focus^ = index}
	case layout.Split:
		saved := Saved_Node{split = true, axis = node.axis, ratio = node.ratio}
		if node.linked {layout_link_encode(app, tree, id, &saved)}
		append(nodes, saved)
		first := layout_node_encode(app, tree, node.first, nodes, focus, processes)
		second := layout_node_encode(app, tree, node.second, nodes, focus, processes)
		if first < 0 || second < 0 {return -1}
		nodes[index].first, nodes[index].second = first, second
	}
	return index
}

// Marks a saved node as a linked slot and records where its window is.
@(private)
layout_link_encode :: proc(app: ^App, tree: ^layout.Layout, slot: layout.Node_Id, saved: ^Saved_Node) {
	saved.linked = true
	panes := make([dynamic]layout.Content, context.temp_allocator)
	layout.contents(tree, slot, &panes)
	if len(panes) == 0 {return}
	linked := pane_link_window_of(app, panes[0])
	if linked == nil {return}
	if placement, err := platform.window_placement(&app.platform, linked.id); err == .None {
		window := make([]platform.Window_Placement, 1, context.temp_allocator)
		window[0] = placement
		saved.window = window
	}
}

@(private)
layout_pane_encode :: proc(app: ^App, content: layout.Content, processes: []pty.Process_Info) -> Saved_Node {
	saved := Saved_Node{content = content.kind}
	if content.kind == .Markdown {
		if pane := markdown_find(app, content.id); pane != nil {
			saved.path, saved.documents = pane.path, pane.documents[:]
		}
	}
	if !pane_owns_session(content.kind) {return saved}
	entry := session_find(app, content.id)
	if entry == nil {return saved}
	program, command := pane_running(app, entry, processes)
	directory, _ := pane_directory_of(entry, program)
	saved.profile, saved.directory, saved.name = entry.profile_id, directory, entry.name
	saved.keep_open, saved.command = entry.keep_open, command
	saved.documents = entry.documents[:]
	return saved
}

// Replaces the file atomically so a crash mid-write leaves the previous layout intact.
@(private, require_results)
layout_state_write :: proc(path, text: string) -> bool {
	f, err := os.create_temp_file(os.dir(path), ".aiodev-layout-*")
	if err != nil {log.errorf("creating the layout temporary file failed: %v", err); return false}
	name := strings.clone(os.name(f), context.temp_allocator)
	defer if cleanup_error := os.remove(name);
	   cleanup_error != nil && cleanup_error != .Not_Exist {
		log.errorf("removing the layout temporary file failed: %v", cleanup_error)
	}
	n, write_error := os.write(f, transmute([]u8)text)
	sync_error := os.sync(f)
	close_error := os.close(f)
	if write_error != nil || n != len(text) || sync_error != nil || close_error != nil {
		log.errorf(
			"writing the layout failed: %v, %v, %v (%d/%d bytes)",
			write_error,
			sync_error,
			close_error,
			n,
			len(text),
		)
		return false
	}
	if rename_error := os.rename(name, path); rename_error != nil {
		log.errorf("replacing the layout failed: %v", rename_error)
		return false
	}
	return true
}

// Rebuilds the saved workspaces and opens their windows. False leaves startup to create the
// default workspace; anything restored before a failure is kept.
@(require_results)
layout_state_restore :: proc(app: ^App) -> bool {
	if app.layout_path == "" {return false}
	data, read_error := os.read_entire_file(app.layout_path, context.temp_allocator)
	if read_error == .Not_Exist {return false}
	if read_error != nil {
		log.errorf("reading %s failed: %v", app.layout_path, read_error)
		notify(app, .Error, "Could not read the saved workspaces. Starting with a new workspace.")
		return false
	}
	state: Layout_State
	decode_error := json.unmarshal(data, &state, allocator = context.temp_allocator)
	if decode_error != nil || state.version != LAYOUT_STATE_VERSION {
		log.warnf("the saved layout is unreadable: %v (version %d)", decode_error, state.version)
		layout_state_quarantine(app)
		return false
	}
	opened, first: ^Workspace
	for &saved in state.workspaces {
		workspace := layout_workspace_restore(app, &saved)
		if workspace == nil {continue}
		if first == nil {first = workspace}
		if saved.open && window_open(app, workspace) && opened == nil {opened = workspace}
	}
	if opened == nil && first != nil && window_open(app, first) {opened = first}
	return opened != nil
}

// Keeps a damaged file for inspection instead of overwriting it with the new default layout.
@(private)
layout_state_quarantine :: proc(app: ^App) {
	kept := strings.concatenate({app.layout_path, ".bad"}, context.temp_allocator)
	if err := os.rename(app.layout_path, kept); err != nil {
		log.errorf("setting aside the unreadable layout failed: %v", err)
		app.layout_path = ""
		notify(app, .Error, "Could not read the saved workspaces, so layout saving is off this session.")
		return
	}
	notify(app, .Error, "Could not read the saved workspaces. The old file was kept beside it as .bad.")
}

@(private)
layout_workspace_restore :: proc(app: ^App, saved: ^Saved_Workspace) -> ^Workspace {
	workspace := workspace_create_empty(app)
	if workspace == nil {return nil}
	if saved.name != "" && utf8.valid_string(saved.name) {
		if name, err := strings.clone(saved.name); err == nil {
			delete(workspace.name)
			workspace.name = name
		}
	}
	icon := saved.icon
	if icon.preset >= 0 && icon.preset < len(WORKSPACE_ICONS) &&
	   (icon.emoji == "" || workspace_icon_valid(icon.emoji)) {
		if emoji, err := strings.clone(icon.emoji); err == nil {
			workspace.icon = {preset = icon.preset, emoji = emoji}
		}
	}
	if icon.tint >= 0 && icon.tint < len(WORKSPACE_ICON_COLORS) {workspace.icon.tint = icon.tint}
	documents_restore(&workspace.documents, saved.documents)
	selected := saved.selected
	for &tab, i in saved.tabs {
		if !layout_tab_restore(app, workspace, &tab) && i <= saved.selected {selected -= 1}
	}
	if len(workspace.tabs) == 0 {
		_ = workspace_discard_empty(app, workspace)
		return nil
	}
	workspace.selected = clamp(selected, 0, len(workspace.tabs) - 1)
	tab_select_one(workspace, workspace.selected)
	return workspace
}

@(private, require_results)
layout_tab_restore :: proc(app: ^App, workspace: ^Workspace, saved: ^Saved_Tab) -> bool {
	tab, record_error := tab_record_reserve(workspace)
	if record_error != .None {return false}
	if !layout_tree_decode(saved, &tab.tree) {
		log.error("skipping a saved tab with a damaged layout")
		tab_record_free(tab)
		return false
	}
	settings_seen := false
	for &node, i in tab.tree.nodes {
		pane, is_pane := &node.(layout.Pane)
		if !is_pane {continue}
		restored := false
		switch pane.content.kind {
		case .Terminal:
			restored = layout_session_restore(app, &saved.nodes[i])
			if restored {pane.content.id = app.next_session_id}
		case .Settings:
			restored = !settings_seen && !workspace_has_content(workspace, pane.content)
			if restored {settings_seen = true} else {log.error("skipping a saved tab with a second settings page")}
		case .Markdown:
			path := saved.nodes[i].path
			document := path != "" && utf8.valid_string(path) ? markdown_pane_create(app, path, false) : nil
			restored = document != nil
			if restored {
				pane.content.id = document.id
				documents_restore(&document.documents, saved.nodes[i].documents)
			}
		}
		if !restored {
			layout_tab_discard(app, tab)
			return false
		}
	}
	if name, err := strings.clone(saved.name); err == nil {tab.name = name}
	documents_restore(&tab.documents, saved.documents)
	tab_record_commit(app, workspace, tab)
	for i in 0 ..< len(tab.tree.nodes) {
		slot := layout.Node_Id(i)
		if layout.link_root(&tab.tree, slot) == slot {
			pane_link_restore(app, workspace, tab, slot, saved.nodes[i].window)
		}
	}
	return true
}

@(private, require_results)
layout_session_restore :: proc(app: ^App, saved: ^Saved_Node) -> bool {
	// A directory that is remote or no longer exists falls back to the profile's own.
	directory := saved.directory
	if directory != "" && !pty.working_directory_is_local(directory) {
		notify(
			app,
			.Warning,
			"A saved pane directory is remote or unavailable; using the profile's default.",
		)
		directory = ""
	}
	command := saved.command
	if !utf8.valid_string(command) || len(command) > PROGRAM_COMMAND_LIMIT * 4 {command = ""}
	if !session_open(app, "", directory, saved.profile, command) {return false}
	entry := &app.sessions[len(app.sessions) - 1]
	entry.keep_open = saved.keep_open
	documents_restore(&entry.documents, saved.documents)
	if saved.name != "" && utf8.valid_string(saved.name) {
		if name, err := strings.clone(saved.name); err == nil {entry.name = name}
	}
	return true
}

// Closes the sessions a partly restored tab already opened before freeing it.
@(private)
layout_tab_discard :: proc(app: ^App, tab: ^Tab) {
	for node in tab.tree.nodes {
		pane := node.(layout.Pane) or_continue
		if pane_owns_session(pane.content.kind) && pane.content.id != 0 {session_close(app, pane.content.id)}
	}
	tab_record_free(tab)
}

// Rebuilds a tree whose node indices match the saved ones. Every node must be reached exactly
// once from the root, so cycles, shared children and orphans are rejected. Pane content ids are
// left at zero for the caller to fill.
@(require_results)
layout_tree_decode :: proc(saved: ^Saved_Tab, tree: ^layout.Layout) -> bool {
	count := len(saved.nodes)
	if count == 0 || count > LAYOUT_NODE_LIMIT {return false}
	visited, visited_error := make([]bool, count, context.temp_allocator)
	if visited_error != nil {return false}
	nodes, nodes_error := make([dynamic]layout.Node, count)
	if nodes_error != nil {return false}
	tree^ = {nodes = nodes}
	if !layout_node_decode(saved.nodes, 0, visited, tree, false) {layout.destroy(tree); return false}
	for reached in visited {if !reached {layout.destroy(tree); return false}}
	tree.root = 0
	focus := saved.focus
	if focus < 0 || focus >= count || saved.nodes[focus].split {
		for node, i in saved.nodes {if !node.split {focus = i; break}}
	}
	tree.focus = layout.Node_Id(focus)
	tree.zoomed = saved.zoomed
	layout.float_stack_restore(tree)
	layout.links_repair(tree)
	return true
}

@(private, require_results)
layout_node_decode :: proc(
	saved: []Saved_Node,
	index: int,
	visited: []bool,
	tree: ^layout.Layout,
	in_slot: bool,
) -> bool {
	if index < 0 || index >= len(saved) || visited[index] {return false}
	visited[index] = true
	node := saved[index]
	if !node.split {
		if node.content > max(layout.Content_Kind) {return false}
		tree.next_pane_order += 1
		// A pane in a slot shows in its linked window, never floating.
		floating := len(node.float) == 1 && !in_slot && !node.linked
		tree.nodes[index] = layout.Pane {
			content  = {kind = node.content},
			order    = tree.next_pane_order,
			linked   = node.linked && !in_slot && CONTENT_POLICY[node.content].linkable,
			floating = floating,
			float    = floating ? layout_float_decode(node.float[0]) : {},
		}
		return true
	}
	if node.axis != .Horizontal && node.axis != .Vertical {return false}
	if math.is_nan(node.ratio) {return false}
	// A slot holds no slots, and only linkable content can have a linked window.
	linked := node.linked && !in_slot
	if !layout_node_decode(saved, node.first, visited, tree, in_slot || linked) ||
	   !layout_node_decode(saved, node.second, visited, tree, in_slot || linked) {
		return false
	}
	if linked {
		panes := make([dynamic]layout.Content, context.temp_allocator)
		layout.contents(tree, layout.Node_Id(node.first), &panes)
		layout.contents(tree, layout.Node_Id(node.second), &panes)
		for pane in panes {linked &&= CONTENT_POLICY[pane.kind].linkable}
	}
	tree.nodes[index] = layout.Split {
		axis   = node.axis,
		ratio  = clamp(node.ratio, 0.05, 0.95),
		first  = layout.Node_Id(node.first),
		second = layout.Node_Id(node.second),
		linked = linked,
	}
	return true
}
