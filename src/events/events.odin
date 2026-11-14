package events

import "base:runtime"
import "core:encoding/json"
import "core:mem"
import "core:reflect"

// What happened, in the order and with the names scripts and `aio events` see.
Kind :: enum u8 {
	Pane_Created,
	Pane_Closed,
	Pane_Exited,
	Pane_Focused,
	Pane_Title_Changed,
	Pane_Cwd_Changed,
	Pane_Bell,
	Pane_Status_Changed,
	Pane_Notification,
	Pane_Resized,
	Pane_Process_Changed,
	Tab_Created,
	Tab_Closed,
	Tab_Selected,
	Tab_Renamed,
	Workspace_Created,
	Workspace_Deleted,
	Workspace_Selected,
	Workspace_Renamed,
	Window_Created,
	Window_Closed,
	Window_Focused,
	Layout_Changed,
	Settings_Reloaded,
	Settings_Changed,
	Prompt_Closed,
	App_Quitting,
}

Kinds :: bit_set[Kind;u32]

NAMES :: [Kind]string {
	.Pane_Created         = "pane.created",
	.Pane_Closed          = "pane.closed",
	.Pane_Exited          = "pane.exited",
	.Pane_Focused         = "pane.focused",
	.Pane_Title_Changed   = "pane.title_changed",
	.Pane_Cwd_Changed     = "pane.cwd_changed",
	.Pane_Bell            = "pane.bell",
	.Pane_Status_Changed  = "pane.status_changed",
	.Pane_Notification    = "pane.notification",
	.Pane_Resized         = "pane.resized",
	.Pane_Process_Changed = "pane.process_changed",
	.Tab_Created          = "tab.created",
	.Tab_Closed           = "tab.closed",
	.Tab_Selected         = "tab.selected",
	.Tab_Renamed          = "tab.renamed",
	.Workspace_Created    = "workspace.created",
	.Workspace_Deleted    = "workspace.deleted",
	.Workspace_Selected   = "workspace.selected",
	.Workspace_Renamed    = "workspace.renamed",
	.Window_Created       = "window.created",
	.Window_Closed        = "window.closed",
	.Window_Focused       = "window.focused",
	.Layout_Changed       = "layout.changed",
	.Settings_Reloaded    = "settings.reloaded",
	.Settings_Changed     = "settings.changed",
	.Prompt_Closed        = "prompt.closed",
	.App_Quitting         = "app.quitting",
}

// The kind a dotted name such as "pane.exited" names.
@(require_results)
kind_named :: proc(name: string) -> (Kind, bool) {
	names := NAMES
	for candidate in Kind {
		if names[candidate] == name {return candidate, true}
	}
	return {}, false
}

// One happening: `fields` is a single JSON object, owned by the queue until `clear`.
Event :: struct {
	kind:   Kind,
	fields: string,
}

Consumer :: enum u8 {
	Lua,
	Cli,
}

// Events pushed during one tick. `wanted` is the union of every consumer's interest, so a push of a
// kind nobody listens to costs one bit test. Everything after `revision` is the queue's own storage.
Queue :: struct {
	interest:  [Consumer]Kinds,
	wanted:    Kinds,
	revision:  u64,
	allocator: mem.Allocator,
	list:      [dynamic]Event,
	// Parallel to list: the pane a Pane_Resized event names, so one per pane survives a tick.
	panes:     [dynamic]u32,
}

init :: proc(q: ^Queue, allocator := context.allocator) {
	q^ = {}
	q.allocator = allocator
	q.list = make([dynamic]Event, allocator)
	q.panes = make([dynamic]u32, allocator)
}

destroy :: proc(q: ^Queue) {
	clear(q)
	delete(q.list)
	delete(q.panes)
	q^ = {}
}

set_interest :: proc(q: ^Queue, consumer: Consumer, kinds: Kinds) {
	q.interest[consumer] = kinds
	q.wanted = {}
	for interest in q.interest {q.wanted += interest}
}

@(require_results)
wants :: proc(q: ^Queue, kind: Kind) -> bool {
	return kind in q.wanted
}

// Records an event whose fields are `fields` marshalled to a JSON object. A kind nobody wants is
// dropped before anything is marshalled. Layout_Changed keeps one event per tick and Pane_Resized
// one per pane, each holding the latest fields at the place the first took.
push :: proc(q: ^Queue, kind: Kind, fields: any) {
	if !wants(q, kind) {return}
	data, err := json.marshal(fields, allocator = q.allocator)
	if err != nil {return}
	pane: u32
	if kind == .Pane_Resized {
		value, _ := reflect.as_u64(reflect.struct_field_value_by_name(fields, "pane"))
		pane = u32(value)
	}
	if kind == .Layout_Changed || kind == .Pane_Resized {
		for &event, i in q.list {
			if event.kind != kind || q.panes[i] != pane {continue}
			delete(event.fields, q.allocator)
			event.fields = string(data)
			return
		}
	}
	if _, append_error := append(&q.list, Event{kind, string(data)}); append_error != nil {
		delete(data, q.allocator)
		return
	}
	if _, append_error := append(&q.panes, pane); append_error != nil {
		pop(&q.list)
		delete(data, q.allocator)
	}
}

// Every layout change bumps the revision, wanted or not, so a later reader can tell its view is old.
layout_changed :: proc(q: ^Queue) {
	q.revision += 1
	push(q, .Layout_Changed, struct {
		revision: u64,
	}{q.revision})
}

// The events pushed since the last `clear`, oldest first. Valid until the next `clear`.
@(require_results)
pending :: proc(q: ^Queue) -> []Event {
	return q.list[:]
}

clear :: proc(q: ^Queue) {
	for event in q.list {delete(event.fields, q.allocator)}
	runtime.clear(&q.list)
	runtime.clear(&q.panes)
}

// Events moved out of a queue for delivery. The queue no longer sees them, so whatever a consumer
// pushes, or a tick it re-enters delivers and clears, cannot free or move what is being read.
Batch :: struct {
	list:      [dynamic]Event,
	allocator: mem.Allocator,
}

// Moves the pending events into a batch and leaves the queue empty, with coalescing restarted, so
// later pushes start a new list. The caller hands `batch.list[:]` to consumers, then calls release.
@(require_results)
take :: proc(q: ^Queue) -> Batch {
	batch := Batch{q.list, q.allocator}
	// An empty dynamic array allocates only on its first append, so an idle tick allocates nothing.
	q.list = make([dynamic]Event, q.allocator)
	runtime.clear(&q.panes)
	return batch
}

// Frees a taken batch's fields and storage.
release :: proc(q: ^Queue, batch: ^Batch) {
	for event in batch.list {delete(event.fields, batch.allocator)}
	delete(batch.list)
	batch^ = {}
}
