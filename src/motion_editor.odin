package main

import "aio:settings"
import "aio:ui"
import "core:fmt"

// Saves the selected Motion row: one context's text, or a curve or preset change.
editor_motion_save :: proc(app: ^App, w: ^Window, reset: bool) {
	p := &w.editor
	change, problem := ui.editor_motion_change(p, reset)
	if problem != "" {
		ui.editor_message(p, problem, true)
		return
	}
	result: Settings_Result
	text := "Saved and applied."
	switch c in change {
	case ui.Motion_Text:
		result = settings_change(app, Setting_Value{c.key, c.value}, Settings_Page{p})
	case settings.Motion_Mutation:
		// The names are temporary copies, so the text outlives the page publication rebuilds.
		switch m in c {
		case settings.Motion_Curve_Set:
			text = fmt.tprintf("Saved curve %s.", m.name)
		case settings.Motion_Curve_Remove:
			text = fmt.tprintf("Deleted curve %s.", m.name)
		case settings.Motion_Curve_Rename:
			text = fmt.tprintf("Renamed curve %s to %s.", m.from, m.to)
		case settings.Motion_Preset_Apply:
			text = fmt.tprintf("Applied preset %s.", m.name)
		case settings.Motion_Preset_Save:
			text = fmt.tprintf("Saved preset %s.", m.name)
		case settings.Motion_Preset_Remove:
			text = fmt.tprintf("Deleted preset %s.", m.name)
		}
		result = settings_change(app, c, Settings_Page{p})
	case:
		return
	}
	if !settings_page_report(p, result, .Motion) {
		// Nothing changed in the file, so the page was not rebuilt: show the row's value again, which
		// also clears Save as Preset after saving a preset identical to the one it replaces.
		if row := ui.editor_row(p); result.status == .Unchanged && row != nil {ui.field_set(&p.value, row.value)}
		return
	}
	ui.editor_message(p, text, false)
}
