package main

import "aio:input"
import "aio:layout"
import "aio:links"
import "aio:localpath"
import "aio:platform"
import "aio:render"
import "aio:ui"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"

// What the document menu shows; it is held by Overlay_Document_Menu while the menu shows.
Document_Menu_Mode :: union #no_nil {
	Document_Menu_List,
	Document_Menu_Pin,
	Document_Menu_Link,
}

// Everything the pane can see, and the ways to add to it.
Document_Menu_List :: struct {
	step: Document_Menu_Step,
}

// A step taken inside the list; nil is browsing it. Either one closes before the other opens.
Document_Menu_Step :: union {
	Document_Url_Entry,
	Document_Popout,
}

// An address field in place of the Add URL row.
Document_Url_Entry :: struct {
	// The last submit was not a full http or https address. Editing the field clears it.
	invalid: bool,
}

// The level popout above row `row`'s level button, with `pick` the level the keyboard or pointer is on.
Document_Popout :: struct {
	row:  int,
	pick: Document_Level,
}

// Choosing the level for the document just added. The menu owns document.target.
Document_Menu_Pin :: struct {
	document: Document,
}

// Ctrl+right-click on a terminal link: open it, or choose a level for it. The menu owns document.target.
Document_Menu_Link :: struct {
	document: Document,
}

Document_Menu_Action :: enum {
	None,
	Open,
	Add_File,
	Add_Folder,
	Add_Url,
	Url_Field,
	Pin,
	Open_Link,
}

Document_Menu_Entry :: struct {
	action: Document_Menu_Action,
	level:  Document_Level,
	target: string,
	folder: bool,
}

// Rows hold their own copies of what they show, so a pane closing behind an open menu leaves nothing
// dangling; an action looks its lists up again when it runs. Which pane and mode the rows are for is
// w.overlay.
Document_Menu :: struct {
	using menu:  ui.Menu,
	entries:     [ui.MENU_MAX_ITEMS]Document_Menu_Entry,
	count:       int,
	text:        [dynamic]string,
	url:         ui.Text_Field,
}

@(private = "file", rodata)
DOCUMENT_LEVEL_LABELS := [Document_Level]string {
	.Pane      = "This Pane",
	.Tab       = "This Tab",
	.Workspace = "This Workspace",
}

@(private = "file", rodata)
DOCUMENT_PIN_LABELS := [Document_Level]string {
	.Pane      = "Pin to This Pane",
	.Tab       = "Pin to This Tab",
	.Workspace = "Pin to This Workspace",
}

@(private = "file", rodata)
DOCUMENT_LEVEL_TIPS := [Document_Level]string {
	.Pane      = "Pinned to this pane",
	.Tab       = "Pinned to this tab",
	.Workspace = "Pinned to this workspace",
}

@(private = "file")
document_level_icon :: proc(level: Document_Level) -> ui.Icon {
	switch level {
	case .Pane:
		return .Split_Right
	case .Tab:
		return .Layout_Top
	case .Workspace:
		return .Workspace
	}
	return .Split_Right
}

document_menu_init :: proc(menu: ^Document_Menu) {
	ui.menu_init(&menu.menu)
}

@(private = "file")
document_menu_text_clear :: proc(menu: ^Document_Menu) {
	for text in menu.text {delete(text)}
	clear(&menu.text)
}

// Frees the document a Pin or Link mode holds; overlay_close and document_menu_set call it on leaving one.
document_menu_mode_release :: proc(mode: Document_Menu_Mode) {
	switch m in mode {
	case Document_Menu_List:
	case Document_Menu_Pin:
		delete(m.document.target)
	case Document_Menu_Link:
		delete(m.document.target)
	}
}

// Takes w because a menu still showing when its window is freed holds a document in w.overlay.
document_menu_destroy :: proc(w: ^Window) {
	if state, shown := w.overlay.(Overlay_Document_Menu); shown {document_menu_mode_release(state.mode)}
	menu := &w.document_menu
	document_menu_text_clear(menu)
	delete(menu.text)
	delete(menu.url.bytes)
	ui.menu_destroy(&menu.menu)
}

document_menu_shown :: proc(w: ^Window) -> bool {
	_, shown := w.overlay.(Overlay_Document_Menu)
	return shown
}

// Whether the pane showing `content` draws its Documents button as open: its menu shows, other than
// for a link, which belongs to the pointer rather than the button.
document_menu_shown_for :: proc(w: ^Window, content: layout.Content) -> bool {
	state, shown := w.overlay.(Overlay_Document_Menu)
	if !shown || state.content != content {return false}
	_, link := state.mode.(Document_Menu_Link)
	return !link
}

@(private = "file")
document_menu_state :: proc(w: ^Window) -> ^Overlay_Document_Menu {
	state, _ := &w.overlay.(Overlay_Document_Menu)
	return state
}

// The list's step, or nil outside the list or while the menu is closed.
@(private = "file")
document_list_step :: proc(w: ^Window) -> Document_Menu_Step {
	state := document_menu_state(w)
	if state == nil {return nil}
	list, _ := state.mode.(Document_Menu_List)
	return list.step
}

document_menu_popout :: proc(w: ^Window) -> (Document_Popout, bool) {
	popout, shown := document_list_step(w).(Document_Popout)
	return popout, shown
}

document_menu_url_entry :: proc(w: ^Window) -> (Document_Url_Entry, bool) {
	entry, shown := document_list_step(w).(Document_Url_Entry)
	return entry, shown
}

// How the rows follow a mode change.
@(private = "file")
Document_Rows :: enum u8 {
	Keep,
	Rebuild,
	Rebuild_Select_First,
}

// The only writer of the mode while the menu shows. Leaving Pin or Link frees the document it held.
@(private = "file")
document_menu_set :: proc(app: ^App, w: ^Window, next: Document_Menu_Mode, rows: Document_Rows) {
	state := document_menu_state(w)
	if state == nil {
		document_menu_mode_release(next)
		return
	}
	document_menu_mode_release(state.mode)
	state.mode, w.dirty = next, true
	switch rows {
	case .Keep:
	case .Rebuild: document_menu_build(app, w)
	case .Rebuild_Select_First: document_menu_build(app, w, true)
	}
}

@(private = "file")
document_menu_own :: proc(menu: ^Document_Menu, text: string) -> string {
	owned, err := strings.clone(text)
	if err != nil {return ""}
	if _, append_error := append(&menu.text, owned); append_error != nil {
		delete(owned)
		return ""
	}
	return owned
}

// Each row's payload keys its entry; a row the menu could not take gets none.
@(private = "file")
document_menu_push :: proc(menu: ^Document_Menu, item: ui.Menu_Item, entry: Document_Menu_Entry = {}) {
	row := item
	row.payload = u32(menu.count)
	added, err := ui.menu_add(&menu.menu, row)
	if err != nil {log.errorf("adding a document menu row failed: %v", err)}
	if !added {return}
	menu.entries[menu.count] = entry
	menu.count += 1
}

// The entry row `row` stands for, or none for a row out of range.
@(private = "file")
document_menu_entry :: proc(menu: ^Document_Menu, row: int) -> (Document_Menu_Entry, bool) {
	if row < 0 || row >= len(menu.menu.items) {return {}, false}
	key := int(menu.menu.items[row].payload)
	if key >= menu.count {return {}, false}
	return menu.entries[key], true
}

@(private = "file")
document_menu_build_list :: proc(
	app: ^App,
	menu: ^Document_Menu,
	content: layout.Content,
	list: Document_Menu_List,
) {
	scopes, found := document_scopes(app, content)
	if !found {return}
	rows := documents_visible(scopes)
	for row, i in rows {
		if i > 0 && rows[i - 1].level != row.level {document_menu_push(menu, {separator = true})}
		name, detail := document_label(row.document, context.temp_allocator)
		target := document_menu_own(menu, row.document.target)
		document_menu_push(
			menu,
			{
				label = document_menu_own(menu, name),
				detail = document_menu_own(menu, detail),
				glyph = document_icon(row.document),
				enabled = true,
				action = document_level_icon(row.level),
				selected_action = ui.Icon.Close,
			},
			{action = .Open, level = row.level, target = target, folder = row.document.folder},
		)
	}
	if len(rows) > 0 {document_menu_push(menu, {separator = true})}
	add :: proc(menu: ^Document_Menu, label: string, glyph: ui.Icon, action: Document_Menu_Action) {
		document_menu_push(menu, {label = label, glyph = glyph, enabled = true}, {action = action})
	}
	add(menu, "Add File…", .Document, .Add_File)
	add(menu, "Add Folder…", .Folder, .Add_Folder)
	if url, entering := list.step.(Document_Url_Entry); entering {
		document_menu_push(menu, {}, {action = .Url_Field})
		if url.invalid {
			document_menu_push(menu, {label = "Enter a full http or https address.", danger = true})
		}
	} else {
		add(menu, "Add URL…", .Globe, .Add_Url)
	}
	if len(rows) == 0 {document_menu_push(menu, {label = "Or Ctrl+right-click a link"})}
}

@(private = "file")
document_menu_build_levels :: proc(
	app: ^App,
	menu: ^Document_Menu,
	content: layout.Content,
	labels: [Document_Level]string,
) {
	scopes, found := document_scopes(app, content)
	for level in Document_Level {
		if !found || document_scope_list(scopes, level) == nil {continue}
		document_menu_push(
			menu,
			{label = labels[level], glyph = document_level_icon(level), enabled = true},
			{action = .Pin, level = level},
		)
	}
}

// Rebuilds the rows for the current mode, keeping the selection near where it was. It leaves the mode as
// it is: a popout names a row, so the transitions that rebuild leave the popout first.
@(private = "file")
document_menu_build :: proc(app: ^App, w: ^Window, select_first := false) {
	state := document_menu_state(w)
	if state == nil {return}
	menu := &w.document_menu
	selected, scroll := ui.menu_selected(&menu.menu), menu.menu.scroll
	ui.menu_clear(&menu.menu)
	document_menu_text_clear(menu)
	menu.count = 0
	menu.entries = {}
	switch mode in state.mode {
	case Document_Menu_List:
		document_menu_build_list(app, menu, state.content, mode)
	case Document_Menu_Pin:
		name, _ := document_label(mode.document, context.temp_allocator)
		label := fmt.tprintf("Pin %s to", name)
		document_menu_push(menu, {label = document_menu_own(menu, label)})
		document_menu_build_levels(app, menu, state.content, DOCUMENT_LEVEL_LABELS)
	case Document_Menu_Link:
		document_menu_push(menu, {label = "Open", enabled = true}, {action = .Open_Link})
		document_menu_push(menu, {separator = true})
		document_menu_build_levels(app, menu, state.content, DOCUMENT_PIN_LABELS)
	}
	if select_first {
		ui.menu_select_edge(&menu.menu, false)
	} else {
		menu.menu.scroll = scroll
		ui.menu_select(&menu.menu, clamp(selected, 0, max(0, len(menu.menu.items) - 1)))
		if len(menu.menu.items) > 0 && !menu.menu.items[ui.menu_selected(&menu.menu)].enabled {
			ui.menu_step(&menu.menu, 1)
		}
	}
	if _, entering := document_menu_url_entry(w); entering {
		for i in 0 ..< len(menu.menu.items) {
			entry, _ := document_menu_entry(menu, i)
			if entry.action == .Url_Field {ui.menu_select(&menu.menu, i)}
		}
	}
	ui.menu_reveal(&menu.menu, f32(w.width), f32(w.height), w.scale)
	w.dirty = true
}

// Shows the menu for `content`, which takes ownership of any document `mode` holds.
@(private = "file")
document_menu_show :: proc(
	app: ^App,
	w: ^Window,
	content: layout.Content,
	mode: Document_Menu_Mode,
	x, y: f32,
) {
	overlay_open(app, w, Overlay_Document_Menu{content, mode})
	ui.menu_anchor(&w.document_menu.menu, x, y)
	document_menu_build(app, w, true)
}

document_menu_open_pane :: proc(app: ^App, w: ^Window, pane: layout.Pane_Rect) {
	if !CONTENT_POLICY[pane.content.kind].documents {return}
	anchor := pane_header_document_anchor(w, pane)
	document_menu_show(app, w, pane.content, Document_Menu_List{}, anchor.x, anchor.y)
}

// The Show Documents command: the only way to the menu for a split pane with headers off.
document_menu_open_focused :: proc(app: ^App, w: ^Window) {
	tree := window_tree(w)
	if tree == nil {return}
	for pane in w.panes {
		if pane.node != tree.focus {continue}
		if !CONTENT_POLICY[pane.content.kind].documents {
			notify(app, .Info, content_documents_notice(pane.content.kind))
			return
		}
		if !gesture_cancel(app, w) {return}
		document_menu_open_pane(app, w, pane)
		return
	}
}

// Ctrl+right-click on a terminal link. False leaves the press to the terminal.
@(require_results)
document_menu_open_link :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	buffer: [links.TARGET_BYTES]u8 = ---
	spelling, folder := "", false
	switch t in link_resolve(app, w, x, y, buffer[:]) {
	case nil:
		return false
	case Missing_Target:
		target_unavailable(app)
		return true
	case Web_Target:
		spelling = t.uri
	case File_Target:
		spelling, folder = t.path, os.is_dir(t.path)
	}
	pane, found := layout.hit_test(w.panes[:], x, y)
	if !found {return false}
	owned, err := strings.clone(spelling)
	if err != nil {return false}
	document_menu_show(app, w, pane.content, Document_Menu_Link{{owned, folder}}, x, y)
	return true
}

// Back from the file dialog, with the menu it closed, to choose a level.
@(private = "file")
document_menu_show_pin :: proc(app: ^App, w: ^Window, content: layout.Content, document: Document) {
	owned, err := strings.clone(document.target)
	if err != nil {return}
	x, y := w.document_menu.menu.anchor_x, w.document_menu.menu.anchor_y
	document_menu_show(app, w, content, Document_Menu_Pin{{owned, document.folder}}, x, y)
}

@(private = "file")
document_pick_start :: proc(app: ^App, w: ^Window, folders: bool) {
	state := document_menu_state(w)
	if state == nil || app.dialogs.document != nil {return}
	content := state.content
	if !gesture_cancel(app, w) {return}
	overlay_close(app, w)
	directory := ""
	if entry := workspace_session_for_content(app, content); entry != nil {
		directory, _ = pane_directory(app, entry)
	}
	pick := platform.file_pick_start(&app.platform, w.id, "All files", "*.*", directory, folders)
	if pick == nil {
		notify(app, .Error, "Could not show the file dialog.")
		return
	}
	app.dialogs.document = Document_Pick{{pick, w.id}, content}
}

// Pins what Add File or Add Folder chose, unless the pane has gone in the meantime.
document_pick_chosen :: proc(app: ^App, w: ^Window, content: layout.Content, path: string) {
	if _, found := document_scopes(app, content); !found {return}
	file, ok := localpath.prepare_open(path)
	if !ok {
		target_unavailable(app)
		return
	}
	defer localpath.open_file_destroy(&file)
	document_menu_show_pin(app, w, content, {file.path, os.is_dir(file.target)})
}

// Pins are app state: every window may be showing a button this changes, and the layout saves them.
@(private = "file")
documents_changed :: proc(app: ^App) {
	layout_state_touch(app)
	for window in app.windows {window.dirty = true}
}

@(private = "file")
document_menu_pin :: proc(app: ^App, w: ^Window, level: Document_Level, document: Document) {
	state := document_menu_state(w)
	if state == nil {return}
	scopes, found := document_scopes(app, state.content)
	if !found {return}
	switch document_pin(scopes, level, document) {
	case .Pinned:
		documents_changed(app)
	case .Level_Full:
		message := fmt.tprintf("%s already has %d documents.", DOCUMENT_LEVEL_LABELS[level], DOCUMENT_LEVEL_LIMIT)
		notify(app, .Warning, message)
	case .Failed:
		notify(app, .Error, "Could not pin the document.")
	}
}

@(private = "file")
document_menu_remove :: proc(app: ^App, w: ^Window, index: int) {
	state := document_menu_state(w)
	menu := &w.document_menu
	if state == nil {return}
	entry, listed := document_menu_entry(menu, index)
	if !listed || entry.action != .Open {return}
	scopes, found := document_scopes(app, state.content)
	if found && document_remove(scopes, entry.level, entry.target) {documents_changed(app)}
	document_menu_build(app, w)
}

@(private = "file")
document_menu_activate :: proc(app: ^App, w: ^Window, index: int) {
	state := document_menu_state(w)
	menu := &w.document_menu
	if state == nil {return}
	entry, listed := document_menu_entry(menu, index)
	if !listed {return}
	switch entry.action {
	case .None, .Url_Field:
	case .Open:
		target := strings.clone(entry.target, context.temp_allocator)
		overlay_close(app, w)
		target_open(app, w, target_from_document(target))
	case .Open_Link:
		link, _ := state.mode.(Document_Menu_Link)
		target := strings.clone(link.document.target, context.temp_allocator)
		overlay_close(app, w)
		target_open(app, w, target_from_document(target))
	case .Add_File:
		document_pick_start(app, w, false)
	case .Add_Folder:
		document_pick_start(app, w, true)
	case .Add_Url:
		ui.field_set(&menu.url, "")
		document_menu_set(app, w, Document_Menu_List{Document_Url_Entry{}}, .Rebuild)
	case .Pin:
		#partial switch mode in state.mode {
		case Document_Menu_Link:
			document_menu_pin(app, w, entry.level, mode.document)
			overlay_close(app, w)
		case Document_Menu_Pin:
			document_menu_pin(app, w, entry.level, mode.document)
			document_menu_set(app, w, Document_Menu_List{}, .Rebuild_Select_First)
		}
	}
}

@(private = "file")
document_menu_url_submit :: proc(app: ^App, w: ^Window) {
	menu := &w.document_menu
	text := strings.trim_space(ui.field_string(&menu.url))
	if !document_is_web(text) {
		document_menu_set(app, w, Document_Menu_List{Document_Url_Entry{invalid = true}}, .Rebuild)
		return
	}
	owned, err := strings.clone(text)
	if err != nil {return}
	document_menu_set(app, w, Document_Menu_Pin{{owned, false}}, .Rebuild_Select_First)
}

// Editing the address clears the complaint about the last one.
@(private = "file")
document_menu_url_edited :: proc(app: ^App, w: ^Window) {
	if url, _ := document_menu_url_entry(w); url.invalid {
		document_menu_set(app, w, Document_Menu_List{Document_Url_Entry{}}, .Rebuild)
	}
	w.dirty = true
}

// The popout takes the list's step, so it ends an address being typed; the rows lose the field first,
// which leaves the documents' rows where they were.
@(private = "file")
document_popout_open :: proc(app: ^App, w: ^Window, index: int) {
	menu := &w.document_menu
	entry, _ := document_menu_entry(menu, index)
	if entry.action != .Open {return}
	if _, entering := document_menu_url_entry(w); entering {
		document_menu_set(app, w, Document_Menu_List{}, .Rebuild)
	}
	document_menu_set(app, w, Document_Menu_List{Document_Popout{index, entry.level}}, .Keep)
}

@(private = "file")
document_popout_close :: proc(app: ^App, w: ^Window) {
	document_menu_set(app, w, Document_Menu_List{}, .Keep)
}

@(private = "file")
document_popout_pick :: proc(app: ^App, w: ^Window, level: Document_Level) {
	popout, shown := document_menu_popout(w)
	if !shown || popout.pick == level {return}
	popout.pick = level
	document_menu_set(app, w, Document_Menu_List{popout}, .Keep)
}

@(private = "file")
document_popout_choose :: proc(app: ^App, w: ^Window, level: Document_Level) {
	popout, shown := document_menu_popout(w)
	if !shown {return}
	menu := &w.document_menu
	entry, _ := document_menu_entry(menu, popout.row)
	document_popout_close(app, w)
	if entry.level == level {return}
	// Rebuilding replaces the text the entry borrows.
	target := strings.clone(entry.target, context.temp_allocator)
	document_menu_pin(app, w, level, {target, entry.folder})
	document_menu_build(app, w)
	// The row moved with its level, so the selection follows it there.
	for i in 0 ..< len(menu.menu.items) {
		if row, _ := document_menu_entry(menu, i); row.action == .Open && row.target == target {
			ui.menu_select(&menu.menu, i)
		}
	}
	ui.menu_reveal(&menu.menu, f32(w.width), f32(w.height), w.scale)
}

// The popout sits above the row's level button, inside the window.
document_popout_rect :: proc(w: ^Window) -> render.Rect {
	menu := &w.document_menu
	popout, _ := document_menu_popout(w)
	s := w.scale
	action := ui.menu_action_rect(&menu.menu, popout.row, .Action, f32(w.width), f32(w.height), s)
	pad := ui.OVERLAY_PADDING * s
	width := f32(len(Document_Level)) * ui.HEIGHT_COMPACT * s + 2 * pad
	height := ui.HEIGHT_COMPACT * s + 2 * pad
	x := action.x + (action.width - width) / 2
	y := action.y - ui.SPACE_1 * s - height
	return {clamp(x, 8 * s, max(8 * s, f32(w.width) - width - 8 * s)), max(8 * s, y), width, height}
}

document_popout_button :: proc(w: ^Window, level: Document_Level) -> render.Rect {
	r := document_popout_rect(w)
	pad := ui.OVERLAY_PADDING * w.scale
	size := ui.HEIGHT_COMPACT * w.scale
	return {r.x + pad + f32(int(level)) * size, r.y + pad, size, size}
}

@(private = "file")
document_popout_hit :: proc(w: ^Window, x, y: f32) -> (Document_Level, bool) {
	for level in Document_Level {
		if render.rect_contains(document_popout_button(w, level), x, y) {return level, true}
	}
	return {}, false
}

document_menu_key :: proc(app: ^App, w: ^Window, raw, logical: input.Key_Event) {
	state := document_menu_state(w)
	if state == nil || !logical.pressed {return}
	menu := &w.document_menu
	switch step in document_list_step(w) {
	case Document_Url_Entry:
		#partial switch raw.key {
		case .Escape:
			document_menu_set(app, w, Document_Menu_List{}, .Rebuild)
		case .Enter, .Numpad_Enter:
			document_menu_url_submit(app, w)
		case:
			field_edit_key(app, &menu.url, raw)
			document_menu_url_edited(app, w)
		}
		return
	case Document_Popout:
		#partial switch logical.key {
		case .Escape:
			document_popout_close(app, w)
		case .Arrow_Left:
			if step.pick > min(Document_Level) {document_popout_pick(app, w, Document_Level(int(step.pick) - 1))}
		case .Arrow_Right:
			if step.pick < max(Document_Level) {document_popout_pick(app, w, Document_Level(int(step.pick) + 1))}
		case .Enter, .Numpad_Enter, .Space:
			document_popout_choose(app, w, step.pick)
		}
		w.dirty = true
		return
	}
	#partial switch logical.key {
	case .Delete:
		document_menu_remove(app, w, ui.menu_selected(&menu.menu))
		return
	case .Arrow_Right:
		document_popout_open(app, w, ui.menu_selected(&menu.menu))
		return
	case .Escape:
		if _, pinning := state.mode.(Document_Menu_Pin); pinning {
			document_menu_set(app, w, Document_Menu_List{}, .Rebuild_Select_First)
			return
		}
	}
	switch ui.menu_key(&menu.menu, logical) {
	case .None:
	case .Changed:
		ui.menu_reveal(&menu.menu, f32(w.width), f32(w.height), w.scale)
		w.dirty = true
	case .Chosen:
		document_menu_activate(app, w, ui.menu_selected(&menu.menu))
	case .Closed:
		overlay_close(app, w)
	}
}

// The wheel moves the selection, which leaves a popout behind.
document_menu_wheel :: proc(app: ^App, w: ^Window, rows: int) {
	if _, shown := document_menu_popout(w); shown {document_popout_close(app, w)}
	menu := &w.document_menu
	ui.menu_wheel(&menu.menu, rows)
	ui.menu_reveal(&menu.menu, f32(w.width), f32(w.height), w.scale)
	w.dirty = true
}

document_menu_text_input :: proc(app: ^App, w: ^Window, text: string) {
	if _, entering := document_menu_url_entry(w); !entering {return}
	if ui.field_text(&w.document_menu.url, text) != .None {document_menu_url_edited(app, w)}
}

@(private = "file")
document_url_box :: proc(w: ^Window) -> (ui.Field_Box, bool) {
	menu := &w.document_menu
	for i in 0 ..< len(menu.menu.items) {
		if entry, _ := document_menu_entry(menu, i); entry.action != .Url_Field {continue}
		rect := ui.menu_row_rect(&menu.menu, i, f32(w.width), f32(w.height), w.scale)
		return ui.field_box_standard(&menu.url, &w.ui_text, rect, w.scale), true
	}
	return {}, false
}

document_menu_hover :: proc(app: ^App, w: ^Window, x, y: f32, left_held: bool) {
	menu := &w.document_menu
	shape := platform.Cursor_Shape.Arrow
	if _, popout := document_menu_popout(w); popout {
		if level, hit := document_popout_hit(w, x, y); hit {
			document_popout_pick(app, w, level)
			shape = .Hand
		}
		pointer_set(app, w, shape)
		return
	}
	if box, shown := document_url_box(w); shown {
		if menu.url.dragging && left_held {
			ui.field_pointer(&menu.url, ui.field_box_offset(box, x), false, true)
			w.dirty = true
		}
		if render.rect_contains(box.rect, x, y) {
			pointer_set(app, w, .Text)
			return
		}
	}
	width, height := f32(w.width), f32(w.height)
	part := ui.Menu_Row_Part.Row
	if hit := ui.menu_hit(&menu.menu, x, y, width, height, w.scale); hit >= 0 {
		item := menu.menu.items[hit]
		if item.enabled && !item.separator {
			if hit != ui.menu_selected(&menu.menu) {ui.menu_select(&menu.menu, hit); w.dirty = true}
			part = ui.menu_row_part(&menu.menu, hit, x, y, width, height, w.scale)
			shape = .Hand
		}
	}
	if part != menu.menu.hover_part {menu.menu.hover_part, w.dirty = part, true}
	pointer_set(app, w, shape)
}

document_menu_tooltip :: proc(_: ^App, w: ^Window, x, y: f32) -> string {
	menu := &w.document_menu
	if _, popout := document_menu_popout(w); popout {
		level, hit := document_popout_hit(w, x, y)
		return hit ? DOCUMENT_LEVEL_LABELS[level] : ""
	}
	width, height := f32(w.width), f32(w.height)
	row := ui.menu_hit(&menu.menu, x, y, width, height, w.scale)
	entry, _ := document_menu_entry(menu, row)
	if entry.action != .Open {return ""}
	switch ui.menu_row_part(&menu.menu, row, x, y, width, height, w.scale) {
	case .Row:
		return ""
	case .Action:
		return DOCUMENT_LEVEL_TIPS[entry.level]
	case .Selected_Action:
		return "Remove"
	}
	return ""
}

document_menu_button :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) {
	menu := &w.document_menu
	if !e.pressed {
		w.dirty = true
		ui.field_release(&menu.url)
		return
	}
	gesture_swallow(w, e.button, .Document_Menu)
	x, y := f32(e.x), f32(e.y)
	if _, popout := document_menu_popout(w); popout {
		if level, hit := document_popout_hit(w, x, y); hit && e.button == .Left {
			document_popout_choose(app, w, level)
		} else {
			document_popout_close(app, w)
		}
		return
	}
	width, height := f32(w.width), f32(w.height)
	hit := ui.menu_hit(&menu.menu, x, y, width, height, w.scale)
	if hit < 0 {
		overlay_close(app, w)
		return
	}
	if e.button != .Left {return}
	if entry, _ := document_menu_entry(menu, hit); entry.action == .Url_Field {
		if box, shown := document_url_box(w); shown {
			ui.field_pointer(&menu.url, ui.field_box_offset(box, x), true, .Shift in e.modifiers)
			w.dirty = true
		}
		return
	}
	item := menu.menu.items[hit]
	if !item.enabled || item.separator {return}
	ui.menu_select(&menu.menu, hit)
	switch ui.menu_row_part(&menu.menu, hit, x, y, width, height, w.scale) {
	case .Row:
		document_menu_activate(app, w, hit)
	case .Action:
		document_popout_open(app, w, hit)
	case .Selected_Action:
		document_menu_remove(app, w, hit)
	}
}

document_menu_draw :: proc(app: ^App, w: ^Window) -> render.Build_Status {
	menu := &w.document_menu
	s := w.scale
	width, height := f32(w.width), f32(w.height)
	if result := ui.menu_draw(&menu.menu, &w.list, &w.ui_text, app.theme, width, height, s, w.pointer);
	   result != .Ok {return result}
	if box, shown := document_url_box(w); shown {
		radius := ui.RADIUS_CONTROL * s
		fill := render.Rect_Instance{rect = box.rect, color = app.theme.pane, radius = radius}
		if render.push_rect(&w.list, fill) != .None {return .Ok}
		edge := render.Rect_Instance{rect = box.rect, color = app.theme.accent, radius = radius, stroke = s}
		if render.push_rect(&w.list, edge) != .None {return .Ok}
		if result := ui.field_box_draw(box, &w.list, app.theme, ui.field_box_baseline(box), true, "https://");
		   result != .Ok {return result}
	}
	popout, shown := document_menu_popout(w)
	if !shown {return .Ok}
	if render.push_layer(&w.list, {0, 0, width, height}) != .None {return .Ok}
	if ui.panel_draw(&w.list, ui.popover_panel(document_popout_rect(w), s), app.theme) != .None {return .Ok}
	entry, _ := document_menu_entry(menu, popout.row)
	current := entry.level
	for level in Document_Level {
		b := ui.Button {
			rect     = document_popout_button(w, level),
			hover    = level == popout.pick && level != current ? 1 : 0,
			radius   = ui.RADIUS_CONTROL,
			selected = level == current,
		}
		face, ink, err := ui.button_draw(&w.list, app.theme, b, s, w.pointer)
		if err != .None {return .Ok}
		ui.icon_draw(&w.list, document_level_icon(level), face, ink, ui.ICON_BUTTON, s)
	}
	return .Ok
}

when AIO_CONTROL {
	// The document menu's keys; documents.mode is list, pin or link, and empty while it is closed.
	document_menu_state_report :: proc(r: ^State_Report, w: ^Window) {
		mode := ""
		if state, shown := w.overlay.(Overlay_Document_Menu); shown {
			switch _ in state.mode {
			case Document_Menu_List: mode = "list"
			case Document_Menu_Pin: mode = "pin"
			case Document_Menu_Link: mode = "link"
			}
		}
		_, popout := document_menu_popout(w)
		_, url_entry := document_menu_url_entry(w)
		state_value(r, "documents.open", document_menu_shown(w))
		state_text(r, "documents.mode", mode)
		state_value(r, "documents.count", w.document_menu.count)
		state_value(r, "documents.popout", popout)
		state_value(r, "documents.url_open", url_entry)
	}
}

// Document menu pointer surface

@(private)
document_menu_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {return document_menu_shown(w)}

@(private)
document_menu_pointer_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: input.Mouse_Move_Event) {
	if owner == .Document_Menu {document_menu_hover(app, w, f32(e.x), f32(e.y), .Left in e.buttons)}
}

@(private)
document_menu_pointer_cancel :: proc(_: ^App, w: ^Window) {
	ui.field_release(&w.document_menu.url)
}

@(private)
document_menu_leave :: proc(_: ^App, w: ^Window) {
	w.document_menu.menu.hover_part = .Row
}
