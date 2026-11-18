package main

import platform_api "aio:platform"
import "aio:turns"
import "base:runtime"
import "core:path/filepath"
import "core:strings"
import "core:sync"

// A Markdown pane's file is watched through its folder, so a save by another program shows at once
// instead of at the next 500 ms poll. The poll stays as the fallback for what a watch misses: a
// folder the OS cannot report on, a notification lost to an overflow, a file its writer still held
// open when the notification came.

// Runs on the watch thread. It only records that a folder has news and wakes the main loop, which
// reads the changes in markdown_tick.
@(private)
markdown_watch_wake :: proc "contextless" (data: rawptr) {
	app := (^App)(data)
	sync.atomic_store(&app.markdown_woken, true)
	context = runtime.default_context()
	_ = platform_api.wake(&app.platform)
}

// Starts watching the folder of the pane's file. A pane without a watch keeps to the poll.
@(private)
markdown_watch_start :: proc(app: ^App, pane: ^Markdown_Pane) {
	if pane.watch != 0 {return}
	if app.markdown_watch == nil {
		wake := turns.Watch_Wake{app, markdown_watch_wake}
		set, created := turns.watch_set_create(wake, runtime.heap_allocator())
		if !created {return}
		app.markdown_watch = set
	}
	id, added := turns.watch_set_add(app.markdown_watch, filepath.dir(pane.path), false)
	if added {pane.watch = id}
}

@(private)
markdown_watch_stop :: proc(state: ^Markdown_App, pane: ^Markdown_Pane) {
	if pane.watch == 0 {return}
	turns.watch_set_remove(state.markdown_watch, pane.watch)
	pane.watch = 0
}

// Reads the files of the panes whose folder reported a change to them, or lost track of changes.
@(private)
markdown_watch_drain :: proc(app: ^App) {
	ready := make([dynamic]turns.Watch_Id, context.temp_allocator)
	turns.watch_set_ready(app.markdown_watch, &ready)
	paths := make([dynamic]string, context.temp_allocator)
	changed := false
	for id in ready {
		clear(&paths)
		overflowed, dead := turns.watch_set_take(app.markdown_watch, id, &paths, context.temp_allocator)
		pane: ^Markdown_Pane
		for candidate in app.markdown_panes {
			if candidate.watch == id {pane = candidate}
		}
		if pane == nil {
			if dead {turns.watch_set_remove(app.markdown_watch, id)}
			continue
		}
		// A folder that went away stops reporting; the poll follows the file from here.
		if dead {markdown_watch_stop(&app.markdown_state, pane)}
		touched := overflowed || dead
		name := filepath.base(pane.path)
		for path in paths {
			if strings.equal_fold(path, name) {touched = true}
		}
		if touched {changed = markdown_pane_refresh(app, pane) || changed}
	}
	if changed {mark_all_dirty(app)}
}
