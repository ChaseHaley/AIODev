package main

import "aio:events"
import "aio:input"
import "aio:layout"
import "aio:procinfo"
import "aio:settings"
import "aio:term"
import "core:strings"

// What a window last reported as focused, so focus events fire only on a real change.
App_Event_Focus :: struct {
	pane, tab, workspace: u32,
}

@(private)
Event_Pane :: struct {
	pane: u32,
}

@(private)
Event_Pane_Place :: struct {
	pane, tab, workspace: u32,
}

@(private)
Event_Pane_Exit :: struct {
	pane, exit_code: u32,
}

// pane.closed carries the exit code only when the pane's exit was observed.
@(private)
Event_Pane_Closed :: struct {
	pane:      u32,
	exit_code: Maybe(u32) `json:"exit_code,omitempty"`,
}

@(private)
Event_Pane_Focus :: struct {
	pane, previous: u32,
}

@(private)
Event_Pane_Title :: struct {
	pane:  u32,
	title: string,
}

@(private)
Event_Pane_Cwd :: struct {
	pane: u32,
	cwd:  string,
}

@(private)
Event_Pane_Size :: struct {
	pane:       u32,
	cols, rows: u16,
}

@(private)
Event_Pane_Status :: struct {
	pane:            u32,
	status, program: string,
}

@(private)
Event_Pane_Process :: struct {
	pane:    u32,
	process: string,
	pid:     u32,
}

@(private)
Event_Pane_Notification :: struct {
	pane:        u32,
	title, body: string,
}

@(private)
Event_Tab :: struct {
	tab, workspace: u32,
}

@(private)
Event_Tab_Name :: struct {
	tab, workspace: u32,
	name:           string,
}

@(private)
Event_Workspace :: struct {
	workspace: u32,
}

@(private)
Event_Workspace_Name :: struct {
	workspace: u32,
	name:      string,
}

@(private)
Event_Window :: struct {
	window: input.Window_Id,
}

// The fields of settings.reloaded and app.quitting: an empty object.
Event_Empty :: struct {}

// prompt.closed: a dismissed prompt is cancelled, a list answers with index and a dialog with text.
@(private)
Event_Prompt_Closed :: struct {
	prompt:    u64,
	cancelled: bool,
	index:     Maybe(int) `json:"index,omitempty"`,
	text:      Maybe(string) `json:"text,omitempty"`,
}

// The struct each event's fields are marshalled from, which the aio type definitions describe.
// Every push names its kind's struct here.
EVENT_FIELDS :: [events.Kind]typeid {
	.Pane_Created         = Event_Pane_Place,
	.Pane_Closed          = Event_Pane_Closed,
	.Pane_Exited          = Event_Pane_Exit,
	.Pane_Focused         = Event_Pane_Focus,
	.Pane_Title_Changed   = Event_Pane_Title,
	.Pane_Cwd_Changed     = Event_Pane_Cwd,
	.Pane_Bell            = Event_Pane,
	.Pane_Status_Changed  = Event_Pane_Status,
	.Pane_Notification    = Event_Pane_Notification,
	.Pane_Resized         = Event_Pane_Size,
	.Pane_Process_Changed = Event_Pane_Process,
	.Tab_Created          = Event_Tab,
	.Tab_Closed           = Event_Tab,
	.Tab_Selected         = Event_Tab,
	.Tab_Renamed          = Event_Tab_Name,
	.Workspace_Created    = Event_Workspace,
	.Workspace_Deleted    = Event_Workspace,
	.Workspace_Selected   = Event_Workspace,
	.Workspace_Renamed    = Event_Workspace_Name,
	.Window_Created       = Event_Window,
	.Window_Closed        = Event_Window,
	.Window_Focused       = Event_Window,
	.Layout_Changed       = events.Layout_Changed,
	.Settings_Reloaded    = Event_Empty,
	.Settings_Changed     = Setting_Value,
	.Prompt_Closed        = Event_Prompt_Closed,
	.App_Quitting         = Event_Empty,
}

// The words pane.status_changed reports for a stored program status.
@(private)
EVENT_STATUS_WORDS :: [term.Program_Status_State]string {
	.Idle    = "idle",
	.Working = "working",
	.Done    = "done",
	.Blocked = "blocked",
	.Error   = "error",
}

// Hands the tick's events to every consumer, then frees them. Runs once at the end of every tick,
// including ticks the Win32 modal resize loop re-enters, and once more as the app quits. The events
// are taken out of the queue first, so a consumer whose work re-enters tick delivers only what was
// pushed after the take, and cannot free or move the list being delivered here.
app_events_deliver :: proc(app: ^App) {
	app_events_settle(app)
	batch := events.take(&app.events)
	// Consumers receive batch.list[:] here, before the release.
	control_cli_events(app, batch.list[:])
	lua_host_deliver(app, batch.list[:])
	events.release(&app.events, &batch)
}

// Reports what the tick's end decides rather than the moment it happens: panes their trees now hold,
// the arrangement, and where each window's focus came to rest. A command that switches tabs and then
// focuses a pane there moves focus once, so no pane the window only passed through is reported.
app_events_settle :: proc(app: ^App) {
	app_events_panes_attached(app)
	if app.events_focus {
		app.events_focus = false
		for w in app.windows {app_events_focus(app, w)}
	}
	app_events_layout_track(app)
}

// Reports layout.changed when a listed workspace's arrangement differs from the last tick's: the
// workspaces, their tabs in order, and each tree's splits, ratios, floats and zoom. Focus, names and
// grid sizes have events of their own. The digest is taken every tick, without allocating, because the
// revision advances whether or not anyone listens; changes within one tick make one revision.
app_events_layout_track :: proc(app: ^App) {
	digest := u64(len(app.workspaces))
	for workspace in app.workspaces {
		if workspace.provisional {continue}
		digest = app_events_mix(digest, u64(workspace.id))
		digest = app_events_mix(digest, u64(len(workspace.tabs)))
		for tab in workspace.tabs {
			digest = app_events_mix(digest, u64(tab.id))
			digest = app_events_tree_digest(digest, &tab.tree)
		}
	}
	if digest == app.events_layout {return}
	app.events_layout = digest
	events.layout_changed(&app.events)
}

@(private, require_results)
app_events_tree_digest :: proc(digest: u64, tree: ^layout.Layout) -> u64 {
	d := app_events_mix(digest, u64(tree.root))
	d = app_events_mix(d, u64(tree.fill))
	d = app_events_mix(d, tree.fill_float)
	d = app_events_mix(d, app_events_flags(tree.zoomed, false))
	for node in tree.nodes {
		switch n in node {
		case layout.Vacant:
			d = app_events_mix(d, 0)
		case layout.Pane:
			d = app_events_mix(d, 1)
			d = app_events_mix(d, u64(n.content.kind) << 32 | u64(n.content.id))
			d = app_events_mix(d, n.order)
			d = app_events_mix(d, app_events_flags(n.linked, n.floating))
			d = app_events_float_digest(d, n.float)
		case layout.Split:
			d = app_events_mix(d, 2)
			d = app_events_mix(d, u64(n.axis) << 32 | u64(transmute(u32)n.ratio))
			d = app_events_mix(d, u64(n.first) << 32 | u64(n.second))
			d = app_events_mix(d, app_events_flags(n.linked, n.floating))
			d = app_events_float_digest(d, n.float)
		}
	}
	return d
}

// A float's place and state; the pane its focus last held is focus, not arrangement.
@(private, require_results)
app_events_float_digest :: proc(digest: u64, float: layout.Float) -> u64 {
	b := float.bounds
	d := app_events_mix(digest, u64(transmute(u32)b.x) << 32 | u64(transmute(u32)b.y))
	d = app_events_mix(d, u64(transmute(u32)b.width) << 32 | u64(transmute(u32)b.height))
	d = app_events_mix(d, float.stack)
	d = app_events_mix(d, float.id)
	return app_events_mix(d, app_events_flags(float.minimized, float.zoomed))
}

@(private, require_results)
app_events_flags :: proc(first, second: bool) -> u64 {
	flags: u64
	if first {flags |= 1}
	if second {flags |= 2}
	return flags
}

// splitmix64's finalizer over the running digest and the next value, so order matters.
@(private, require_results)
app_events_mix :: proc(digest, value: u64) -> u64 {
	x := (digest ~ value) + 0x9e3779b97f4a7c15
	x = (x ~ (x >> 30)) * 0xbf58476d1ce4e5b9
	x = (x ~ (x >> 27)) * 0x94d049bb133111eb
	return x ~ (x >> 31)
}

// Focus brackets also run when relayout re-enters the same pane. Remember identities independently
// of the bracket's temporary Left state, so these transitions do not invent focus changes. A window
// still Preparing is nobody's yet; window_commit marks it once it shows. A linked window shows a
// private view of a pane, so only its pane focus is reported. Runs from app_events_settle, after the
// panes a window may focus as they open are announced as created.
app_events_focus :: proc(app: ^App, w: ^Window) {
	if w.phase == .Preparing || w.workspace == nil {return}
	next: App_Event_Focus
	if !window_linked(w) {
		next.workspace = w.workspace.id
		if tab := selected_tab(w.workspace); tab != nil {next.tab = tab.id}
	}
	if entry := focused_session(app, w); entry != nil {next.pane = entry.id}
	previous := w.event_focus
	w.event_focus = next
	if next.workspace != 0 && next.workspace != previous.workspace {
		events.push(&app.events, .Workspace_Selected, Event_Workspace{next.workspace})
	}
	if next.tab != 0 && (next.tab != previous.tab || next.workspace != previous.workspace) {
		events.push(&app.events, .Tab_Selected, Event_Tab{next.tab, next.workspace})
	}
	if next.pane != 0 && next.pane != previous.pane {
		events.push(&app.events, .Pane_Focused, Event_Pane_Focus{next.pane, previous.pane})
	}
}

// A session is first registered before it belongs to a tree. Announce it only once the mutation has
// attached it, so every created event names the same tab and workspace as pane.list.
app_events_panes_attached :: proc(app: ^App) {
	if !app.events_unattached {return}
	app.events_unattached = false
	for &entry in app.sessions {
		if entry.event_created {continue}
		workspace, pane, found := session_pane_find(app, entry.id)
		if !found {
			app.events_unattached = true
			continue
		}
		entry.event_created = true
		place := Event_Pane_Place{entry.id, workspace.tabs[pane.tab].id, workspace.id}
		events.push(&app.events, .Pane_Created, place)
	}
}

// Reports how a closing session ended: with its exit code only when its exit was observed.
app_events_pane_closed :: proc(app: ^App, entry: ^Session_Entry, exit_code: u32) {
	if !entry.event_created {return}
	fields := Event_Pane_Closed{pane = entry.id}
	if entry.event_exited {fields.exit_code = exit_code}
	events.push(&app.events, .Pane_Closed, fields)
}

// pane.process_changed names what pane.list reports: the program at `index`, or the shell at `root`
// when the pane has returned to its prompt (`index` < 0).
app_events_process :: proc(
	app: ^App,
	entry: ^Session_Entry,
	processes: []procinfo.Process_Info,
	root: u32,
	index: int,
) {
	if !events.wants(&app.events, .Pane_Process_Changed) {return}
	found := index
	if found < 0 {
		for process, i in processes {
			if process.id == root {found = i; break}
		}
	}
	report := Event_Pane_Process{pane = entry.id}
	if found >= 0 {report.process, report.pid = processes[found].executable, processes[found].id}
	events.push(&app.events, .Pane_Process_Changed, report)
}

// One settings.changed per key a saved revision changes. Schema values include defaults, so removing
// an explicit override reports the effective new value. Other settings families use their decoded
// last assignment, matching the settings file grammar; a removed one reports an empty value.
app_events_settings_commit :: proc(app: ^App, loaded: ^settings.Settings, previous, revision: string) {
	if !events.wants(&app.events, .Settings_Changed) {return}
	for entry in settings.SCHEMA {
		before := settings.value_text(&app.settings, entry)
		after := settings.value_text(loaded, entry)
		if before != after {events.push(&app.events, .Settings_Changed, Setting_Value{entry.key, after})}
	}
	before := app_events_setting_lines(previous)
	after := app_events_setting_lines(revision)
	for key, value in after {
		if old, exists := before[key]; !exists || old != value {
			events.push(&app.events, .Settings_Changed, Setting_Value{key, value})
		}
	}
	for key in before {
		if _, exists := after[key]; !exists {
			events.push(&app.events, .Settings_Changed, Setting_Value{key, ""})
		}
	}
}

// The non-schema assignments in a settings text, keyed by name, in temporary memory.
@(private)
app_events_setting_lines :: proc(source: string) -> map[string]string {
	values := make(map[string]string, context.temp_allocator)
	scanner := settings.line_scanner_init(source)
	for line, ok := settings.line_next(&scanner); ok; line, ok = settings.line_next(&scanner) {
		if !line.split || strings.has_prefix(line.key, "#") || strings.has_prefix(line.key, ";") {continue}
		if settings.schema_find(line.key) != nil {continue}
		value, issue := settings.text_value_decode(line.value)
		if issue == "" {values[line.key] = value}
	}
	return values
}
