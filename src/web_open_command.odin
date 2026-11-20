package main

import "aio:commands"
import "aio:layout"
import "aio:links"

// Opens a web pane for `aio pane.open_web <url>` beside the target pane: a split toward the requested
// direction, else a float when pane.web_floating is on (unless the target already floats), else a split to
// the right. With no URL the pane opens blank.
@(require_results)
control_web_open :: proc(
	app: ^App,
	w: ^Window,
	target: Pane_Target,
	invocation: commands.Invocation,
) -> Outcome {
	url := ""
	if .Text in invocation.given {
		normalized, ok := links.normalize_web_input(invocation.text)
		if !ok {return outcome_failure(.Usage, "give an http or https address")}
		url = normalized
	}
	workspace := target.workspace
	tab := target.pane.tab
	node := target.pane.node
	tree := &workspace.tabs[tab].tree
	// A requested direction asks for a split, whatever the floating preference.
	floating := app.settings.pane.web_floating && .Direction not_in invocation.given
	placement: Pane_Placement = floating && !layout.is_floating(tree, node) ? .Float : .Split_Right
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
