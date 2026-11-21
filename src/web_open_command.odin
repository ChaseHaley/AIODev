package main

import "aio:commands"
import "aio:layout"
import "aio:links"

// Explicit --float opens a separate float. Otherwise use the requested split direction or the
// floating preference, which keeps splits from an already floating pane inside that float.
@(require_results)
control_web_open :: proc(
	app: ^App,
	w: ^Window,
	target: Pane_Target,
	invocation: commands.Invocation,
) -> Outcome {
	explicit_float := .Float in invocation.given
	url := ""
	if .Text in invocation.given {
		normalized, ok := links.normalize_web_input(invocation.text)
		if !ok {
			return outcome_failure(.Usage, "give a web address, local file:/// URL, or absolute file path")
		}
		url = normalized
	}
	workspace := target.workspace
	tab := target.pane.tab
	node := target.pane.node
	tree := &workspace.tabs[tab].tree
	// A requested direction asks for a split, whatever the floating preference.
	prefer_float := app.settings.pane.web_floating && .Direction not_in invocation.given &&
		!layout.is_floating(tree, node)
	placement: Pane_Placement = explicit_float || prefer_float ? .Float : .Split_Right
	pane := web_pane_create(app, url)
	if pane == nil {return outcome_failure(.Failed, "could not open a web pane")}
	if url == "" {pane.nav_bar, pane.url_editing = true, true}
	// An unplaced pane is dropped by the next web poll.
	if !pane_place(
		app,
		w,
		workspace,
		tab,
		node,
		layout.Content{.Web, pane.id},
		placement,
		invocation.focus,
		invocation.ratio,
		invocation.direction,
	) {
		return outcome_failure(.Failed, "could not open a web pane")
	}
	if w != nil {w.dirty = true}
	return {}
}
