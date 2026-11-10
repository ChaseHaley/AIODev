package main

import "aio:settings"
import "aio:ui"
import "core:strings"

// How a reveal sets the settings search before it selects its row.
Reveal_Search :: enum {
	// Show every row, so a jump never inherits a search that hides the target.
	Clear,
	// Show only the caller's query, such as the shortcut key prefix.
	Scope,
	// Keep the current search, including across a reload.
	Preserve,
}

// Whether a reveal moves keyboard focus into the selected row, for a jump that wants typing next.
Reveal_Focus :: enum {
	None,
	Control,
}

// Parts of the page a command or the palette jumps to by name rather than by row. A section with
// a query shows only its rows; one with a palette key is listed in the palette's settings.
Settings_Section :: enum {
	None,
	Profiles,
	Link_Programs,
	Shortcuts,
	Colors,
	Motion,
}

Settings_Section_Info :: struct {
	title, palette_key, query: string,
}

@(rodata)
SETTINGS_SECTIONS := [Settings_Section]Settings_Section_Info {
	.None          = {},
	.Profiles      = {title = "Profiles", palette_key = "profiles"},
	.Link_Programs = {title = "Link Programs", palette_key = "link_programs"},
	.Shortcuts     = {query = settings.KEY_BINDING_PREFIX},
	.Colors        = {query = SETTINGS_COLOR_PREFIX},
	.Motion        = {title = "Motion", query = settings.MOTION_PREFIX},
}

// The key prefix of the active theme's color rows.
SETTINGS_COLOR_PREFIX :: "colors."

// One settings row or section to show. Callers name their target and the policy; the reveal owns
// the order.
Settings_Reveal :: struct {
	key:         string,
	section:     Settings_Section,
	query:       string,
	search:      Reveal_Search,
	focus:       Reveal_Focus,
	message:     string,
	// Keep the page scrolled where it was, as a save on the page does.
	keep_scroll: bool,
}

// Shows the settings tab, creating and loading it when the app has none, then reveals its row.
settings_reveal :: proc(app: ^App, w: ^Window, reveal: Settings_Reveal) {
	shown := editor_open(app, w)
	if shown == nil || !settings_active(shown) {return}
	settings_reveal_page(&shown.editor, reveal)
}

// The order is the invariant: the search is settled before the filter rebuilds the page, and the
// target is selected after it, since a rebuild would otherwise select the first row.
settings_reveal_page :: proc(p: ^ui.Editor, reveal: Settings_Reveal) {
	scroll := p.scroll
	query, search := reveal.query, reveal.search
	// A section with a query shows only its rows.
	if section := SETTINGS_SECTIONS[reveal.section]; section.query != "" {query, search = section.query, .Scope}
	if search == .Clear {
		query = ""
	} else if search == .Preserve {
		query = strings.clone(ui.field_string(&p.filter), context.temp_allocator)
	}
	ui.field_set(&p.filter, query)
	ui.editor_filter(p)
	target := settings_reveal_target(reveal)
	selected := target != nil && ui.editor_reveal(p, target.?)
	if reveal.focus == .Control && selected {
		// Shortcut rows capture chords instead of typing, so they keep focus in the search.
		if row := ui.editor_row(p); row != nil && row.kind != .Shortcut {ui.editor_focus_row(p)}
	}
	if reveal.keep_scroll {ui.editor_scroll_keep(p, scroll)}
	if reveal.message != "" {ui.editor_message(p, reveal.message, false)}
}

// The row a reveal selects: a section's own target, the program groups editor, or the named row.
// Motion keys name rows of their own, so they reveal like any other row.
@(private)
settings_reveal_target :: proc(reveal: Settings_Reveal) -> Maybe(ui.Reveal_Target) {
	section := reveal.section
	for info, candidate in SETTINGS_SECTIONS {
		if info.palette_key != "" && info.palette_key == reveal.key {section = candidate}
	}
	if section == .Profiles {return ui.Reveal_Profiles{}}
	if section == .Link_Programs {return ui.Reveal_Openers{}}
	if reveal.key == "" {return nil}
	if reveal.key == settings.PADDING_GROUPS_KEY {return ui.Reveal_Program_Groups{}}
	return ui.Reveal_Row{reveal.key}
}

