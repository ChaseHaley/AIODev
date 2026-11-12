package main

import "aio:input"
import "aio:render"
import "aio:ui"
import "core:fmt"
import "core:strings"

// These imports are used only when AIO_CONTROL is set.
_ :: fmt
_ :: render

// The settings file's text before and after the last conflict chain save. Undo puts `previous` back
// only while the file still holds `revision`. Owned; empty when there is nothing to undo.
Shortcut_Undo :: struct {
	previous, revision: string,
}

shortcut_undo_destroy :: proc(undo: ^Shortcut_Undo) {
	delete(undo.previous)
	delete(undo.revision)
	undo^ = {}
}

// Saves every change of a resolved conflict chain as one revision computed against `base`; the
// file never holds a duplicate, because the whole revision passes the shortcut check first. A save
// shows "Saved" with Undo. A change that does not apply leaves the chain open and says why.
@(require_results)
shortcut_chain_save :: proc(app: ^App, changes: []ui.Shortcut_Change, base: Settings_Base) -> bool {
	if len(changes) == 0 {return true}
	values := make([]Setting_Value, len(changes), context.temp_allocator)
	for change, i in changes {values[i] = {change.key, change.value}}
	result := settings_change(app, Setting_Values{values}, base)
	if result.status != .Applied {
		if text := settings_result_text(result, .Setting); text != "" {notify(app, .Error, text)}
		return false
	}
	shortcut_undo_destroy(&app.shortcut_undo)
	previous, previous_error := strings.clone(result.previous)
	revision, revision_error := strings.clone(result.revision)
	if previous_error == nil && revision_error == nil {
		app.shortcut_undo = {previous, revision}
	} else {
		delete(previous)
		delete(revision)
	}
	action := app.shortcut_undo.revision != "" ? "Undo" : ""
	ui.notices_put(&app.notices, u32(Notice_Key.Shortcut_Undo), .Success, "Saved", NOTICE_DURATION,
	               app.animations, clock_now(&app.clock), action, action != "" ? "Ctrl+Z" : "")
	mark_all_dirty(app)
	return true
}

// Puts the settings file back as it was before the last chain save, in one write, unless something
// changed the file since.
shortcut_undo :: proc(app: ^App) {
	undo := app.shortcut_undo
	app.shortcut_undo = {}
	defer shortcut_undo_destroy(&undo)
	if undo.revision == "" {return}
	ui.notices_clear(&app.notices, u32(Notice_Key.Shortcut_Undo), app.animations)
	result := settings_change(app, Settings_Restore{undo.previous}, Settings_Expected{undo.revision})
	switch result.status {
	case .Applied, .Unchanged:
		ui.notices_put(&app.notices, u32(Notice_Key.Shortcut_Undo), .Info, "Undone", NOTICE_DURATION,
		               app.animations, clock_now(&app.clock))
		mark_all_dirty(app)
	case .Conflict:
		notify(app, .Error, "Could not undo: the settings file changed after the save.")
	case .Refused, .Unprepared, .Failed:
		notify(app, .Error, settings_result_text(result, .Setting))
	}
}

// Ctrl+Z while the "Saved" notice of a chain save shows undoes that save. Reports whether it took
// the key.
shortcut_undo_key :: proc(app: ^App, e: input.Key_Event) -> bool {
	if !e.pressed || app.shortcut_undo.revision == "" {return false}
	if e.key != .Z || e.modifiers & {.Control, .Shift, .Alt, .Super} != {.Control} {return false}
	if !ui.notices_showing(&app.notices, u32(Notice_Key.Shortcut_Undo)) {
		shortcut_undo_destroy(&app.shortcut_undo)
		return false
	}
	shortcut_undo(app)
	return true
}

when AIO_CONTROL {
	// Where a surface shows a chain member's row and where its chips end.
	Chain_Report_Row :: struct {
		row:   render.Rect,
		right: f32,
		shown: bool,
	}

	// A conflict chain's verification keys under `prefix`: the members' settings keys in order, the
	// selected one, the line above the rows, whether a chip records, and every shown chip as
	// key|label|flags|chip rect|remove rect, joined by ';'. Flags name contested, pending, recording.
	shortcut_chain_state_report :: proc(
		r: ^State_Report,
		prefix: string,
		chain: ^ui.Shortcut_Chain,
		rows: []Chain_Report_Row,
		text: ^ui.Text,
		scale: f32,
	) {
		members := strings.builder_make(context.temp_allocator)
		chips := strings.builder_make(context.temp_allocator)
		selected, summary := "", ""
		if chain != nil && ui.shortcut_chain_active(chain) {
			summary = ui.shortcut_chain_context(chain)
			for member in 0 ..< len(chain.members) {
				key := ui.shortcut_chain_member_key(chain, member)
				if member > 0 {strings.write_byte(&members, ',')}
				strings.write_string(&members, key)
				if member == chain.selected {selected = key}
				if member >= len(rows) || !rows[member].shown {continue}
				row := rows[member]
				for c in ui.shortcut_chain_chip_rects(chain, member, row.row, row.right, text, scale) {
					if strings.builder_len(chips) > 0 {strings.write_byte(&chips, ';')}
					flags := fmt.tprintf("%s%s%s", c.chip.contested ? "contested," : "",
					                     c.chip.pending ? "pending," : "", c.chip.recording ? "recording," : "")
					fmt.sbprintf(&chips, "%s|%s|%s|%g,%g,%g,%g|%g,%g,%g,%g", key, c.chip.label,
					             strings.trim_suffix(flags, ","), c.rect.x, c.rect.y, c.rect.width,
					             c.rect.height, c.remove.x, c.remove.y, c.remove.width, c.remove.height)
				}
			}
		}
		state_text(r, state_key("%s.chain", prefix), strings.to_string(members))
		state_text(r, state_key("%s.chain.selected", prefix), selected)
		state_text(r, state_key("%s.chain.context", prefix), summary)
		state_value(r, state_key("%s.chain.recording", prefix), chain != nil && ui.shortcut_chain_recording(chain))
		state_text(r, state_key("%s.chain.chips", prefix), strings.to_string(chips))
	}
}
