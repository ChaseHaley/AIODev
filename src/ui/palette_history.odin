package ui

import "aio:commands"
import "aio:frecency"
import "aio:input"
import "core:log"
import "core:strings"

// What the palette has run, keyed by stable identity rather than display text. Command names and setting
// keys hold across restarts, so the app saves those tables; tab and workspace ids hold only while the app
// runs, so their tables last one session.
Palette_Usage :: struct {
	commands, settings: frecency.Table(string),
	tabs, workspaces:   frecency.Table(u64),
}

// One item a palette opening has counted: a command name or setting key, which the registry and schema
// own for longer than any opening, or a tab or workspace id.
Palette_Use :: struct {
	kind: Palette_Kind,
	name: string,
	id:   u64,
}

Palette_History :: Query_History(Palette_Mode)

// Any of these held turns Up and Down back into list keys.
@(private) PALETTE_RECALL_BLOCKERS :: input.Modifiers{.Shift, .Control, .Alt, .Super}

palette_usage_destroy :: proc(u: ^Palette_Usage) {
	frecency.destroy(&u.commands)
	frecency.destroy(&u.settings)
	frecency.destroy(&u.tabs)
	frecency.destroy(&u.workspaces)
}

@(private)
palette_usage_empty :: proc(u: ^Palette_Usage) -> bool {
	tables := len(u.commands.entries) + len(u.settings.entries)
	return tables + len(u.tabs.entries) + len(u.workspaces.entries) == 0
}

// The result's frecency when the palette opened; 0 for one never used. A use this opening counted was
// recorded at opened_at, where it weighs exactly 1, so taking it back keeps the order fixed while the
// palette stays open and a row the user is adjusting does not move.
palette_frecency :: proc(p: ^Palette, r: Palette_Result) -> f64 {
	use, usable := palette_result_use(p, r)
	if !usable {return 0}
	now := p.opened_at
	score: f64
	switch use.kind {
	case .Command:
		score = frecency.lookup(&p.usage.commands, use.name, now)
	case .Setting:
		score = frecency.lookup(&p.usage.settings, use.name, now)
	case .Tab:
		score = frecency.lookup(&p.usage.tabs, use.id, now)
	case .Workspace:
		score = frecency.lookup(&p.usage.workspaces, use.id, now)
	case .Unassigned:
	}
	for counted in p.counted {
		if counted == use {return max(0, score - 1)}
	}
	return score
}

// The identity a result's uses count under; false for the Unassigned row.
@(private)
palette_result_use :: proc(p: ^Palette, r: Palette_Result) -> (Palette_Use, bool) {
	switch r.kind {
	case .Command:
		if r.command != nil {return {kind = .Command, name = r.command.name}, true}
	case .Setting:
		if r.setting >= 0 && r.setting < len(p.settings) {
			return {kind = .Setting, name = p.settings[r.setting].key}, true
		}
	case .Tab, .Workspace:
		return {kind = r.kind, id = r.id}, true
	case .Unassigned:
	}
	return {}, false
}

// Counts one use of an item: running or opening it, changing its value in place, or opening its
// shortcut editor. Each item counts at most once per opening, so ten Alt+Right steps on a slider are
// one use, like one Enter.
@(private)
palette_use :: proc(p: ^Palette, use: Palette_Use) {
	for counted in p.counted {
		if counted == use {return}
	}
	if _, err := append(&p.counted, use); err != nil {
		log.warn("palette: no room to note a use")
		return
	}
	now := p.opened_at
	recorded := true
	switch use.kind {
	case .Command:
		recorded = frecency.record(&p.usage.commands, use.name, now)
	case .Setting:
		recorded = frecency.record(&p.usage.settings, use.name, now)
	case .Tab:
		recorded = frecency.record(&p.usage.tabs, use.id, now)
	case .Workspace:
		recorded = frecency.record(&p.usage.workspaces, use.id, now)
	case .Unassigned:
	}
	if !recorded {
		log.warn("palette: no room to record a use")
		pop(&p.counted)
		return
	}
	p.used = true
}

// Whether a use was recorded since the owner last asked, so it can schedule saving the usage.
palette_used_take :: proc(p: ^Palette) -> bool {
	used := p.used
	p.used = false
	return used
}

// Counts one run of the result and records the query that found it.
@(private)
palette_record :: proc(p: ^Palette, r: Palette_Result) {
	if p.keys.state == .Off {query_history_add(&p.history, palette_query(p), p.mode)}
	if use, usable := palette_result_use(p, r); usable {palette_use(p, use)}
}

// Leaves history browsing, freeing the draft; the query keeps what browsing put there.
@(private)
palette_browse_end :: proc(p: ^Palette) {
	if browse, browsing := p.browse.?; browsing {delete(browse.draft.query)}
	p.browse = nil
}

// Up and Down recall earlier queries like the find bar. Up starts at an empty query with the first
// result selected, where it could not move the selection. While the recalled query stands unchanged,
// Up and Down step through history, and Down past the newest entry brings back the empty query.
// Anywhere else they move the selection, as Ctrl+P and Ctrl+N always do. False leaves the key to the
// list.
@(private)
palette_recall_key :: proc(
	p: ^Palette,
	registry: ^commands.Registry,
	e: input.Key_Event,
) -> (
	Outcome,
	bool,
) {
	older := false
	#partial switch e.key {
	case .Arrow_Up:
		older = true
	case .Arrow_Down:
	case:
		return .None, false
	}
	if e.modifiers & PALETTE_RECALL_BLOCKERS != {} || p.keys.state != .Off || p.assign != nil {
		return .None, false
	}
	query := palette_query(p)
	index := -1
	if browse, browsing := p.browse.?; browsing {
		entries := p.history.entries[:]
		if browse.index < len(entries) && entries[browse.index].query == query &&
		   entries[browse.index].options == p.mode {
			index = browse.index
		} else {
			palette_browse_end(p)
		}
	}
	if index < 0 && !(older && query == "" && p.selected == 0) {return .None, false}
	next, ok := query_history_step(&p.history, index, query, older)
	switch {
	case !ok:
		// At the oldest entry Up stays put rather than moving the selection under a recalled query.
		return .None, index >= 0
	case next < 0:
		palette_show(p, registry, p.browse.?.draft)
		palette_browse_end(p)
	case index >= 0:
		if browse, browsing := &p.browse.?; browsing {browse.index = next}
		palette_show(p, registry, p.history.entries[next])
	case:
		// Browsing must be able to restore the draft, so without a copy of it nothing is recalled.
		copied, err := strings.clone(query)
		if err != nil {return .None, false}
		p.browse = Query_Browse(Palette_Mode){next, {copied, p.mode}}
		palette_show(p, registry, p.history.entries[next])
	}
	return .Changed, true
}

@(private)
palette_show :: proc(p: ^Palette, registry: ^commands.Registry, entry: Query_Entry(Palette_Mode)) {
	field_set(&p.query, entry.query)
	p.mode = entry.options
	p.selected, p.scroll = 0, 0
	refresh(p, registry)
}
