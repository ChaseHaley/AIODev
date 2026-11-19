package main

import "aio:settings"
import "core:hash"
import "core:log"
import "core:os"
import "core:path/filepath"

// What the app remembers of the record the Neovim plugin follows (D-105).
@(private)
Theme_Record :: struct {
	// Of the last record written, taken without its generation, so a settings save that leaves the
	// theme alone writes nothing.
	digest:     u64,
	generation: u64,
}

// The record's path in temporary memory; empty without a data directory, as in tests.
@(private)
theme_record_path :: proc(app: ^App) -> string {
	return settings.neovim_record_path(app.paths.local, context.temp_allocator)
}

// Writes the record when the active theme's content differs from the last one written. A failed write
// is logged and tried again by the next change, since panes read the file the variable names.
@(private)
theme_record_publish :: proc(app: ^App) {
	path := theme_record_path(app)
	if path == "" {return}
	body, body_ok := settings.neovim_record_text(&app.settings, 0, context.temp_allocator)
	if !body_ok {
		log.error("composing the Neovim theme record failed")
		return
	}
	digest := hash.fnv64a(transmute([]u8)body)
	if app.theme_record.generation != 0 && digest == app.theme_record.digest {return}
	generation := app.theme_record.generation + 1
	text, text_ok := settings.neovim_record_text(&app.settings, generation, context.temp_allocator)
	if !text_ok {
		log.error("composing the Neovim theme record failed")
		return
	}
	if err := settings.neovim_record_write(path, text); err != nil {
		log.errorf("writing %s failed: %v", path, err)
		return
	}
	app.theme_record = {digest, generation}
}

// Removes the record this run wrote, so a quit leaves no theme behind in the data directory.
@(private)
theme_record_remove :: proc(app: ^App) {
	path := theme_record_path(app)
	if path == "" || app.theme_record.generation == 0 {return}
	_ = os.remove(path)
	_ = os.remove(filepath.dir(path))
}
