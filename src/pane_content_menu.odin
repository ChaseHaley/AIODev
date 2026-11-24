package main

import "aio:commands"
import "aio:layout"
import "aio:localpath"
import "aio:settings"

@(private, require_results)
pane_content_menu_available :: proc(kind: layout.Content_Kind) -> bool {
	return pane_owns_session(kind) || kind == .Markdown || kind == .Web || kind == .Neovim
}

// A deferred choice still belongs to the same content, and only while this window shows its tree.
@(private, require_results)
pane_content_menu_node :: proc(w: ^Window, content: layout.Content) -> layout.Node_Id {
	tree := window_tree(w)
	if tree == nil {return layout.INVALID_NODE}
	node := layout.find_content(tree, content)
	if node == layout.INVALID_NODE {return node}
	if !window_linked(w) && layout.link_root(tree, node) != layout.INVALID_NODE {return layout.INVALID_NODE}
	return node
}

// `value` names the selected shell profile, the Markdown path or the folder Neovim starts in; a new web pane
// starts blank.
pane_content_menu_choose :: proc(
	app: ^App, w: ^Window, mode: Profile_Menu_Mode, kind: layout.Content_Kind, value: string,
) {
	if target, swap := mode.(Profile_Menu_Swap_Pane); swap {
		node := pane_content_menu_node(w, target.pane)
		if node == layout.INVALID_NODE {return}
		// The profile of the shell behind a Neovim shows that shell, as quitting Neovim does.
		if kind == .Terminal && neovim_shell_show(app, target.pane, value) {
			pane_focus(app, w, node)
			return
		}
		if neovim_unsaved(app, target.pane) {
			notify(app, .Warning, "Neovim has unsaved changes. Save them, or quit Neovim, first.")
			return
		}
		if pane_owns_session(target.pane.kind) {
			if kind == .Terminal {
				pane_shell_swap_request(app, w, node, value)
				return
			}
			// Neovim opens over the shell, which shows again when Neovim quits, so nothing is lost.
			if kind == .Neovim {
				neovim_open_over_menu(app, w, target.pane, value)
				return
			}
			if entry := session_find(app, target.pane.id);
			   entry != nil && entry.status == .Running && .Shell_Switch in app.settings.interface.confirm {
				label := kind == .Web ? "a web pane" : "Markdown"
				pane_swap_ask(app, w, target.pane, entry, kind, "", label, value)
				return
			}
		}
		pane_content_replace(app, w, target.pane, kind, value)
		return
	}
	if split, split_menu := mode.(Profile_Menu_Split); split_menu {
		pane_content_menu_split(app, w, split, kind, value)
		return
	}
	if !pane_minimum_single(app, w) {return}
	content, made := pane_content_make(app, kind, value)
	if !made {return}
	if !pane_new_tab(app, w, w.workspace, content, true) {
		pane_content_discard(app, content)
		notify(app, .Error, "Could not create a tab.")
		return
	}
	layout_state_touch(app)
	rail_overlay_dismiss(app, w)
}

@(private)
pane_content_menu_split :: proc(
	app: ^App, w: ^Window, split: Profile_Menu_Split, kind: layout.Content_Kind, value: string,
) {
	node := pane_content_menu_node(w, split.pane)
	if node == layout.INVALID_NODE {return}
	workspace := w.workspace
	tab := selected_tab(workspace)
	ratio := commands.SPLIT_DEFAULT.ratio
	switch pane_split_check(app, w, tab, node, split.direction, ratio, true) {
	case .None:
	case .Minimum:
		return
	case .Check, .Session, .Layout:
		notify(app, .Error, "Could not check the new pane size.")
		return
	}
	content, made := pane_content_make(app, kind, value)
	if !made {return}
	if pane_split_attach(app, w, workspace, workspace.selected, node, split.direction, ratio, true, content) {
		layout_state_touch(app)
		return
	}
	pane_content_discard(app, content)
	notify(app, .Error, "Could not split the pane.")
}

// Markdown's poll already releases panes that no layout references.
@(private)
pane_content_discard :: proc(app: ^App, content: layout.Content) {
	#partial switch content.kind {
	case .Terminal: session_close(app, content.id)
	case .Web: web_pane_remove(app, content.id)
	case .Neovim: neovim_pane_remove(app, content.id)
	}
}

// A bad file or missing profile leaves the layout unchanged.
@(private, require_results)
pane_content_make :: proc(app: ^App, kind: layout.Content_Kind, value: string) -> (layout.Content, bool) {
	#partial switch kind {
	case .Terminal:
		if _, found := settings.profile_resolve(&app.settings, value); !found {
			notify(app, .Error, "That shell profile is not available.")
			return {}, false
		}
		if id, opened := session_open(app, profile_id = value); opened {return {.Terminal, id}, true}
	case .Markdown:
		file, ok := localpath.prepare_open(value)
		if !ok {target_unavailable(app); return {}, false}
		defer localpath.open_file_destroy(&file)
		if file.confirm || !markdown_is_path(file.target) {
			notify(app, .Warning, "Choose a Markdown file.")
			return {}, false
		}
		if pane := markdown_pane_create(app, file.target, true); pane != nil {return {.Markdown, pane.id}, true}
	case .Web:
		if pane := web_pane_create(app, ""); pane != nil {
			pane.nav_bar, pane.url_editing = true, true
			return {.Web, pane.id}, true
		}
	case .Neovim:
		if pane := neovim_pane_create(app, "", value); pane != nil {return {.Neovim, pane.id}, true}
	}
	notify(app, .Error, "Could not open the pane content.")
	return {}, false
}

// Retains the pane's split, float or linked slot; both copies of a linked pane must name the new content.
@(private)
pane_content_replace :: proc(
	app: ^App, w: ^Window, old: layout.Content, kind: layout.Content_Kind, value: string,
) {
	node := pane_content_menu_node(w, old)
	if node == layout.INVALID_NODE {return}
	tree := window_tree(w)
	workspace := w.workspace
	tab: ^Tab
	home_pane: ^layout.Pane
	if window_linked(w) {
		home, found := pane_link_home(app, old)
		if !found {return}
		workspace, tab = home.workspace, home.tab
		home_pane = &tab.tree.nodes[home.node].(layout.Pane)
	} else {
		tab = selected_tab(workspace)
	}
	content, made := pane_content_make(app, kind, value)
	if !made {return}
	focused := tree.focus == node
	if focused {focus_leave(app, w)}
	pane := &tree.nodes[node].(layout.Pane)
	pane.content = content
	if home_pane != nil {home_pane.content = content}
	focus_jumps_replace(&app.focus_jumps, workspace, old, content)
	if pane_owns_session(old.kind) {session_close(app, old.id)}
	tab_update_title(app, tab)
	workspace_mutation_finish(app, workspace, {.Names})
	window_relayout(app, w)
	if focused {focus_enter(app, w)}
}
