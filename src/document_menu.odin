package main

import "aio:input"
import "aio:layout"
import "aio:links"
import "aio:localpath"
import "aio:platform"
import "aio:pty"
import "aio:render"
import "aio:settings"
import "aio:ui"
import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

// What the Links menu shows; it is held by Overlay_Document_Menu while the menu shows. The list is a search
// field, the other windows showing part of this tab, then pinned documents: files, folders and web addresses.
Document_Menu_Mode :: union #no_nil {
	Document_Menu_List,
	Document_Menu_Pin,
	Document_Menu_Link,
}

// Everything the pane can see, and the ways to add to it.
Document_Menu_List :: struct {
	step: Document_Menu_Step,
}

// A step taken inside the list; nil is browsing it. Only one is open at a time.
Document_Menu_Step :: union {
	Document_Url_Entry,
	Document_Popout,
	Document_Actions,
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

// Row `row`'s right-click menu: what else it can do beyond its click. Its rows are Document_Menu.actions,
// each with a Link_Choice as its payload.
Document_Actions :: struct {
	row: int,
}

// What a link can do (D-085). Open through Open_Folder are offered the same way by the right-click menu of a
// terminal or Markdown link and of a pinned link: link_choices lists which a link offers. Moving and removing
// are a pinned link's own.
Link_Action :: enum u8 {
	// The link's own handling: a Markdown file shows in a pane, anything else goes to the system.
	Open,
	// A new shell in a folder, with the profile of the pane the menu belongs to.
	Open_Shell,
	// A program from Link Programs in settings, run on the link.
	Program,
	Open_External,
	Copy,
	Open_Folder,
	Move_Pane,
	Move_Tab,
	Move_Workspace,
	Remove,
}

// Where Open, Open_Shell or a Program opens a pane. Default is the row's own: its click, while its submenu
// names each of the others (D-088).
Link_Placement :: enum u8 {
	Default,
	Split_Right,
	Split_Down,
	Float,
	Tab,
	Linked_Window,
}

// One row of a link menu or of its placement submenu, carried as the row's payload.
Link_Choice :: bit_field u32 {
	action:    Link_Action    | 8,
	placement: Link_Placement | 8,
	// The program's place in settings' Link Programs order, for Program.
	program:   u8             | 8,
}

// Choosing the level for the document just added. The menu owns document.target.
Document_Menu_Pin :: struct {
	document: Document,
}

// Ctrl+ or Shift+right-click on a terminal or Markdown link: open it here or elsewhere, copy it, or choose a
// level for it. The menu owns document.target.
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
	Search_Field,
	Pin,
	// A row of the link menu running `link`.
	Link,
	Focus_Window,
}

Document_Menu_Entry :: struct {
	action: Document_Menu_Action,
	level:  Document_Level,
	link:   Link_Choice,
	target: string,
	folder: bool,
	// The window a Focus_Window row brings forward.
	window: input.Window_Id,
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
	// What the list is filtered by. It has the keyboard while the list shows and no address is typed.
	search:      ui.Text_Field,
	actions:     ui.Menu,
	// The placements of row `submenu_row` of the menu it hangs from: the actions menu while that shows, else
	// the link menu (D-088). Its rows' payloads are Link_Choices. Any change of mode or rows closes it.
	submenu:     ui.Menu,
	submenu_row: Maybe(int),
	// Keeps the submenu while the pointer heads from its row to it (menu aim).
	reveal:      ui.Hover_Reveal,
	// A row the pointer rests on whose submenu shows LINK_SUBMENU_DELAY after `pending_since`.
	pending_row:   Maybe(int),
	pending_since: time.Tick,
	// A pinned row pressed or dragged to reorder it among its level's rows (D-069).
	order:           Document_Order,
	// Each row's eased place, in slots, while a row is lifted and while the rows settle after it; only
	// while order_moving.
	order_positions: [ui.MENU_MAX_ITEMS]ui.Motion,
	order_moving:    bool,
	// The row drawn on top while it settles into its slot after a drop.
	order_settle:    Maybe(int),
}

Document_Order :: union {
	Document_Order_Press,
	Document_Order_Lift,
}

// A press on a pinned row, which lifts it once the pointer passes the drag threshold and else opens it on
// release.
Document_Order_Press :: struct {
	row:                    int,
	start_x, start_y, grab: f32,
}

// A lifted row follows the pointer between rows first and last, its level's; a drop moves it to slot `to`.
Document_Order_Lift :: struct {
	row, first, last, to: int,
	grab:                 f32,
}

@(private = "file", rodata)
LINK_ACTIONS := [Link_Action]struct {
	label: string,
	glyph: ui.Icon,
} {
	.Open           = {"Open", .None},
	.Open_Shell     = {"Open in Shell", .Terminal},
	.Program        = {"", .Terminal},
	.Open_External  = {"Open with Default App", .Document},
	.Copy           = {"Copy Path", .Copy},
	.Open_Folder    = {"Open Containing Folder", .Folder},
	.Move_Pane      = {"Move to This Pane", .Split_Right},
	.Move_Tab       = {"Move to This Tab", .Layout_Top},
	.Move_Workspace = {"Move to This Workspace", .Workspace},
	.Remove         = {"Remove", .Close},
}

@(private = "file", rodata)
LINK_PLACEMENTS := [Link_Placement]struct {
	label: string,
	glyph: ui.Icon,
} {
	.Default       = {"", .None},
	.Split_Right   = {"Right Split", .Split_Right},
	.Split_Down    = {"Down Split", .Split_Down},
	.Float         = {"Float", .Float_Pane},
	.Tab           = {"New Tab", .Layout_Top},
	.Linked_Window = {"Linked Window", .Window_Out},
}

@(private = "file")
LINK_SUBMENU_WIDTH :: f32(200)

// The Link Programs entry at `index` in settings' order, or none once settings no longer have it.
@(private = "file")
link_program :: proc(app: ^App, index: int) -> (^settings.Opener, bool) {
	indices: [settings.OPENER_LIMIT]int
	count := settings.openers_in_order(&app.settings.openers, indices[:])
	if index < 0 || index >= count {return nil, false}
	return &app.settings.openers.items[indices[index]], true
}

// The shared rows `document` offers, in menu order, with nil for a divider (D-088). First come the ways to
// open it: Open, or Open in Shell for a folder, then each program from Link Programs that offers itself for
// files or for folders. A Markdown file and a folder also have the system's handler, which is what Open
// already does for any other file.
@(private = "file")
link_choices :: proc(app: ^App, document: Document) -> []Maybe(Link_Choice) {
	capacity := len(Link_Action) + settings.OPENER_LIMIT
	rows := make([dynamic]Maybe(Link_Choice), 0, capacity, context.temp_allocator)
	web := document_is_web(document.target)
	file := !web && !document.folder
	markdown := file && markdown_is_path(document.target)
	append(&rows, Link_Choice{action = document.folder ? .Open_Shell : .Open})
	if !web {
		indices: [settings.OPENER_LIMIT]int
		count := settings.openers_in_order(&app.settings.openers, indices[:])
		for i in 0 ..< count {
			offers := app.settings.openers.items[indices[i]].offers
			if (document.folder ? settings.Opener_Link.Folders : .Files) not_in offers {continue}
			append(&rows, Link_Choice{action = .Program, program = u8(i)})
		}
	}
	if markdown || document.folder {append(&rows, Link_Choice{action = .Open_External})}
	append(&rows, nil, Link_Choice{action = .Copy})
	if file {append(&rows, Link_Choice{action = .Open_Folder})}
	return rows[:]
}

// A link row. Open shows the link's own icon and a program its name; copying a web address copies a link.
// A row that opens a pane leads to its placements. A program's name is copied into `menu`, so the row
// outlives a settings reload.
@(private = "file")
link_choice_item :: proc(
	app: ^App,
	menu: ^Document_Menu,
	choice: Link_Choice,
	document: Document,
) -> ui.Menu_Item {
	row := LINK_ACTIONS[choice.action]
	item := ui.Menu_Item{label = row.label, glyph = row.glyph, enabled = true, payload = transmute(u32)choice}
	#partial switch choice.action {
	case .Open:
		item.glyph = document_icon(document)
		item.submenu = markdown_is_path(document.target) && !document_is_web(document.target)
	case .Open_Shell:
		item.submenu = true
	case .Program:
		if program, found := link_program(app, int(choice.program)); found {
			item.label = document_menu_own(menu, fmt.tprintf("Open in %s", program.name))
			item.submenu = program.placement != .Own_Window
			if !item.submenu {item.glyph = .Window_Out}
		}
	case .Copy:
		if document_is_web(document.target) {item.label = "Copy Link"}
	}
	return item
}

// Where the row `choice` opens when clicked: Markdown in a float or a split as Open does today, a shell in
// a right split, and a program at its own placement. Default for a program that runs as its own window.
@(private = "file")
link_choice_default :: proc(app: ^App, choice: Link_Choice) -> Link_Placement {
	#partial switch choice.action {
	case .Open:
		return app.settings.pane.markdown_floating ? .Float : .Split_Right
	case .Open_Shell:
		return .Split_Right
	case .Program:
		program, found := link_program(app, int(choice.program))
		if !found {return .Default}
		switch program.placement {
		case .Right_Split: return .Split_Right
		case .Down_Split: return .Split_Down
		case .Float: return .Float
		case .Tab: return .Tab
		case .Linked_Window: return .Linked_Window
		case .Own_Window: return .Default
		}
	}
	return .Default
}

// Fills `submenu` with the placements of row `choice`, its click marked Default.
@(private = "file")
link_submenu_build :: proc(app: ^App, submenu: ^ui.Menu, choice: Link_Choice) {
	ui.menu_clear(submenu)
	submenu.width = LINK_SUBMENU_WIDTH
	default := link_choice_default(app, choice)
	for placement in Link_Placement.Split_Right ..= Link_Placement.Linked_Window {
		row := LINK_PLACEMENTS[placement]
		place := choice
		place.placement = placement
		item := ui.Menu_Item{label = row.label, glyph = row.glyph, enabled = true, payload = transmute(u32)place}
		if placement == default {item.shortcut = "Default"}
		if _, err := ui.menu_add(submenu, item); err != nil {log.errorf("adding a placement row failed: %v", err)}
	}
}

@(private = "file")
pane_placement_of :: proc(placement: Link_Placement) -> Pane_Placement {
	switch placement {
	case .Default, .Split_Right: return .Split_Right
	case .Split_Down: return .Split_Down
	case .Float: return .Float
	case .Tab: return .Tab
	case .Linked_Window: return .Linked_Window
	}
	return .Split_Right
}

// Runs one of the shared rows on `document`, a link shown in or pinned to the pane showing `content` in
// w. The menu has closed, so `document` must not borrow from it.
@(private = "file")
link_choice_run :: proc(
	app: ^App,
	w: ^Window,
	content: layout.Content,
	document: Document,
	choice: Link_Choice,
) {
	switch choice.action {
	case .Open:
		if choice.placement == .Default {
			target_open(app, w, target_from_document(document.target))
		} else {
			document_link_open_in(app, w, content, document, pane_placement_of(choice.placement))
		}
	case .Open_Shell:
		document_link_open_in(app, w, content, document, pane_placement_of(choice.placement))
	case .Program:
		link_program_run(app, w, content, document, choice)
	case .Open_External:
		if document.folder {
			target_open(app, w, File_Target{document.target})
		} else {
			document_link_open_external(app, w, document.target)
		}
	case .Copy:
		_ = clipboard_copy(app, document.target)
	case .Open_Folder:
		target_open(app, w, File_Target{filepath.dir(document.target)})
	case .Move_Pane, .Move_Tab, .Move_Workspace, .Remove:
		log.errorf("%v is not a shared link action", choice.action)
	}
}

// Runs the Link Programs entry `choice` names on `document`: in a new pane at the choice's placement, else
// the program's own, or as a window of its own. It starts in the file's folder, or in the folder itself.
@(private = "file")
link_program_run :: proc(
	app: ^App,
	w: ^Window,
	content: layout.Content,
	document: Document,
	choice: Link_Choice,
) {
	program, found := link_program(app, int(choice.program))
	if !found {
		notify(app, .Error, "That link program is no longer in settings.")
		return
	}
	directory := document.folder ? document.target : filepath.dir(document.target)
	if !os.is_dir(directory) || !document.folder && !os.exists(document.target) {
		target_unavailable(app)
		return
	}
	name := strings.clone(program.name, context.temp_allocator)
	line, ready := link_program_line(app, program, document.target)
	if !ready {return}
	placement := choice.placement
	if placement == .Default {placement = link_choice_default(app, choice)}
	if placement == .Default {
		if app.opener.program == nil || !app.opener.program(line, directory) {
			notify(app, .Error, fmt.tprintf("Could not start %s.", name))
		}
		return
	}
	tree := window_tree(w)
	if tree == nil {return}
	node := layout.find_content(tree, content)
	if node == layout.INVALID_NODE {node = tree.focus}
	launch := Pane_Launch{command = line, directory = directory}
	if !shell_open_placed(app, w, node, launch, pane_placement_of(placement)) {
		notify(app, .Error, fmt.tprintf("Could not start %s.", name))
	}
}

// The command line that runs `program` on `path`, in temporary memory, naming its executable by the path
// found for it so nothing searches again. A batch script runs through cmd.exe, which would read some
// characters of a path as commands, so such a path is refused.
@(private = "file")
link_program_line :: proc(app: ^App, program: ^settings.Opener, path: string) -> (string, bool) {
	line, err := settings.opener_command_line(program.command, path, context.temp_allocator)
	if err != nil {return "", false}
	resolved, resolve_error := pty.resolve_program(line, context.temp_allocator)
	if resolve_error.kind != .None {
		notify(app, .Error, fmt.tprintf("Could not find the program %s runs.", program.name))
		return "", false
	}
	defer pty.program_destroy(&resolved, context.temp_allocator)
	arguments := pty.command_arguments(line)
	if !resolved.batch {
		explicit, join_error := strings.concatenate({`"`, resolved.path, `" `, arguments}, context.temp_allocator)
		return strings.trim_right_space(explicit), join_error == nil
	}
	if strings.contains_any(path, `%"&|<>^!`) {
		notify(app, .Error, fmt.tprintf("%s cannot open a path containing %% \" & | < > ^ or !.", program.name))
		return "", false
	}
	batch, batch_error := pty.batch_command_line(resolved.path, arguments, context.temp_allocator)
	if batch_error.kind != .None {
		notify(app, .Error, fmt.tprintf("Could not start %s.", program.name))
		return "", false
	}
	return batch, true
}

@(private = "file")
DOCUMENT_ACTIONS_WIDTH :: f32(224)

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
	ui.menu_init(&menu.actions)
	menu.actions.width = DOCUMENT_ACTIONS_WIDTH
	ui.menu_init(&menu.submenu)
}

@(private = "file")
document_menu_text_clear :: proc(menu: ^Document_Menu) {
	for text in menu.text {delete(text)}
	clear(&menu.text)
}

// Frees the document a Pin or Link mode holds; document_menu_close and document_menu_set call it.
document_menu_mode_release :: proc(mode: Document_Menu_Mode) {
	switch m in mode {
	case Document_Menu_List:
	case Document_Menu_Pin:
		delete(m.document.target)
	case Document_Menu_Link:
		delete(m.document.target)
	}
}

// The menu's surface ends: the document its mode holds, the text being typed and the hover go with it.
document_menu_close :: proc(menu: ^Document_Menu, mode: Document_Menu_Mode) {
	document_menu_mode_release(mode)
	ui.field_release(&menu.url)
	ui.field_release(&menu.search)
	menu.menu.hover_part = .Row
	document_submenu_reset(menu)
	document_order_stop(menu)
}

// Takes w because a menu still showing when its window is freed holds a document in w.overlay.
document_menu_destroy :: proc(w: ^Window) {
	if state, shown := w.overlay.(Overlay_Document_Menu); shown {document_menu_mode_release(state.mode)}
	menu := &w.document_menu
	document_menu_text_clear(menu)
	delete(menu.text)
	delete(menu.url.bytes)
	delete(menu.search.bytes)
	ui.menu_destroy(&menu.menu)
	ui.menu_destroy(&menu.actions)
	ui.menu_destroy(&menu.submenu)
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

document_menu_actions :: proc(w: ^Window) -> (Document_Actions, bool) {
	actions, shown := document_list_step(w).(Document_Actions)
	return actions, shown
}

// The menu the submenu hangs from: the actions menu while it shows, else the link menu, else none.
@(private = "file")
document_submenu_parent :: proc(w: ^Window) -> ^ui.Menu {
	state := document_menu_state(w)
	if state == nil {return nil}
	if _, actions := document_menu_actions(w); actions {return &w.document_menu.actions}
	if _, link := state.mode.(Document_Menu_Link); link {return &w.document_menu.menu}
	return nil
}

// Whether a row's placements show beside it. document_submenu_open and document_submenu_close change it.
document_submenu_shown :: proc(w: ^Window) -> bool {
	_, shown := w.document_menu.submenu_row.?
	return shown && document_submenu_parent(w) != nil
}

// What row `row` of `parent` runs, for a row with placements.
@(private = "file")
document_row_choice :: proc(w: ^Window, parent: ^ui.Menu, row: int) -> (Link_Choice, bool) {
	if row < 0 || row >= len(parent.items) || !parent.items[row].submenu {return {}, false}
	if parent == &w.document_menu.actions {return transmute(Link_Choice)parent.items[row].payload, true}
	entry, listed := document_menu_entry(&w.document_menu, row)
	return entry.link, listed && entry.action == .Link
}

// Shows the placements of row `row` beside it, with the first selected for the keyboard. A row without
// placements closes them instead.
@(private = "file")
document_submenu_open :: proc(app: ^App, w: ^Window, row: int, select_first: bool) {
	menu := &w.document_menu
	parent := document_submenu_parent(w)
	if parent == nil {return}
	choice, has := document_row_choice(w, parent, row)
	if !has {
		document_submenu_close(w)
		return
	}
	if current, open := menu.submenu_row.?; open && current == row && !select_first {return}
	link_submenu_build(app, &menu.submenu, choice)
	anchor := ui.menu_submenu_anchor(parent, row, LINK_SUBMENU_WIDTH, f32(w.width), f32(w.height), w.scale)
	ui.menu_anchor(&menu.submenu, anchor.x, anchor.y)
	ui.menu_select(&menu.submenu, select_first ? 0 : -1)
	menu.submenu_row, w.dirty = row, true
}

@(private = "file")
document_submenu_close :: proc(w: ^Window) {
	if w.document_menu.submenu_row != nil {w.dirty = true}
	document_submenu_reset(&w.document_menu)
}

@(private = "file")
document_submenu_reset :: proc(menu: ^Document_Menu) {
	menu.submenu_row, menu.pending_row = nil, nil
	ui.hover_reveal_close(&menu.reveal)
}

// How long the pointer rests on a row before its submenu shows, Radix UI's open delay, so a sweep down the
// menu does not flash each submenu it crosses. The keyboard opens one at once.
LINK_SUBMENU_DELAY :: 100 * time.Millisecond

// Shows the submenu of the row the pointer, at `point`, rests on once LINK_SUBMENU_DELAY has passed. True
// when it did.
@(private = "file")
document_submenu_settle :: proc(app: ^App, w: ^Window, point: [2]f32, now: time.Tick) -> bool {
	menu := &w.document_menu
	row, pending := menu.pending_row.?
	if !pending || time.tick_diff(time.tick_add(menu.pending_since, LINK_SUBMENU_DELAY), now) < 0 {return false}
	menu.pending_row = nil
	parent := document_submenu_parent(w)
	if parent == nil {return false}
	width, height := f32(w.width), f32(w.height)
	if ui.menu_hit(parent, point.x, point.y, width, height, w.scale) != row {return false}
	document_submenu_open(app, w, row, false)
	trigger := ui.menu_row_rect(parent, row, width, height, w.scale)
	surface, _ := ui.menu_layout(&menu.submenu, width, height, w.scale)
	slack := ui.HOVER_AIM_SLACK * w.scale
	ui.hover_reveal_move(&menu.reveal, point, true, false, false, trigger, surface, slack, now)
	return true
}

// An aim at the submenu that stopped short of it gives the row under the pointer its turn, and a row the
// pointer has rested on long enough shows its submenu.
document_submenu_tick :: proc(app: ^App, w: ^Window, now: time.Tick) {
	if !document_menu_shown(w) {return}
	if document_submenu_settle(app, w, w.pointer, now) {return}
	if !ui.hover_reveal_tick(&w.document_menu.reveal, now) {return}
	document_submenu_close(w)
	document_menu_hover(app, w, w.pointer.x, w.pointer.y, false)
}

document_submenu_deadline :: proc(w: ^Window) -> (time.Tick, bool) {
	if !document_menu_shown(w) {return {}, false}
	if _, pending := w.document_menu.pending_row.?; pending {
		return time.tick_add(w.document_menu.pending_since, LINK_SUBMENU_DELAY), true
	}
	return ui.hover_reveal_deadline(w.document_menu.reveal)
}

// The link the shared rows act on and the pane they are for: the link menu's link, or the pinned link the
// actions menu is for. It borrows the menu.
@(private = "file")
document_link_subject :: proc(w: ^Window) -> (Document, layout.Content, bool) {
	state := document_menu_state(w)
	if state == nil {return {}, {}, false}
	if actions, shown := document_menu_actions(w); shown {
		entry, listed := document_menu_entry(&w.document_menu, actions.row)
		return {entry.target, entry.folder}, state.content, listed && entry.action == .Open
	}
	if link, linking := state.mode.(Document_Menu_Link); linking {return link.document, state.content, true}
	return {}, {}, false
}

// Runs a shared row. The menu closes first, so the link is copied out of it.
@(private = "file")
document_link_choose :: proc(app: ^App, w: ^Window, choice: Link_Choice) {
	subject, content, found := document_link_subject(w)
	if !found {return}
	document := Document{strings.clone(subject.target, context.temp_allocator), subject.folder}
	overlay_close(app, w)
	link_choice_run(app, w, content, document, choice)
}

// The submenu's keys while it shows with a row selected: it moves and chooses, and Left or Escape closes
// it. A submenu the pointer opened has no selection yet, so the keys stay with the highlighted row of the
// menu it hangs from, as in Radix UI, except that Left still closes it. False when the key is the parent's.
@(private = "file")
document_submenu_key :: proc(app: ^App, w: ^Window, logical: input.Key_Event) -> bool {
	if !document_submenu_shown(w) {return false}
	submenu := &w.document_menu.submenu
	if ui.menu_selected(submenu) < 0 {
		if logical.key != .Arrow_Left {return false}
		document_submenu_close(w)
		return true
	}
	switch ui.menu_key(submenu, logical) {
	case .None, .Submenu:
		if logical.key == .Arrow_Left {document_submenu_close(w)}
	case .Changed:
	case .Chosen:
		document_link_choose(app, w, transmute(Link_Choice)submenu.items[ui.menu_selected(submenu)].payload)
		return true
	case .Closed:
		document_submenu_close(w)
	}
	w.dirty = true
	return true
}

// The pointer at x, y over the submenu or the menu it hangs from. On the submenu it selects there. While
// the pointer heads from a row to its submenu (ui.Hover_Reveal) everything stays as it is; otherwise the
// parent row under the pointer shows its placements or, having none, closes them. True when the submenu
// keeps the pointer.
@(private = "file")
document_submenu_hover :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	parent := document_submenu_parent(w)
	if parent == nil {return false}
	menu := &w.document_menu
	width, height := f32(w.width), f32(w.height)
	slack, now := ui.HOVER_AIM_SLACK * w.scale, clock_now(&app.clock)
	hit := ui.menu_hit(parent, x, y, width, height, w.scale)
	if row, shown := menu.submenu_row.?; shown {
		trigger := ui.menu_row_rect(parent, row, width, height, w.scale)
		surface, _ := ui.menu_layout(&menu.submenu, width, height, w.scale)
		on_trigger, on_surface := render.rect_contains(trigger, x, y), render.rect_contains(surface, x, y)
		// Another row of the menu wants the hover unless the pointer is heading for the submenu.
		on_other := !on_trigger && !on_surface && hit >= 0 && hit != row
		ui.hover_reveal_move(&menu.reveal, {x, y}, on_trigger, on_surface, on_other, trigger, surface, slack, now)
		if on_surface {
			place := ui.menu_hit(&menu.submenu, x, y, width, height, w.scale)
			if place >= 0 && place != ui.menu_selected(&menu.submenu) {
				ui.menu_select(&menu.submenu, place)
				w.dirty = true
			}
			return true
		}
		if menu.reveal.open && !on_trigger {return true}
	}
	if hit < 0 {
		menu.pending_row = nil
		return false
	}
	if !parent.items[hit].submenu {
		document_submenu_close(w)
		return false
	}
	if current, open := menu.submenu_row.?; open && current == hit {
		trigger := ui.menu_row_rect(parent, hit, width, height, w.scale)
		surface, _ := ui.menu_layout(&menu.submenu, width, height, w.scale)
		ui.hover_reveal_move(&menu.reveal, {x, y}, true, false, false, trigger, surface, slack, now)
		return false
	}
	if menu.submenu_row != nil {document_submenu_close(w)}
	if pending, waiting := menu.pending_row.?; !waiting || pending != hit {
		menu.pending_row, menu.pending_since = hit, now
	}
	_ = document_submenu_settle(app, w, {x, y}, now)
	return false
}

// Whether every word of `query` is in one of `texts`, ignoring case.
@(private = "file")
document_menu_matches :: proc(query: string, texts: ..string) -> bool {
	words := query
	for word in strings.fields_iterator(&words) {
		needle := strings.to_lower(word, context.temp_allocator)
		found := false
		for text in texts {
			if strings.contains(strings.to_lower(text, context.temp_allocator), needle) {found = true; break}
		}
		if !found {return false}
	}
	return true
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
	document_submenu_reset(&w.document_menu)
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

// The other windows showing part of w's tab that match `query`: the window showing the tab first, then its
// linked windows. A row brings its window forward.
@(private = "file")
document_menu_build_windows :: proc(app: ^App, menu: ^Document_Menu, w: ^Window, query: string) {
	tab, host := selected_tab(w.workspace), w
	if window_linked(w) {
		home, found := pane_link_locate(app, w)
		if !found {return}
		tab, host = home.tab, nil
		if selected_tab(home.workspace) == home.tab {host = window_for_workspace(app, home.workspace)}
	}
	if tab == nil {return}
	add :: proc(menu: ^Document_Menu, other: ^Window, glyph: ui.Icon, detail, query: string) {
		shown := selected_tab(other.workspace)
		title := shown != nil && shown.title != "" ? shown.title : "Untitled"
		if !document_menu_matches(query, title, detail) {return}
		document_menu_push(
			menu,
			{label = document_menu_own(menu, title), detail = detail, glyph = glyph, enabled = true},
			{action = .Focus_Window, window = other.id},
		)
	}
	if host != nil && host != w {add(menu, host, .Window_In, "Main window", query)}
	for other in app.windows {
		if other == w || !window_linked(other) || other.phase != .Shown {continue}
		if home, found := pane_link_locate(app, other); found && home.tab == tab {
			add(menu, other, .Window_Out, "Linked window", query)
		}
	}
}

@(private = "file")
document_menu_build_list :: proc(
	app: ^App,
	w: ^Window,
	menu: ^Document_Menu,
	content: layout.Content,
	list: Document_Menu_List,
) {
	scopes, found := document_scopes(app, content)
	if !found {return}
	document_menu_push(menu, {}, {action = .Search_Field})
	query := ui.field_string(&menu.search)
	document_menu_build_windows(app, menu, w, query)
	windows := menu.count - 1
	pinned := documents_visible(scopes)
	shown := 0
	for row in pinned {
		name, detail := document_label(row.document, context.temp_allocator)
		if !document_menu_matches(query, name, row.document.target) {continue}
		if shown == 0 && windows > 0 || shown > 0 && menu.entries[menu.count - 1].level != row.level {
			document_menu_push(menu, {separator = true})
		}
		shown += 1
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
	if query != "" && windows + shown == 0 {document_menu_push(menu, {label = "No links match"})}
	document_menu_push(menu, {separator = true})
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
	if len(pinned) == 0 {document_menu_push(menu, {label = "Or Ctrl+right-click a link"})}
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

// A link's rows: the shared actions, then pinning it.
@(private = "file")
document_menu_build_link :: proc(
	app: ^App,
	menu: ^Document_Menu,
	content: layout.Content,
	document: Document,
) {
	for row in link_choices(app, document) {
		choice, is_choice := row.?
		if !is_choice {
			document_menu_push(menu, {separator = true})
			continue
		}
		document_menu_push(menu, link_choice_item(app, menu, choice, document), {action = .Link, link = choice})
	}
	document_menu_push(menu, {separator = true})
	document_menu_build_levels(app, menu, content, DOCUMENT_PIN_LABELS)
}

// Places a link's Markdown file, or a new shell in its folder, beside the pane showing `content` or, once
// that pane has gone, the focused one. The shell takes that pane's profile; a pane with no shell, such as
// a Markdown pane, gives the default profile.
@(private = "file")
document_link_open_in :: proc(
	app: ^App,
	w: ^Window,
	content: layout.Content,
	document: Document,
	placement: Pane_Placement,
) {
	tree := window_tree(w)
	if tree == nil {return}
	node := layout.find_content(tree, content)
	if node == layout.INVALID_NODE {node = tree.focus}
	if document.folder {
		if !os.is_dir(document.target) {
			target_unavailable(app)
			return
		}
		launch := Pane_Launch{directory = document.target}
		if entry := workspace_session_for_content(app, content); entry != nil {launch.profile = entry.profile_id}
		if !shell_open_placed(app, w, node, launch, placement) {notify(app, .Error, "Could not open a shell.")}
		return
	}
	file, ok := localpath.prepare_open(document.target)
	if !ok {
		target_unavailable(app)
		return
	}
	defer localpath.open_file_destroy(&file)
	if !markdown_open_placed(app, w, node, file.target, placement) {
		notify(app, .Error, "Could not open the file.")
	}
}

// Hands a Markdown file to the system instead of a pane. A type that needs confirming takes the usual
// confirmation.
@(private = "file")
document_link_open_external :: proc(app: ^App, w: ^Window, path: string) {
	file, ok := localpath.prepare_open(path)
	if !ok {
		target_unavailable(app)
		return
	}
	if file.confirm {
		localpath.open_file_destroy(&file)
		target_open(app, w, File_Target{path})
		return
	}
	defer localpath.open_file_destroy(&file)
	if !target_open_approved(app, file.path, "") {notify(app, .Error, "Could not open the file.")}
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
	// Rebuilt rows may stand for other documents, so no press or motion carries over.
	document_order_stop(menu)
	document_submenu_reset(menu)
	document_menu_text_clear(menu)
	menu.count = 0
	menu.entries = {}
	switch mode in state.mode {
	case Document_Menu_List:
		document_menu_build_list(app, w, menu, state.content, mode)
	case Document_Menu_Pin:
		name, _ := document_label(mode.document, context.temp_allocator)
		label := fmt.tprintf("Pin %s to", name)
		document_menu_push(menu, {label = document_menu_own(menu, label)})
		document_menu_build_levels(app, menu, state.content, DOCUMENT_LEVEL_LABELS)
	case Document_Menu_Link:
		document_menu_build_link(app, menu, state.content, mode.document)
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
	ui.field_set(&w.document_menu.search, "")
	ui.menu_anchor(&w.document_menu.menu, x, y)
	document_menu_build(app, w, true)
}

document_menu_open_pane :: proc(app: ^App, w: ^Window, pane: layout.Pane_Rect) {
	if !CONTENT_POLICY[pane.content.kind].documents {return}
	anchor := pane_header_document_anchor(w, pane)
	document_menu_show(app, w, pane.content, Document_Menu_List{}, anchor.x, anchor.y)
}

// The Show Links command: the only way to the menu for a split pane with headers off.
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

// Ctrl+ or Shift+right-click on a terminal link. False leaves the press to the terminal.
@(require_results)
document_menu_open_link :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	buffer: [links.TARGET_BYTES]u8 = ---
	target := link_resolve(app, w, x, y, buffer[:])
	if target == nil {return false}
	pane, found := layout.hit_test(w.panes[:], x, y)
	if !found {return false}
	document_menu_open_target(app, w, pane.content, target, x, y)
	return true
}

// The link menu at the point for `target`, a link shown in the pane showing `content`; a file that is not
// there is reported instead.
document_menu_open_target :: proc(app: ^App, w: ^Window, content: layout.Content, target: Target, x, y: f32) {
	spelling, folder := "", false
	switch t in target {
	case nil:
		return
	case Missing_Target:
		target_unavailable(app)
		return
	case Web_Target:
		spelling = t.uri
	case File_Target:
		spelling, folder = t.path, os.is_dir(t.path)
	}
	owned, err := strings.clone(spelling)
	if err != nil {return}
	document_menu_show(app, w, content, Document_Menu_Link{{owned, folder}}, x, y)
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
		message := fmt.tprintf("%s already has %d links.", DOCUMENT_LEVEL_LABELS[level], DOCUMENT_LEVEL_LIMIT)
		notify(app, .Warning, message)
	case .Failed:
		notify(app, .Error, "Could not pin the link.")
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
	case .None, .Url_Field, .Search_Field:
	case .Open:
		target := strings.clone(entry.target, context.temp_allocator)
		overlay_close(app, w)
		target_open(app, w, target_from_document(target))
	case .Link:
		document_link_choose(app, w, entry.link)
	case .Focus_Window:
		overlay_close(app, w)
		if other := window_find(app, entry.window); other != nil {_ = window_activate(app, other)}
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

// Opens row `index`'s right-click menu at x, y, ending any address being typed as the popout does. Only a
// pinned document has one; a window row has only its click.
@(private = "file")
document_actions_open :: proc(app: ^App, w: ^Window, index: int, x, y: f32) {
	state := document_menu_state(w)
	menu := &w.document_menu
	entry, _ := document_menu_entry(menu, index)
	if state == nil || entry.action != .Open {return}
	if _, entering := document_menu_url_entry(w); entering {
		document_menu_set(app, w, Document_Menu_List{}, .Rebuild)
	}
	actions := &menu.actions
	ui.menu_clear(actions)
	add :: proc(actions: ^ui.Menu, item: ui.Menu_Item, choice: Link_Choice) {
		row := item
		row.payload = transmute(u32)choice
		if _, err := ui.menu_add(actions, row); err != nil {log.errorf("adding a link action failed: %v", err)}
	}
	document := Document{entry.target, entry.folder}
	for row in link_choices(app, document) {
		if choice, is_choice := row.?; is_choice {
			add(actions, link_choice_item(app, menu, choice, document), choice)
		} else {
			_, _ = ui.menu_add(actions, {separator = true})
		}
	}
	_, _ = ui.menu_add(actions, {separator = true})
	scopes, found := document_scopes(app, state.content)
	for level in Document_Level {
		if level == entry.level || !found || document_scope_list(scopes, level) == nil {continue}
		move := Link_Choice{action = Link_Action(int(Link_Action.Move_Pane) + int(level))}
		add(actions, link_choice_item(app, menu, move, document), move)
	}
	remove := Link_Choice{action = .Remove}
	add(actions, link_choice_item(app, menu, remove, document), remove)
	ui.menu_anchor(actions, x, y)
	ui.menu_select_edge(actions, false)
	ui.menu_select(&menu.menu, index)
	document_menu_set(app, w, Document_Menu_List{Document_Actions{index}}, .Keep)
}

// The right-click menu for the selected row, hung below it, for Ctrl+Enter and the Menu key.
@(private = "file")
document_actions_open_selected :: proc(app: ^App, w: ^Window) {
	menu := &w.document_menu
	index := ui.menu_selected(&menu.menu)
	if index < 0 {return}
	row := ui.menu_row_rect(&menu.menu, index, f32(w.width), f32(w.height), w.scale)
	document_actions_open(app, w, index, row.x + ui.SPACE_6 * w.scale, row.y + row.height)
}

// Runs a right-click menu row on the row it was opened for. Opening closes the menu; moving and removing
// keep it open on the list.
@(private = "file")
document_actions_choose :: proc(app: ^App, w: ^Window, choice: Link_Choice) {
	actions, shown := document_menu_actions(w)
	if !shown {return}
	switch choice.action {
	case .Open, .Open_Shell, .Program, .Open_External, .Copy, .Open_Folder:
		document_link_choose(app, w, choice)
	case .Move_Pane, .Move_Tab, .Move_Workspace:
		document_popout_close(app, w)
		level := Document_Level(int(choice.action) - int(Link_Action.Move_Pane))
		document_menu_move(app, w, actions.row, level)
	case .Remove:
		document_popout_close(app, w)
		document_menu_remove(app, w, actions.row)
	}
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
	document_popout_close(app, w)
	document_menu_move(app, w, popout.row, level)
}

// Moves row `row`'s document to `level`, keeping the selection on it.
@(private = "file")
document_menu_move :: proc(app: ^App, w: ^Window, row: int, level: Document_Level) {
	menu := &w.document_menu
	entry, _ := document_menu_entry(menu, row)
	if entry.action != .Open || entry.level == level {return}
	// Rebuilding replaces the text the entry borrows.
	target := strings.clone(entry.target, context.temp_allocator)
	document_menu_pin(app, w, level, {target, entry.folder})
	document_menu_build(app, w)
	// The row moved with its level, so the selection follows it there.
	for i in 0 ..< len(menu.menu.items) {
		if moved, _ := document_menu_entry(menu, i); moved.action == .Open && moved.target == target {
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

// In the list the search field has the keyboard: Up, Down, Ctrl+N and Ctrl+P move the selection, Enter
// runs the selected row's click, and Ctrl+Enter, the Menu key or Shift+F10 opens its right-click menu.
document_menu_key :: proc(app: ^App, w: ^Window, raw, logical: input.Key_Event) {
	state := document_menu_state(w)
	if state == nil || !logical.pressed {return}
	// A lifted row keeps the list still; Escape lets it go back to its slot.
	if _, lifted := w.document_menu.order.(Document_Order_Lift); lifted {
		if logical.key == .Escape {document_order_end(app, w)}
		return
	}
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
	case Document_Actions:
		if document_submenu_key(app, w, logical) {return}
		switch ui.menu_key(&menu.actions, logical) {
		case .None:
			if logical.key == .Arrow_Left {document_popout_close(app, w)}
		case .Changed:
		case .Chosen:
			row := menu.actions.items[ui.menu_selected(&menu.actions)]
			document_actions_choose(app, w, transmute(Link_Choice)row.payload)
		case .Closed:
			document_popout_close(app, w)
		case .Submenu:
			document_submenu_open(app, w, ui.menu_selected(&menu.actions), true)
		}
		w.dirty = true
		return
	}
	if document_submenu_key(app, w, logical) {return}
	_, listing := state.mode.(Document_Menu_List)
	#partial switch logical.key {
	case .Enter, .Numpad_Enter:
		if .Control in logical.modifiers {
			document_actions_open_selected(app, w)
		} else {
			document_menu_activate(app, w, ui.menu_selected(&menu.menu))
		}
		return
	case .Context_Menu:
		document_actions_open_selected(app, w)
		return
	case .F10:
		if logical.modifiers == {.Shift} {
			document_actions_open_selected(app, w)
			return
		}
	case .Escape:
		// Escape clears a search before it closes the menu.
		if listing && ui.field_string(&menu.search) != "" {
			ui.field_set(&menu.search, "")
			document_menu_build(app, w, true)
			return
		}
		if _, pinning := state.mode.(Document_Menu_Pin); pinning {
			document_menu_set(app, w, Document_Menu_List{}, .Rebuild_Select_First)
			return
		}
		overlay_close(app, w)
		return
	}
	if step := ui.list_step(logical); step != 0 {
		ui.menu_step(&menu.menu, step)
		ui.menu_reveal(&menu.menu, f32(w.width), f32(w.height), w.scale)
		w.dirty = true
		return
	}
	if listing {
		if field_edit_key(app, &menu.search, raw).change != .None {document_menu_build(app, w, true)}
		w.dirty = true
		return
	}
	switch ui.menu_key(&menu.menu, logical) {
	case .None, .Closed:
	case .Submenu:
		document_submenu_open(app, w, ui.menu_selected(&menu.menu), true)
	case .Changed:
		ui.menu_reveal(&menu.menu, f32(w.width), f32(w.height), w.scale)
		w.dirty = true
	case .Chosen:
		document_menu_activate(app, w, ui.menu_selected(&menu.menu))
	}
}

// The wheel moves the selection, which leaves a popout or right-click menu behind.
document_menu_wheel :: proc(app: ^App, w: ^Window, rows: int) {
	if _, lifted := w.document_menu.order.(Document_Order_Lift); lifted {return}
	if document_list_step(w) != nil {
		if _, entering := document_menu_url_entry(w); !entering {document_popout_close(app, w)}
	}
	document_submenu_close(w)
	menu := &w.document_menu
	ui.menu_wheel(&menu.menu, rows)
	ui.menu_reveal(&menu.menu, f32(w.width), f32(w.height), w.scale)
	w.dirty = true
}

// Typing goes to the address being entered, or else to the list's search, which filters the rows.
document_menu_text_input :: proc(app: ^App, w: ^Window, text: string) {
	menu := &w.document_menu
	if _, entering := document_menu_url_entry(w); entering {
		if ui.field_text(&menu.url, text) != .None {document_menu_url_edited(app, w)}
		return
	}
	state := document_menu_state(w)
	if state == nil || document_list_step(w) != nil {return}
	if _, listing := state.mode.(Document_Menu_List); !listing {return}
	if ui.field_text(&menu.search, text) != .None {document_menu_build(app, w, true)}
}

// The box of the field row `action` names, Url_Field or Search_Field, with the field it edits.
@(private = "file")
document_field_box :: proc(w: ^Window, action: Document_Menu_Action) -> (ui.Field_Box, ^ui.Text_Field, bool) {
	menu := &w.document_menu
	field := action == .Url_Field ? &menu.url : &menu.search
	for i in 0 ..< len(menu.menu.items) {
		if entry, _ := document_menu_entry(menu, i); entry.action != action {continue}
		rect := ui.menu_row_rect(&menu.menu, i, f32(w.width), f32(w.height), w.scale)
		return ui.field_box_standard(field, &w.ui_text, rect, w.scale), field, true
	}
	return {}, nil, false
}

document_menu_hover :: proc(app: ^App, w: ^Window, x, y: f32, left_held: bool) {
	if document_order_hover(app, w, x, y, left_held) {return}
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
	if document_submenu_hover(app, w, x, y) {
		over := ui.menu_hit(&menu.submenu, x, y, f32(w.width), f32(w.height), w.scale) >= 0
		pointer_set(app, w, over ? .Hand : .Arrow)
		return
	}
	if _, actions := document_menu_actions(w); actions {
		hit := ui.menu_hit(&menu.actions, x, y, f32(w.width), f32(w.height), w.scale)
		if hit >= 0 && menu.actions.items[hit].enabled {
			if hit != ui.menu_selected(&menu.actions) {ui.menu_select(&menu.actions, hit); w.dirty = true}
			shape = .Hand
		}
		pointer_set(app, w, shape)
		return
	}
	for action in ([?]Document_Menu_Action{.Url_Field, .Search_Field}) {
		box, field, shown := document_field_box(w, action)
		if !shown {continue}
		if field.dragging && left_held {
			ui.field_pointer(field, ui.field_box_offset(box, x), false, true)
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
	if _, actions := document_menu_actions(w); actions {return ""}
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

// Ends any press, lift or settle with the rows standing in their slots.
@(private = "file")
document_order_stop :: proc(menu: ^Document_Menu) {
	menu.order, menu.order_moving, menu.order_settle = nil, false, nil
}

// The rows a lifted row moves among: the run of pinned rows of its level around it.
@(private = "file")
document_order_group :: proc(menu: ^Document_Menu, row: int) -> (first, last: int) {
	entry, _ := document_menu_entry(menu, row)
	same :: proc(menu: ^Document_Menu, row: int, level: Document_Level) -> bool {
		other, listed := document_menu_entry(menu, row)
		return listed && other.action == .Open && other.level == level
	}
	first, last = row, row
	for same(menu, first - 1, entry.level) {first -= 1}
	for same(menu, last + 1, entry.level) {last += 1}
	return
}

// Follows the pointer at `y` with the lifted row, inside its level, and picks the slot a drop takes.
@(private = "file")
document_order_move :: proc(w: ^Window, y: f32) {
	menu := &w.document_menu
	lift, lifted := &menu.order.(Document_Order_Lift)
	if !lifted {return}
	slot := ui.menu_row_rect(&menu.menu, lift.row, f32(w.width), f32(w.height), w.scale)
	top := clamp(f32(lift.row) + (y - slot.y) / slot.height - lift.grab, f32(lift.first), f32(lift.last))
	lift.to = int(math.round(top))
	ui.motion_target(&menu.order_positions[lift.row], top, 0, .Linear, false)
}

// Eases every row toward its slot: with a row lifted, the rows between its own slot and `to` open the gap
// it would drop into (D-069). The settle ends once nothing moves.
document_order_animate :: proc(menu: ^Document_Menu, enabled: bool, frame: ui.Frame_Time) -> bool {
	if !menu.order_moving {return false}
	lift, lifted := menu.order.(Document_Order_Lift)
	changed, moving := false, false
	for i in 0 ..< len(menu.menu.items) {
		position := &menu.order_positions[i]
		if !lifted || i != lift.row {
			target := i
			if lifted && lift.row < lift.to && i > lift.row && i <= lift.to {target -= 1}
			if lifted && lift.to < lift.row && i >= lift.to && i < lift.row {target += 1}
			ui.motion_target(position, f32(target), ui.REORDER_DURATION, .Decelerate, enabled)
		}
		changed = ui.motion_update(position, frame) || changed
		moving ||= ui.motion_active(position^)
	}
	if !lifted && !moving {
		menu.order_moving, menu.order_settle, changed = false, nil, true
	}
	return changed
}

document_order_animating :: proc(w: ^Window) -> bool {
	menu := &w.document_menu
	if !document_menu_shown(w) || !menu.order_moving {return false}
	if _, settling := menu.order_settle.?; settling {return true}
	for i in 0 ..< len(menu.menu.items) {if ui.motion_active(menu.order_positions[i]) {return true}}
	return false
}

// Gives each row the offset and lift the menu draws it with.
@(private = "file")
document_order_place :: proc(menu: ^Document_Menu) {
	lift, lifted := menu.order.(Document_Order_Lift)
	settle, settling := menu.order_settle.?
	for &item, row in menu.menu.items {
		item.offset = menu.order_moving ? (menu.order_positions[row].value - f32(row)) * ui.MENU_ROW_HEIGHT : 0
		item.lifted = lifted && row == lift.row || settling && row == settle
	}
}

// A press past the drag threshold lifts its row; a lifted row follows the pointer. True while the press
// or lift has the pointer.
@(private = "file")
document_order_hover :: proc(app: ^App, w: ^Window, x, y: f32, left_held: bool) -> bool {
	menu := &w.document_menu
	if menu.order == nil {return false}
	if !left_held {
		document_order_end(app, w)
		return false
	}
	if press, pressed := menu.order.(Document_Order_Press); pressed {
		if math.abs(x - press.start_x) < DRAG_THRESHOLD * w.scale &&
		   math.abs(y - press.start_y) < DRAG_THRESHOLD * w.scale {
			pointer_set(app, w, .Hand)
			return true
		}
		// A row lifted while the rows still settle carries on from where they are drawn.
		if !menu.order_moving {
			for i in 0 ..< len(menu.menu.items) {menu.order_positions[i] = {value = f32(i), target = f32(i)}}
		}
		first, last := document_order_group(menu, press.row)
		menu.order = Document_Order_Lift{press.row, first, last, press.row, press.grab}
		menu.order_moving, menu.order_settle = true, nil
		ui.menu_select(&menu.menu, press.row)
		document_submenu_reset(menu)
	}
	document_order_move(w, y)
	_ = document_order_animate(menu, app.animations, window_frame_time(app, w))
	w.dirty = true
	pointer_set(app, w, .Resize_All)
	return true
}

// Lets go of a press or lift without reordering: a lifted row settles back into its slot.
@(private = "file")
document_order_end :: proc(app: ^App, w: ^Window) {
	menu := &w.document_menu
	lift, lifted := menu.order.(Document_Order_Lift)
	menu.order = nil
	if !lifted {return}
	menu.order_settle = lift.row
	_ = document_order_animate(menu, app.animations, window_frame_time(app, w))
	w.dirty = true
}

// The release of a press on a pinned row: a press that never lifted opens its row if released on it, and a
// lifted row drops into the slot it opened, moving its document there within its level.
@(private = "file")
document_order_release :: proc(app: ^App, w: ^Window, x, y: f32) {
	menu := &w.document_menu
	switch order in menu.order {
	case nil:
	case Document_Order_Press:
		menu.order = nil
		if ui.menu_hit(&menu.menu, x, y, f32(w.width), f32(w.height), w.scale) == order.row {
			document_menu_activate(app, w, order.row)
		}
	case Document_Order_Lift:
		document_order_move(w, y)
		lift := menu.order.(Document_Order_Lift)
		menu.order = nil
		settle := lift.row
		if lift.to != lift.row && document_order_commit(app, w, lift) {settle = lift.to}
		menu.order_settle = settle
		_ = document_order_animate(menu, app.animations, window_frame_time(app, w))
		w.dirty = true
	}
}

// Moves the lifted row's document onto the slot of row `to` and rebuilds the rows, each carrying on from
// where it was drawn so the drop settles rather than jumps.
@(private = "file")
document_order_commit :: proc(app: ^App, w: ^Window, lift: Document_Order_Lift) -> bool {
	menu := &w.document_menu
	state := document_menu_state(w)
	if state == nil {return false}
	scopes, found := document_scopes(app, state.content)
	moved, _ := document_menu_entry(menu, lift.row)
	onto, _ := document_menu_entry(menu, lift.to)
	if !found || !document_reorder(scopes, moved.level, moved.target, onto.target) {return false}
	drawn := menu.order_positions
	documents_changed(app)
	document_menu_build(app, w)
	// The rows between the two slots shifted one place as the list did.
	from, to := lift.row, lift.to
	step := from < to ? 1 : -1
	for i := to; i != from; i -= step {menu.order_positions[i - step] = drawn[i]}
	menu.order_positions[to] = drawn[from]
	menu.order_moving = true
	ui.menu_select(&menu.menu, to)
	return true
}

// A left click runs a row; a right click on a pinned document opens its right-click menu there.
document_menu_button :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) {
	menu := &w.document_menu
	if !e.pressed {
		w.dirty = true
		ui.field_release(&menu.url)
		ui.field_release(&menu.search)
		if e.button == .Left {document_order_release(app, w, f32(e.x), f32(e.y))}
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
	if document_submenu_shown(w) {
		if hit := ui.menu_hit(&menu.submenu, x, y, f32(w.width), f32(w.height), w.scale); hit >= 0 {
			if e.button == .Left {
				document_link_choose(app, w, transmute(Link_Choice)menu.submenu.items[hit].payload)
			}
			return
		}
	}
	if _, actions := document_menu_actions(w); actions {
		hit := ui.menu_hit(&menu.actions, x, y, f32(w.width), f32(w.height), w.scale)
		if hit >= 0 && e.button == .Left && menu.actions.items[hit].enabled {
			document_actions_choose(app, w, transmute(Link_Choice)menu.actions.items[hit].payload)
		} else if hit < 0 {
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
	entry, _ := document_menu_entry(menu, hit)
	if e.button == .Right {
		document_actions_open(app, w, hit, x, y)
		return
	}
	if e.button != .Left {return}
	if entry.action == .Url_Field || entry.action == .Search_Field {
		if box, field, shown := document_field_box(w, entry.action); shown {
			ui.field_pointer(field, ui.field_box_offset(box, x), true, .Shift in e.modifiers)
			w.dirty = true
		}
		return
	}
	item := menu.menu.items[hit]
	if !item.enabled || item.separator {return}
	ui.menu_select(&menu.menu, hit)
	part := ui.menu_row_part(&menu.menu, hit, x, y, width, height, w.scale)
	// A pinned row opens on release, unless the press becomes a drag that reorders it. A filtered list
	// hides rows a drop would land among, so it only opens.
	if state := document_menu_state(w); part == .Row && entry.action == .Open && state != nil &&
	   ui.field_string(&menu.search) == "" {
		if _, listing := state.mode.(Document_Menu_List); listing {
			row := ui.menu_row_rect(&menu.menu, hit, width, height, w.scale)
			menu.order = Document_Order_Press{hit, x, y, (y - row.y) / row.height}
			w.dirty = true
			return
		}
	}
	switch part {
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
	document_order_place(menu)
	// Program rows name Link Programs by their place in settings' order, found once per draw.
	order: [settings.OPENER_LIMIT]int
	programs := order[:settings.openers_in_order(&app.settings.openers, order[:])]
	for &item, row in menu.menu.items {
		item.icon_atlas = {}
		entry, listed := document_menu_entry(menu, row)
		if !listed || entry.action != .Link {continue}
		if result := link_choice_icon(app, w, &item, entry.link, programs); result != .Ok {return result}
	}
	if result := ui.menu_draw(&menu.menu, &w.list, &w.ui_text, app.theme, width, height, s, w.pointer);
	   result != .Ok {return result}
	_, entering := document_menu_url_entry(w)
	for action in ([?]Document_Menu_Action{.Search_Field, .Url_Field}) {
		box, _, shown := document_field_box(w, action)
		if !shown {continue}
		url := action == .Url_Field
		radius := ui.RADIUS_CONTROL * s
		fill := render.Rect_Instance{rect = box.rect, color = app.theme.pane, radius = radius}
		if render.push_rect(&w.list, fill) != .None {return .Ok}
		ink := url ? app.theme.accent : app.theme.border
		edge := render.Rect_Instance{rect = box.rect, color = ink, radius = radius, stroke = s}
		if render.push_rect(&w.list, edge) != .None {return .Ok}
		focused := url == entering
		placeholder := url ? "https://" : "Search links"
		if result := ui.field_box_draw(box, &w.list, app.theme, ui.field_box_baseline(box), focused, placeholder);
		   result != .Ok {return result}
	}
	_, actions := document_menu_actions(w)
	if actions {
		for &item in menu.actions.items {
			item.icon_atlas = {}
			if item.separator {continue}
			choice := transmute(Link_Choice)item.payload
			if result := link_choice_icon(app, w, &item, choice, programs); result != .Ok {return result}
		}
		if result := ui.menu_draw(&menu.actions, &w.list, &w.ui_text, app.theme, width, height, s, w.pointer);
		   result != .Ok {return result}
	}
	if document_submenu_shown(w) {
		return ui.menu_draw(&menu.submenu, &w.list, &w.ui_text, app.theme, width, height, s, w.pointer)
	}
	if actions {return .Ok}
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

// Gives a program's row the program's icon once it is ready; until then, and for other rows, the row
// keeps its glyph. `programs` holds indices into the Link Programs list in settings' order.
@(private = "file")
link_choice_icon :: proc(
	app: ^App,
	w: ^Window,
	item: ^ui.Menu_Item,
	choice: Link_Choice,
	programs: []int,
) -> render.Build_Status {
	if choice.action != .Program || int(choice.program) >= len(programs) {return .Ok}
	program := &app.settings.openers.items[programs[choice.program]]
	atlas, result := link_program_icon(app, program, 16 * w.scale)
	item.icon_atlas = atlas
	return result
}

when AIO_CONTROL {
	// The Links menu's keys; documents.mode is list, pin or link, and empty while it is closed.
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
		_, actions := document_menu_actions(w)
		state_value(r, "documents.open", document_menu_shown(w))
		state_text(r, "documents.mode", mode)
		state_value(r, "documents.count", w.document_menu.count)
		state_value(r, "documents.popout", popout)
		state_value(r, "documents.url_open", url_entry)
		state_value(r, "documents.actions", actions)
		state_value(r, "documents.submenu", document_submenu_shown(w))
		state_text(r, "documents.query", ui.field_string(&w.document_menu.search))
		// The labels of program rows that drew their program's icon in the last frame, joined by ';'.
		icons := strings.builder_make(context.temp_allocator)
		for menu in ([?]^ui.Menu{&w.document_menu.menu, &w.document_menu.actions}) {
			for item in menu.items {
				if item.icon_atlas.width <= 0 {continue}
				if strings.builder_len(icons) > 0 {strings.write_byte(&icons, ';')}
				strings.write_string(&icons, item.label)
			}
		}
		state_text(r, "documents.program_icons", strings.to_string(icons))
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
document_menu_pointer_cancel :: proc(app: ^App, w: ^Window) {
	ui.field_release(&w.document_menu.url)
	ui.field_release(&w.document_menu.search)
	document_order_end(app, w)
}

@(private)
document_menu_leave :: proc(_: ^App, w: ^Window) {
	w.document_menu.menu.hover_part = .Row
}
