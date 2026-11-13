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

// The result's frecency when the palette opened; 0 for one never run.
palette_frecency :: proc(p: ^Palette, r: Palette_Result) -> f64 {
	now := p.opened_at
	switch r.kind {
	case .Command:
		if r.command != nil {return frecency.lookup(&p.usage.commands, r.command.name, now)}
	case .Setting:
		if r.setting >= 0 && r.setting < len(p.settings) {
			return frecency.lookup(&p.usage.settings, p.settings[r.setting].key, now)
		}
	case .Tab:
		return frecency.lookup(&p.usage.tabs, r.id, now)
	case .Workspace:
		return frecency.lookup(&p.usage.workspaces, r.id, now)
	case .Unassigned:
	}
	return 0
}

// Counts one run of the result and records the query that found it.
@(private)
palette_record :: proc(p: ^Palette, r: Palette_Result) {
	if p.keys.state == .Off {query_history_add(&p.history, palette_query(p), p.mode)}
	now := p.opened_at
	recorded := true
	switch r.kind {
	case .Command:
		if r.command != nil {recorded = frecency.record(&p.usage.commands, r.command.name, now)}
	case .Setting:
		if r.setting >= 0 && r.setting < len(p.settings) {
			recorded = frecency.record(&p.usage.settings, p.settings[r.setting].key, now)
		}
	case .Tab:
		recorded = frecency.record(&p.usage.tabs, r.id, now)
	case .Workspace:
		recorded = frecency.record(&p.usage.workspaces, r.id, now)
	case .Unassigned:
	}
	if !recorded {log.warn("palette: no room to record a use")}
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
