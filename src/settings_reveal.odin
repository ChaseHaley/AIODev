package main

import "aio:font"
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

// One settings row to show. Callers name their key and the policy; the reveal owns the order.
Settings_Reveal :: struct {
	key:     string,
	query:   string,
	search:  Reveal_Search,
	focus:   Reveal_Focus,
	message: string,
	// Reload the page from the settings file before revealing, keeping a preserved search.
	reload: bool,
}

// Shows the settings tab, creating and loading it when the app has none, then reveals its row.
settings_reveal :: proc(app: ^App, w: ^Window, reveal: Settings_Reveal) {
	shown := editor_open(app, w)
	if shown == nil || !settings_active(shown) {return}
	settings_reveal_page(app, &shown.editor, reveal)
}

// The order is the invariant: the search is settled before the filter rebuilds the page, and the key
// is selected after it, since a rebuild would otherwise select the first row.
settings_reveal_page :: proc(app: ^App, p: ^ui.Editor, reveal: Settings_Reveal) {
	query := reveal.query
	if reveal.search == .Clear {
		query = ""
	} else if reveal.search == .Preserve {
		// The reload destroys the search field, so its text is copied out first.
		query = strings.clone(ui.field_string(&p.filter), context.temp_allocator)
	}
	if reveal.reload && !settings_load(app, p) {return}
	ui.field_set(&p.filter, query)
	ui.editor_filter(p)
	selected := reveal.key != "" && ui.editor_reveal(p, reveal.key)
	if reveal.focus == .Control && selected {
		// Shortcut rows capture chords instead of typing, so they keep focus in the search.
		if row := ui.editor_row(p); row != nil && row.kind != .Shortcut {ui.editor_focus_row(p)}
	}
	if reveal.message != "" {ui.editor_message(p, reveal.message, false)}
}

// The palette's view of a setting's current value; a theme also shows its display name.
@(private)
palette_setting_value :: proc(user: rawptr, key: string) -> (value, label: string) {
	app := cast(^App)user
	entry := settings.schema_find(key)
	if entry == nil {return}
	value = settings.value_text(&app.settings, entry^)
	if entry.live_choices == .Themes {label = settings.theme_display_name(&app.settings, value)}
	return
}

@(private)
palette_setting_choices :: proc(user: rawptr, key: string) -> (choices, labels: []string) {
	app := cast(^App)user
	entry := settings.schema_find(key)
	if entry == nil {return}
	fonts, _ := font.installed_families(app.fonts)
	choices, labels, _ = setting_live_choices(&app.settings, fonts, entry.live_choices)
	return
}
