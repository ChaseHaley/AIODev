package main

when AIO_CONTROL {
	// The verification keys of the web panes: the focused one under web.*, and every pane under
	// web.pane.<id>.* so a script can read panes that do not hold focus.
	web_state_report :: proc(r: ^State_Report, app: ^App, w: ^Window) {
		state_value(r, "web.count", len(app.web_panes))
		state_value(r, "web.active", web_active(w))
		web_pane_state(r, "web", web_focused_pane(app, w))
		for pane in app.web_panes {
			web_pane_state(r, state_key("web.pane.%d", pane.id), pane)
		}
	}

	// One pane's keys under `prefix`; a nil pane reports a blank one.
	@(private = "file")
	web_pane_state :: proc(r: ^State_Report, prefix: string, pane: ^Web_Pane) {
		blank := Web_Pane {
			zoom       = 1,
			find_index = -1,
		}
		p := pane != nil ? pane : &blank
		state_text(r, state_key("%s.kind", prefix), "web")
		state_text(r, state_key("%s.url", prefix), p.url)
		state_text(r, state_key("%s.title", prefix), p.title)
		state_text(r, state_key("%s.host", prefix), p.host_label)
		state_valuef(r, state_key("%s.zoom", prefix), "%g", p.zoom)
		state_value(r, state_key("%s.nav_bar", prefix), p.nav_bar)
		state_value(r, state_key("%s.loading", prefix), p.loading)
		state_value(r, state_key("%s.failed", prefix), p.failed)
		state_word(r, state_key("%s.crashed", prefix), p.crashed)
		state_value(r, state_key("%s.find_count", prefix), p.find_count)
		state_value(r, state_key("%s.find_index", prefix), p.find_index)
		state_value(r, state_key("%s.find_failed", prefix), p.find_failed)
	}
}
