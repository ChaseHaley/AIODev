package main

import "aio:frecency"
import "aio:views"
import "core:encoding/json"
import "core:log"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

// What the everything palette has run survives restarts in its own file beside the layout, so its
// frecency order does too (WORK-455). Only command and setting uses are saved: tab and workspace ids
// are handed out again at each launch and would name other tabs.
PALETTE_USAGE_VERSION :: 1
// Uses are written this long after the first one, so a burst of palette runs costs one write.
PALETTE_USAGE_SAVE_DELAY :: 2 * time.Second

Palette_Usage_State :: struct {
	version:  int,
	commands: []Saved_Usage,
	settings: []Saved_Usage,
}

Saved_Usage :: struct {
	key:    string,
	count:  int,
	last:   i64,
	weight: f64,
}

// Saving palette usage. An empty path saves nothing, as in tests; only the real launch sets one. `due` is
// the deadline of a pending write, and `saved` the text last written, so unchanged usage is not written
// again. palette_usage_store_destroy releases both strings.
Palette_Usage_Store :: struct {
	path:  string,
	due:   Maybe(time.Tick),
	saved: string,
}

palette_usage_store_destroy :: proc(store: ^Palette_Usage_Store) {
	delete(store.path)
	delete(store.saved)
	store^ = {}
}

// Saves palette usage to `path`, which the app then owns.
palette_usage_enable :: proc(app: ^App, path: string) {
	palette_usage_store_destroy(&app.palette_store)
	app.palette_store.path = path
}

// Reads the saved usage into the palette. A missing file is a first run; an unreadable one is logged and
// replaced by the next save, since losing the order costs only a few runs to rebuild.
palette_usage_load :: proc(app: ^App) {
	path := app.palette_store.path
	if path == "" {return}
	data, read_error := os.read_entire_file(path, context.temp_allocator)
	if read_error == .Not_Exist {return}
	if read_error != nil {
		log.errorf("reading %s failed: %v", path, read_error)
		return
	}
	state: Palette_Usage_State
	decode_error := json.unmarshal(data, &state, allocator = context.temp_allocator)
	if decode_error != nil || state.version != PALETTE_USAGE_VERSION {
		log.warnf("the saved palette usage is unreadable: %v (version %d)", decode_error, state.version)
		return
	}
	now := time.time_to_unix(clock_wall(&app.clock))
	usage := &app.palette.usage
	for saved in state.commands {
		if !frecency.restore(&usage.commands, saved.key, {saved.count, saved.last, saved.weight}, now) {return}
	}
	for saved in state.settings {
		if !frecency.restore(&usage.settings, saved.key, {saved.count, saved.last, saved.weight}, now) {return}
	}
	if saved, err := strings.clone(string(data)); err == nil {app.palette_store.saved = saved}
}

// Schedules a write; uses recorded before it runs share it.
palette_usage_touch :: proc(app: ^App) {
	if app.palette_store.path == "" || app.palette_store.due != nil {return}
	app.palette_store.due = time.tick_add(clock_now(&app.clock), PALETTE_USAGE_SAVE_DELAY)
}

// Like the layout, the write waits for every motion to settle rather than cost a moving window frames.
palette_usage_deadline :: proc(app: ^App) -> (time.Tick, bool) {
	due, pending := app.palette_store.due.?
	return due, pending && !motion_active(app)
}

palette_usage_tick :: proc(app: ^App) {
	due, pending := app.palette_store.due.?
	if !pending || time.tick_diff(clock_now(&app.clock), due) > 0 || motion_active(app) {return}
	palette_usage_save(app)
}

// Writes pending usage now, when it differs from the last write; quitting calls it so no use waits out
// the delay.
palette_usage_save :: proc(app: ^App) {
	if app.palette_store.due == nil {return}
	app.palette_store.due = nil
	path := app.palette_store.path
	if path == "" {return}
	text, ok := palette_usage_encode(&app.palette.usage, context.temp_allocator)
	if !ok {log.error("encoding the palette usage failed"); return}
	if text == app.palette_store.saved || !file_replace(path, text) {return}
	owned, err := strings.clone(text)
	if err != nil {return}
	delete(app.palette_store.saved)
	app.palette_store.saved = owned
}

@(require_results)
palette_usage_encode :: proc(usage: ^views.Palette_Usage, allocator := context.allocator) -> (string, bool) {
	state := Palette_Usage_State {
		version  = PALETTE_USAGE_VERSION,
		commands = palette_usage_list(&usage.commands),
		settings = palette_usage_list(&usage.settings),
	}
	data, err := json.marshal(state, {pretty = true}, allocator)
	if err != nil {return "", false}
	return string(data), true
}

// The table's entries in key order, so the same usage always writes the same text; in temporary memory.
@(private = "file")
palette_usage_list :: proc(t: ^frecency.Table(string)) -> []Saved_Usage {
	list := make([dynamic]Saved_Usage, 0, len(t.entries), context.temp_allocator)
	for key, u in t.entries {append(&list, Saved_Usage{key, u.count, u.last, u.weight})}
	slice.sort_by(list[:], proc(a, b: Saved_Usage) -> bool {return a.key < b.key})
	return list[:]
}
