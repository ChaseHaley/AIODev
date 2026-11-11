package main

import "aio:layout"
import "aio:platform"
import "aio:procinfo"
import "core:encoding/json"
import "core:log"
import "core:os"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

// The workspace, tab and split structure that survives a full exit or reboot (D-020). Panes come
// back as fresh shells in their saved directories; a pane running a coding agent types its resume
// line into the fresh shell (WORK-361), and other running programs are not resumed.
LAYOUT_STATE_VERSION :: 1
// Changes are written this long after the first one, so a burst of edits costs one write and a
// reboot loses at most this much.
LAYOUT_SAVE_DELAY :: 2 * time.Second
// A tree larger than any reachable layout is treated as damage rather than allocated.
LAYOUT_NODE_LIMIT :: 4096

// Files written before it was dropped also hold an unused `workspace_number`, which reading skips.
Layout_State :: struct {
	version:    int,
	workspaces: []Saved_Workspace,
}

Saved_Workspace :: struct {
	name:     string,
	icon:     Workspace_Icon,
	selected: int,
	open:     bool,
	tabs:     []Saved_Tab,
	documents: []Document `json:"documents,omitempty"`,
}

// Nodes are stored root first; splits refer to their children by index. A tab's view is not saved, so a
// tab comes back in the split view.
Saved_Tab :: struct {
	name:  string `json:"name,omitempty"`,
	focus: int,
	nodes: []Saved_Node,
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
	// The pane's lasting key and, when it ran a coding agent, the command that resumes its session.
	key:       string `json:"key,omitempty"`,
	resume:    string `json:"resume,omitempty"`,
	linked:    bool,
	// A linked pane's window, as a slice because only an empty one is left out of the file.
	window:    []Saved_Window `json:"window,omitempty"`,
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

// A linked window's restored rectangle and maximized state as the layout file stores them. The tags are
// the file's names, so the platform's placement type can change without changing the format.
Saved_Window :: struct {
	left:      i32 `json:"left"`,
	top:       i32 `json:"top"`,
	right:     i32 `json:"right"`,
	bottom:    i32 `json:"bottom"`,
	maximized: bool `json:"maximized"`,
}

// The saved form of a floating pane group's place, in temporary memory, or nil for a tiled node.
@(private)
layout_float_encode :: proc(floating: bool, value: layout.Float) -> []Saved_Float {
	if !floating {return nil}
	saved := make([]Saved_Float, 1, context.temp_allocator)
	b := value.bounds
	saved[0] = {b.x, b.y, b.width, b.height, value.stack, value.minimized}
	return saved
}

// A saved floating place as layout takes it, which brings the bounds into range.
@(private)
layout_float_decode :: proc(saved: Saved_Float) -> layout.Float {
	return {
		bounds = {saved.x, saved.y, saved.width, saved.height},
		stack = saved.stack,
		minimized = saved.minimized,
	}
}

// Saving the layout. nil is Disabled: there is no file, as in tests, or a damaged one could not be set
// aside. Idle has nothing waiting; Scheduled writes a burst of changes at its deadline. Each enabled state
// owns the path, and the procs below are the only writers.
Layout_Save :: union {
	Layout_Save_Idle,
	Layout_Save_Scheduled,
}

Layout_Save_Idle :: struct {
	path: string,
}

Layout_Save_Scheduled :: struct {
	path:     string,
	deadline: time.Tick,
}

// Layout persistence as App embeds it: the save state and the text last written, which a save
// compares against so an unchanged layout is not written again. layout_state_destroy releases both.
Layout_Store :: struct {
	layout_save:  Layout_Save,
	layout_saved: string,
}

layout_state_destroy :: proc(app: ^App) {
	layout_state_disable(app)
	delete(app.layout_saved)
	app.layout_saved = ""
}

// Saves the layout to `path`, which the app then owns.
layout_state_enable :: proc(app: ^App, path: string) {
	layout_state_disable(app)
	app.layout_save = Layout_Save_Idle{path}
}

// Stops saving and drops a pending save with the path.
layout_state_disable :: proc(app: ^App) {
	if path, enabled := layout_state_path(app); enabled {delete(path)}
	app.layout_save = nil
}

layout_state_path :: proc(app: ^App) -> (string, bool) {
	switch save in app.layout_save {
	case Layout_Save_Idle:
		return save.path, true
	case Layout_Save_Scheduled:
		return save.path, true
	}
	return "", false
}

// Saving holds the main thread for a moment, so it waits for every motion to settle rather than cost a
// moving window its frames; the loop wakes for it once nothing moves.
layout_state_deadline :: proc(app: ^App) -> (time.Tick, bool) {
	scheduled, ok := app.layout_save.(Layout_Save_Scheduled)
	return scheduled.deadline, ok && !motion_active(app)
}

// Schedules a save check; repeated calls before it runs coalesce into one.
layout_state_touch :: proc(app: ^App) {
	idle, ok := app.layout_save.(Layout_Save_Idle)
	if !ok {return}
	app.layout_save = Layout_Save_Scheduled{idle.path, time.tick_add(clock_now(&app.clock), LAYOUT_SAVE_DELAY)}
}

layout_state_tick :: proc(app: ^App) {
	scheduled, ok := app.layout_save.(Layout_Save_Scheduled)
	if !ok || time.tick_diff(clock_now(&app.clock), scheduled.deadline) > 0 || motion_active(app) {return}
	app.layout_save = Layout_Save_Idle{scheduled.path}
	layout_state_save(app)
}

// Writes the current structure when it differs from the last write. `fresh` reads running
// programs now even without icon polling, as on quit.
layout_state_save :: proc(app: ^App, fresh := false) {
	path, enabled := layout_state_path(app)
	if !enabled {return}
	text, ok := layout_state_encode(app, context.temp_allocator, fresh ? pane_processes(app) : nil)
	if !ok {log.error("encoding the workspace layout failed"); return}
	if text == app.layout_saved {return}
	if !file_replace(path, text) {return}
	owned, err := strings.clone(text)
	if err != nil {return}
	delete(app.layout_saved)
	app.layout_saved = owned
}

@(require_results)
layout_state_encode :: proc(
	app: ^App,
	allocator := context.allocator,
	processes: []procinfo.Process_Info = nil,
) -> (
	string,
	bool,
) {
	workspaces := make([dynamic]Saved_Workspace, 0, len(app.workspaces), context.temp_allocator)
	for workspace in app.workspaces {
		if workspace.provisional || len(workspace.tabs) == 0 {continue}
		tabs := make([]Saved_Tab, len(workspace.tabs), context.temp_allocator)
		for tab, i in workspace.tabs {
			encoded: bool
			tabs[i], encoded = layout_tab_encode(app, tab, processes)
			if !encoded {return "", false}
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
		version    = LAYOUT_STATE_VERSION,
		workspaces = workspaces[:],
	}
	data, err := json.marshal(state, {pretty = true, use_enum_names = true}, allocator)
	if err != nil {return "", false}
	return string(data), true
}

// A tab as layout state and the closed-tab journal save it, in temporary memory.
@(private, require_results)
layout_tab_encode :: proc(app: ^App, tab: ^Tab, processes: []procinfo.Process_Info) -> (Saved_Tab, bool) {
	nodes, focus, encoded := layout_tree_encode(app, &tab.tree, processes)
	if !encoded {return {}, false}
	return {
			name = tab.name,
			focus = focus,
			nodes = nodes,
			documents = tab.documents[:],
		},
		true
}

// The tree's saved nodes, root first, in temporary memory, and the saved index of its focused pane. False
// for a tree that has lost its shape.
@(private)
layout_tree_encode :: proc(
	app: ^App,
	tree: ^layout.Layout,
	processes: []procinfo.Process_Info,
) -> (
	nodes: []Saved_Node,
	focus: int,
	ok: bool,
) {
	flat := make([dynamic]layout.Flat_Node, 0, len(tree.nodes), context.temp_allocator)
	focus = layout.flatten(tree, &flat) or_return
	nodes = make([]Saved_Node, len(flat), context.temp_allocator)
	for node, i in flat {
		if node.split {
			nodes[i] = {split = true, axis = node.axis, ratio = node.ratio, first = node.first, second = node.second}
		} else {
			nodes[i] = layout_pane_encode(app, node.content, processes)
		}
		if node.linked {layout_link_encode(app, flat[i:], &nodes[i])}
		nodes[i].float = layout_float_encode(node.floating, node.float)
	}
	return nodes, focus, true
}

// Marks a saved node as a linked slot and records where its window is. `slot` starts at the slot's own
// flat node, so its first pane is the slot's first.
@(private)
layout_link_encode :: proc(app: ^App, slot: []layout.Flat_Node, saved: ^Saved_Node) {
	saved.linked = true
	for node in slot {
		if node.split {continue}
		linked := pane_link_window_of(app, node.content)
		if linked == nil {return}
		if placement, err := platform.window_placement(&app.platform, linked.id); err == .None {
			window := make([]Saved_Window, 1, context.temp_allocator)
			window[0] = {placement.left, placement.top, placement.right, placement.bottom, placement.maximized}
			saved.window = window
		}
		return
	}
}

@(private)
layout_pane_encode :: proc(
	app: ^App,
	content: layout.Content,
	processes: []procinfo.Process_Info,
) -> Saved_Node {
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
	saved.key, saved.resume = entry.key, pane_resume_line(app, entry, processes)
	saved.documents = entry.documents[:]
	return saved
}

// Replaces the file atomically so a crash mid-write leaves the previous contents intact.
@(private, require_results)
file_replace :: proc(path, text: string) -> bool {
	f, err := os.create_temp_file(os.dir(path), ".aiodev-*")
	if err != nil {log.errorf("creating a temporary file for %s failed: %v", path, err); return false}
	name := strings.clone(os.name(f), context.temp_allocator)
	defer if cleanup_error := os.remove(name);
	   cleanup_error != nil && cleanup_error != .Not_Exist {
		log.errorf("removing the temporary file %s failed: %v", name, cleanup_error)
	}
	n, write_error := os.write(f, transmute([]u8)text)
	sync_error := os.sync(f)
	close_error := os.close(f)
	if write_error != nil || n != len(text) || sync_error != nil || close_error != nil {
		log.errorf(
			"writing %s failed: %v, %v, %v (%d/%d bytes)",
			path,
			write_error,
			sync_error,
			close_error,
			n,
			len(text),
		)
		return false
	}
	if rename_error := os.rename(name, path); rename_error != nil {
		log.errorf("replacing %s failed: %v", path, rename_error)
		return false
	}
	return true
}

// What layout_state_restore_workspaces rebuilt, in saved order, for layout_state_restore_windows.
// The lists are temporary.
Layout_Restore :: struct {
	workspaces: [dynamic]Layout_Restored,
}

Layout_Restored :: struct {
	workspace: ^Workspace,
	// Whether the workspace had a window open.
	open:      bool,
	links:     [dynamic]Layout_Link,
}

// A linked pane whose window is still to open, where it was saved.
Layout_Link :: struct {
	tab:    ^Tab,
	slot:   layout.Node_Id,
	window: []Saved_Window,
}

// Rebuilds the saved workspaces, whose panes start their shells; layout_state_restore_windows then
// opens their windows, once the graphics device exists. False, with nothing rebuilt, leaves startup
// to create the default workspace.
@(require_results)
layout_state_restore_workspaces :: proc(app: ^App) -> (restore: Layout_Restore, ok: bool) {
	path, enabled := layout_state_path(app)
	if !enabled {return}
	data, read_error := os.read_entire_file(path, context.temp_allocator)
	if read_error == .Not_Exist {return}
	if read_error != nil {
		log.errorf("reading %s failed: %v", path, read_error)
		notify(app, .Error, "Could not read the saved workspaces. Starting with a new workspace.")
		return
	}
	state: Layout_State
	decode_error := json.unmarshal(data, &state, allocator = context.temp_allocator)
	if decode_error != nil || state.version != LAYOUT_STATE_VERSION {
		log.warnf("the saved layout is unreadable: %v (version %d)", decode_error, state.version)
		layout_state_quarantine(app, path)
		return
	}
	restore.workspaces = make([dynamic]Layout_Restored, context.temp_allocator)
	for &saved in state.workspaces {
		restored := Layout_Restored {
			open  = saved.open,
			links = make([dynamic]Layout_Link, context.temp_allocator),
		}
		restored.workspace = layout_workspace_restore(app, &saved, &restored.links)
		if restored.workspace == nil {continue}
		if _, err := append(&restore.workspaces, restored); err != nil {
			// Unlisted, it gets no window now; its linked panes go back to their tabs, losing nothing.
			log.error("listing a restored workspace failed")
			for link in restored.links {
				if !layout.set_linked(&link.tab.tree, link.slot, false) {
					log.error("returning a saved linked pane failed")
				}
			}
		}
	}
	// The panes' shells started side by side, each on a thread of its own.
	for &entry in app.sessions {session_start_finish(&entry)}
	return restore, len(restore.workspaces) > 0
}

// Opens the restored workspaces' linked windows and the windows that were open, or the first
// workspace's if none could open. False leaves startup to create the default workspace; the restored
// workspaces are kept.
@(require_results)
layout_state_restore_windows :: proc(app: ^App, restore: Layout_Restore) -> bool {
	opened: ^Workspace
	for &restored in restore.workspaces {
		for link in restored.links {
			pane_link_restore(app, restored.workspace, link.tab, link.slot, link.window)
		}
		if restored.open && window_open(app, restored.workspace) && opened == nil {
			opened = restored.workspace
		}
	}
	first := restore.workspaces[0].workspace
	if opened == nil && window_open(app, first) {opened = first}
	return opened != nil
}

// Keeps a damaged file for inspection instead of overwriting it with the new default layout.
@(private)
layout_state_quarantine :: proc(app: ^App, path: string) {
	if scheduled, pending := app.layout_save.(Layout_Save_Scheduled); pending {
		app.layout_save = Layout_Save_Idle{scheduled.path}
	}
	kept := strings.concatenate({path, ".bad"}, context.temp_allocator)
	if err := os.rename(path, kept); err != nil {
		log.errorf("setting aside the unreadable layout failed: %v", err)
		layout_state_disable(app)
		notify(app, .Error, "Could not read the saved workspaces, so layout saving is off this session.")
		return
	}
	notify(app, .Error, "Could not read the saved workspaces. The old file was kept beside it as .bad.")
}

// Linked panes' windows wait in `links` for layout_state_restore_windows.
@(private)
layout_workspace_restore :: proc(
	app: ^App,
	saved: ^Saved_Workspace,
	links: ^[dynamic]Layout_Link,
) -> ^Workspace {
	workspace := workspace_create_empty(app)
	if workspace == nil {return nil}
	if saved.name != "" && utf8.valid_string(saved.name) {
		if name, err := strings.clone(saved.name); err == nil {
			delete(workspace.name)
			workspace.name = name
		}
	}
	// Each part is kept on its own: a damaged tint must not cost the workspace a valid preset or emoji.
	icon := saved.icon
	if workspace_icon_valid_value({preset = icon.preset, emoji = icon.emoji}) {
		if emoji, err := strings.clone(icon.emoji); err == nil {
			workspace.icon = {preset = icon.preset, emoji = emoji}
		}
	}
	if workspace_icon_valid_value({tint = icon.tint}) {workspace.icon.tint = icon.tint}
	documents_restore(&workspace.documents, saved.documents)
	selected := saved.selected
	for &tab, i in saved.tabs {
		if !layout_tab_restore(app, workspace, &tab, links) && i <= saved.selected {selected -= 1}
	}
	if len(workspace.tabs) == 0 {
		_ = workspace_discard_empty(app, workspace)
		return nil
	}
	workspace_tab_choose(workspace, clamp(selected, 0, len(workspace.tabs) - 1))
	return workspace
}

// Opens the linked panes' windows and starts the panes' shells. With `links`, as at startup, it
// leaves the windows there for the caller to open and the shells starting for it to finish with
// session_start_finish.
@(private, require_results)
layout_tab_restore :: proc(
	app: ^App,
	workspace: ^Workspace,
	saved: ^Saved_Tab,
	links: ^[dynamic]Layout_Link = nil,
) -> bool {
	tab, reserved := tab_record_reserve(workspace)
	if !reserved {return false}
	if !layout_tree_decode(saved, &tab.tree) {
		log.error("skipping a saved tab with a damaged layout")
		tab_record_free(tab)
		return false
	}
	// Content a workspace holds once may come back once, and only when the workspace lacks it.
	once: bit_set[layout.Content_Kind]
	for &node, i in tab.tree.nodes {
		pane, is_pane := &node.(layout.Pane)
		if !is_pane {continue}
		restored := false
		kind := pane.content.kind
		switch kind {
		case .Terminal:
			pane.content.id, restored = layout_session_restore(app, &saved.nodes[i], links != nil)
		case .Settings:
			restored = true
		case .Markdown:
			path := saved.nodes[i].path
			document := path != "" && utf8.valid_string(path) ? markdown_pane_create(app, path, false) : nil
			restored = document != nil
			if restored {
				pane.content.id = document.id
				documents_restore(&document.documents, saved.nodes[i].documents)
			}
		}
		if restored && CONTENT_POLICY[kind].one_per_workspace {
			restored = kind not_in once && !workspace_has_content(workspace, pane.content)
			if restored {
				once += {kind}
			} else {
				log.errorf("skipping a saved tab with a second %s page", CONTENT_POLICY[kind].display_name)
			}
		}
		if !restored {
			layout_tab_discard(app, tab, i)
			return false
		}
	}
	if name, err := strings.clone(saved.name); err == nil {tab.name = name}
	documents_restore(&tab.documents, saved.documents)
	tab_record_commit(app, workspace, tab)
	for i in 0 ..< len(tab.tree.nodes) {
		slot := layout.Node_Id(i)
		if layout.link_root(&tab.tree, slot) != slot {continue}
		window := saved.nodes[i].window
		if links == nil {
			pane_link_restore(app, workspace, tab, slot, window)
		} else if _, err := append(links, Layout_Link{tab, slot, window}); err != nil {
			log.error("keeping a saved linked pane for later failed")
			if !layout.set_linked(&tab.tree, slot, false) {log.error("returning a saved linked pane failed")}
		}
	}
	return true
}

// Opens the saved pane's session and returns its id. With start_later its shell starts on a thread,
// and the caller finishes it with session_start_finish.
@(private, require_results)
layout_session_restore :: proc(
	app: ^App,
	saved: ^Saved_Node,
	start_later := false,
) -> (
	session: u32,
	ok: bool,
) {
	// A directory that is remote or no longer exists falls back to the profile's own.
	directory, refused := local_launch_directory(saved.directory)
	if refused {
		notify(
			app,
			.Warning,
			"A saved pane directory is remote or unavailable; using the profile's default.",
		)
	}
	command := saved.command
	if !utf8.valid_string(command) || len(command) > PROGRAM_COMMAND_LIMIT * 4 {command = ""}
	resume := app.settings.pane.resume_agents ? saved.resume : ""
	// A pane resuming its agent shows the agent coming back rather than a note about it.
	id, opened := session_open(
		app,
		"",
		directory,
		saved.profile,
		resume != "" ? "" : command,
		saved.key,
		start_later,
	)
	if !opened {return 0, false}
	entry := session_find(app, id)
	entry.keep_open = saved.keep_open
	documents_restore(&entry.documents, saved.documents)
	if saved.name != "" && utf8.valid_string(saved.name) {
		if name, err := strings.clone(saved.name); err == nil {entry.name = name}
	}
	pane_resume(app, entry, resume)
	return id, true
}

// Closes the sessions a partly restored tab opened for its first `restored` nodes, before freeing it.
@(private)
layout_tab_discard :: proc(app: ^App, tab: ^Tab, restored: int) {
	for i in 0 ..< restored {
		content, is_pane := layout.pane_content(&tab.tree, layout.Node_Id(i))
		if is_pane && pane_owns_session(content.kind) {session_close(app, content.id)}
	}
	tab_record_free(tab)
}

// Rebuilds a tree whose node indices match the saved ones; layout.unflatten rejects a damaged tree and
// repairs its detached groups. Pane content ids are left at zero for the caller to fill.
@(require_results)
layout_tree_decode :: proc(saved: ^Saved_Tab, tree: ^layout.Layout) -> bool {
	count := len(saved.nodes)
	if count == 0 || count > LAYOUT_NODE_LIMIT {return false}
	flat, flat_error := make([]layout.Flat_Node, count, context.temp_allocator)
	if flat_error != nil {return false}
	for node, i in saved.nodes {
		flat[i] = {
			split   = node.split,
			axis    = node.axis,
			ratio   = node.ratio,
			first   = node.first,
			second  = node.second,
			content = {kind = node.content},
			linked  = node.linked,
		}
		if len(node.float) == 1 {flat[i].floating, flat[i].float = true, layout_float_decode(node.float[0])}
	}
	linkable: bit_set[layout.Content_Kind]
	for policy, kind in CONTENT_POLICY {if policy.linkable {linkable += {kind}}}
	return layout.unflatten(tree, flat, saved.focus, linkable)
}
