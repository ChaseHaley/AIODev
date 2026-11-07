package ui

import "aio:colour"
import "aio:commands"
import "aio:input"
import "aio:platform"
import "aio:render"
import "aio:settings"
import "base:runtime"
import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

Row_Kind :: enum {
	Text,
	Integer,
	Number,
	Toggle,
	Choice,
	Color,
	Optional_Color,
	Shortcut,
	Action,
	// One row per profile, its inline editor and the add row.
	Profile,
	Process_Group,
	Profile_Add,
	Profile_Icon,
}

// What saving an action or theme row asks the page owner to do. Rows are still found, searched and
// revealed by key; the action alone says what they run.
Page_Action :: enum {
	None,
	Theme_Name,
	Theme_Rename,
	Theme_Duplicate,
	Theme_Delete,
	Theme_Export,
	Theme_Color,
}

// Facts the profile table draws beside a row. Ordinary settings rows leave these unset.
Editor_Row_Flag :: enum {
	Default,
	Hidden,
	// The profile already has an explicit profile.order entry.
	Listed,
	// A profile found on this machine.
	Builtin,
	// A profile Settings may not delete (settings.profile_can_remove is false).
	Protected,
}

// Strings, `choices` and `choice_labels` are owned by the editor. `choice_labels`, when present,
// is what each choice displays; the choice itself is the saved value. An empty optional color has no
// color at all. Profile rows also own `profile`, `badge`, `detail` (extra search text) and `note`
// (an inline problem).
Editor_Row :: struct {
	key, title, description, value, default_value: string,
	group:                                         int,
	kind:                                          Row_Kind,
	minimum, maximum:                              f64,
	// The rounding of a numeric row; zero rounds by kind.
	step:                                          f64,
	// A choice whose popup has a filter field, such as a font picker.
	searchable:                                    bool,
	// A choice whose value is any combination of `choices`: bit i of `choice_mask` is choices[i].
	// The page edits the bits; its owner saves their names.
	multiple:                                      bool,
	choice_mask:                                   u32,
	choices, choice_labels:                        []string,
	// The narrowest the choice popup gets, in DIPs; zero follows the field.
	choice_min_width:                              f32,
	// The choice popup carries the Show all fonts switch, which reports .Font_Filter.
	font_filter:                                   bool,
	show_all_fonts:                                bool,
	shortcut_mode:                                 Shortcut_Mode,
	action:                                        Page_Action,
	profile, badge, detail, note:                  string,
	// The profile field an inline profile row edits.
	profile_field:                                 Maybe(settings.Profile_Field),
	flags:                                         bit_set[Editor_Row_Flag],
	process: int,
	process_field: Process_Field,
}

// A command shortcut holds several comma-separated alternatives; a Single chord such as the leader
// holds one.
Shortcut_Mode :: enum {
	Alternatives,
	Single,
}

Editor_Group :: struct {
	title: string,
	// The Profiles group draws column captions on its header line.
	table: bool,
}

// One page line: a group header, with its matching row count, when row is -1. Headers are never selected.
Editor_Item :: struct {
	group, row, count: int,
}

// Keyboard focus as readers see it: the search field, the selected row's control, its key-position
// switch, or Reset to Defaults. It is derived from Editor_Mode by editor_focus.
Editor_Focus :: enum {
	Search,
	Control,
	Positions,
	Reset_All,
}

Editor_Popup :: enum {
	None,
	Choice,
	Color,
	Shortcuts,
}

// What the page is doing, one state at a time. Each state carries what is valid only in it, so a
// capture cannot run under a popup, a colour drag cannot outlive its picker and the profile menu
// cannot open over a list. editor_mode_set is the only writer. Reordering rows is Editor_Order.
Editor_Mode :: union #no_nil {
	Editor_Browsing,
	Editor_Editing,
	Editor_Positions,
	Editor_Reset_All,
	Editor_Shortcut,
	Editor_Choice_Popup,
	Editor_Color_Popup,
	Editor_Profile_Menu,
}

// The search field has the keyboard; `selecting` while the pointer drags a selection in it.
Editor_Browsing :: struct {
	selecting: bool,
}

// The selected row's control has the keyboard.
Editor_Editing :: struct {
	drag: Editing_Drag,
}

Editing_Drag :: enum {
	None,
	// The pointer drags a selection in the value field.
	Value,
	Slider,
}

Editor_Positions :: struct {}

Editor_Reset_All :: struct {}

// A shortcut row's field has the keyboard; `capture` records chords or lists the alternatives.
Editor_Shortcut :: struct {}

Editor_Choice_Popup :: struct {
	// Tab moves the keyboard from the font search to its Show All Fonts switch.
	toggle_focus: bool,
	drag:         Choice_Drag,
}

// The pointer drags a selection in the popup's search field, or holds its scrollbar thumb.
Choice_Drag :: union {
	Choice_Search_Drag,
	Scroll_Drag,
}

Choice_Search_Drag :: struct {}

Editor_Color_Popup :: struct {
	drag: Color_Drag,
}

Color_Drag :: enum {
	None,
	Wheel,
	Ramp,
}

Editor_Profile_Menu :: struct {}

Order_Kind :: enum {
	Profiles,
	Process_Groups,
}

// A reorder drag, then its blocks easing into place once it ends. Nil while nothing reorders;
// profile_positions has entries only while Dragging or Settling. Only the order_ procs write it.
Editor_Order :: union {
	Order_Dragging,
	Order_Settling,
}

Order_Dragging :: struct {
	block:        Order_Block,
	// The grabbed block's index among the blocks, and the insertion slot a drop saves.
	from, target: int,
	// The pointer's line offset inside the grabbed block.
	grab:         f32,
}

// The grabbed block: a profile, whose owned ID a drop hands to its request, or a process group.
Order_Block :: union #no_nil {
	Order_Profile,
	Order_Group,
}

Order_Profile :: struct {
	id: string,
}

Order_Group :: struct {
	id: int,
}

Order_Settling :: struct {
	kind: Order_Kind,
}

// The profile table's sub-controls, in Tab and Left/Right order.
Profile_Control :: enum {
	Radio,
	Hidden,
	Expand,
	Duplicate,
	Remove,
	More,
}

// A profile write the page owner must perform. Expansion and collapse stay inside the editor; these
// requests describe a mutation for the page owner.
Profile_Action :: enum {
	Default,
	Duplicate,
	Remove,
}

// A write the page owner performs, named by the outcome that reports it. The owner takes it with
// editor_request_take as it handles that outcome, so a request never outlives it. Strings are owned.
Editor_Request :: union {
	Profile_Request,
	Profile_Hidden_Request,
	Profile_Order_Request,
	Process_Remove_Request,
}

Profile_Request :: struct {
	action: Profile_Action,
	id:     string,
}

Profile_Hidden_Request :: struct {
	id:     string,
	hidden: bool,
}

Profile_Order_Request :: struct {
	id:   string,
	slot: int,
}

Process_Remove_Request :: struct {
	group: int,
}

// A profile block's drawn first line while rows reorder. Like the tab strip's positions, the grabbed
// block follows the pointer and the others ease into place; entries exist from a reorder drag's start
// until every block settles.
Profile_Position :: struct {
	id:       string,
	position: Motion,
	lifted:   bool,
}

// The settings text a page shows; nil is Closed. The revision_ procs below own its transitions.
// Current matches the latest revision the page received; whether it has pending work is derived by
// editor_draft. Stale keeps that work and the older text when publication cannot reach it, so a save
// checks the older text rather than overwriting a newer file.
Editor_Revision :: union {
	Editor_Current,
	Editor_Stale,
}

Editor_Current :: struct {
	source: string,
}

Editor_Stale :: struct {
	source: string,
	reason: Editor_Stale_Reason,
}

Editor_Stale_Reason :: enum {
	// The file no longer holds the page's text: an external edit, found when a save checks the file.
	Changed_Outside,
	// Adopting the revision would drop a draft: its row is gone, or its program groups changed.
	Draft_Conflict,
	// Building the replacement page failed.
	Refresh_Failed,
}

// The revision a page shows and saves against, and whether it fell behind the file.
Page_Revision_State :: struct {
	revision: Editor_Revision,
}

editor_loaded :: proc(p: ^Editor) -> bool {
	return p.revision != nil
}

// The text the page shows and saves against; empty for a closed page.
editor_source :: proc(p: ^Editor) -> string {
	switch r in p.revision {
	case Editor_Current:
		return r.source
	case Editor_Stale:
		return r.source
	}
	return ""
}

// Takes ownership of the text only after a replacement page is built.
editor_revision_open :: proc(p: ^Editor, source: string) {
	editor_revision_close(p)
	p.revision = Editor_Current{source}
}

editor_revision_close :: proc(p: ^Editor) {
	delete(editor_source(p))
	p.revision = nil
}

// Records the first revision the page missed, retaining its source and pending work. A prompt about
// the old revision ends with it.
editor_revision_stale :: proc(p: ^Editor, reason: Editor_Stale_Reason) {
	if !editor_loaded(p) {return}
	editor_theme_delete_disarm(p)
	if _, stale := p.revision.(Editor_Stale); stale {return}
	p.revision = Editor_Stale{editor_source(p), reason}
}

// Pending work in the selected field, a shortcut capture or the program groups.
editor_draft :: proc(p: ^Editor) -> bool {
	row := editor_row(p)
	return p.process_dirty || editor_capturing(p) || (row != nil && field_string(&p.value) != row.value)
}

// The settings page shown in a settings tab. Only the selected row is edited; its pending value lives
// in `value` until it is saved. Profile, program group, revision and theme state belong to those
// features and are nested here so the page's procedures read them as page fields.
Editor :: struct {
	using profiles:                                                    Profile_Editor_State,
	using processes:                                                   Process_Editor_State,
	using page:                                                        Page_Revision_State,
	using themes:                                                      Theme_Page_State,
	hover_clear:                                                       bool,
	// The shortcut field's capture, alternatives list and key-positions choice.
	capture:                                                           Shortcut_Capture,
	mode:                                                              Editor_Mode,
	hover_item, hover_reset, hover_outline:                            int,
	choice_list:                                                       Choice_List,
	// The options a multiple choice has on while its popup edits them.
	choice_set:                                                        u32,
	// The group last chosen in the outline stays highlighted until the page scrolls or the selection moves,
	// since the final groups can be shown without reaching the top of the page.
	jump_group, outline_scroll, outline_active:                        int,
	rows:                                                              [dynamic]Editor_Row,
	groups:                                                            [dynamic]Editor_Group,
	items:                                                             [dynamic]Editor_Item,
	selected, scroll, visible_rows:                                    int,
	filter, value:                                                     Text_Field,
	choice_search:                                                     Text_Field,
	popup_bar_hover:                                                   bool,
	choice_matches:                                                    [dynamic]int,
	// The picker keeps hue and saturation while value is zero, where RGB alone would lose them.
	hsv:                                                               [3]f32,
	message:                                                           string,
	error:                                                             bool,
	// A write the page owner performs for profiles or program groups, and the reorder that rewrites
	// profile.order or the process groups.
	request:                                                           Editor_Request,
	order:                                                             Editor_Order,
	profile_positions:                                                 [dynamic]Profile_Position,
}
Editor_Outcome :: enum {
	None,
	Changed,
	Save,
	Reset,
	Reset_All,
	Profile_Action,
	Process_Save,
	Process_Remove,
	Font_Filter,
}

// Table state a settings reload keeps: expansion and blocks still settling after a reorder, with
// the kind of block they are.
Editor_View :: struct {
	process_expanded:  int,
	expanded:          string,
	order:             Order_Kind,
	profile_positions: [dynamic]Profile_Position,
}

// Wide pages put the search field and a group outline in a left column; narrow ones have no outline.
Editor_Layout :: struct {
	page, filter, list, outline:                     render.Rect,
	row_height, outline_row_height, status_x, scale: f32,
	rows:                                            int,
}

// The vertical centre of the page header: the Settings title, the summary and Reset to Defaults.
@(private)
HEADER_CENTER :: 30

editor_reset_all_rect :: proc(l: Editor_Layout) -> render.Rect {
	right := max(l.filter.x + l.filter.width, l.list.x + l.list.width)
	width := min(148 * l.scale, max(0, l.page.width - 160 * l.scale))
	y := l.page.y + (HEADER_CENTER - HEIGHT_STANDARD / 2) * l.scale
	return {right - width, y, width, HEIGHT_STANDARD * l.scale}
}

// The parts of one setting row; zero-sized parts do not exist for its kind.
Row_Parts :: struct {
	row, reset, field, toggle, slider, swatch, positions, clear: render.Rect,
	text_right:                                                 f32,
	positions_label_below:                                      bool,
}

@(private)
ROW_HEIGHT :: 52
@(private)
CHOICE_HEIGHT :: HEIGHT_STANDARD
@(private)
OUTLINE_ROW_HEIGHT :: RAIL_ROW_HEIGHT
@(private)
OUTLINE_WIDTH :: 220
@(private)
OUTLINE_MIN_PAGE :: 720

// Every string a row owns, in one place for editor_add's copies and editor_row_destroy's frees.
@(private)
row_owned_strings :: proc(row: ^Editor_Row) -> [9]^string {
	return {
		&row.key,
		&row.title,
		&row.description,
		&row.value,
		&row.default_value,
		&row.profile,
		&row.badge,
		&row.detail,
		&row.note,
	}
}

editor_row_destroy :: proc(row: ^Editor_Row) {
	for text in row_owned_strings(row) {delete(text^)}
	for choice in row.choices {delete(choice)}
	delete(row.choices)
	for label in row.choice_labels {delete(label)}
	delete(row.choice_labels)
}

editor_destroy :: proc(p: ^Editor) {
	profile_editor_destroy(&p.profiles)
	for &row in p.rows {editor_row_destroy(&row)}
	for group in p.groups {delete(group.title)}
	delete(p.rows)
	delete(p.groups)
	delete(p.items)
	delete(p.filter.bytes)
	delete(p.value.bytes)
	delete(p.choice_search.bytes)
	delete(p.choice_matches)
	delete(p.process_source)
	editor_revision_close(p)
	delete(p.message)
	delete(p.theme)
	editor_request_destroy(&p.request)
	if drag, dragging := p.order.(Order_Dragging); dragging {order_block_free(drag.block)}
	profile_positions_clear(&p.profile_positions)
	delete(p.profile_positions)
	p^ = {}
}

// Copies the table state a reload must keep. The caller frees the result with editor_view_destroy
// after editor_view_restore, which moves the strings into the rebuilt page. A drag keeps the pointer
// on this page; its blocks settle on the rebuilt one.
@(require_results)
editor_view_take :: proc(p: ^Editor) -> (view: Editor_View, alloc_error: runtime.Allocator_Error) {
	view.process_expanded = p.process_expanded
	view.expanded = strings.clone(p.expanded) or_return
	view.order, _ = order_kind(p)
	view.profile_positions, p.profile_positions = p.profile_positions, {}
	if _, settling := p.order.(Order_Settling); settling {order_settle(p, view.order)}
	return
}

editor_view_destroy :: proc(view: ^Editor_View) {
	delete(view.expanded)
	profile_positions_clear(&view.profile_positions)
	delete(view.profile_positions)
	view^ = {}
}

// Restores a previous view into a page whose rows now exist, dropping a profile that no longer
// does. A reload after a successful save must land back on the same expanded row.
editor_view_restore :: proc(p: ^Editor, view: ^Editor_View) {
	p.process_expanded = view.process_expanded
	delete(p.expanded)
	p.expanded, view.expanded = view.expanded, ""
	if drag, dragging := p.order.(Order_Dragging); dragging {order_block_free(drag.block)}
	profile_positions_clear(&p.profile_positions)
	delete(p.profile_positions)
	p.profile_positions, view.profile_positions = view.profile_positions, {}
	order_settle(p, view.order)
	if p.expanded != "" && !editor_has_profile_row(p, p.expanded) {delete(p.expanded); p.expanded = ""}
}

// How a page meets a rebuild for a new revision.
Editor_Adoption :: enum {
	// The page that saved the revision accepts its saved field.
	Saved_Origin,
	// Another page showing the saved revision keeps its pending text and selection.
	Saved_Other,
	// The file was read again; every page keeps drafts whose rows remain.
	Reloaded,
}

Editor_Adoption_Result :: enum {
	Adopted,
	// Adopting would drop a draft, so the page stays behind the revision.
	Draft_Conflict,
	// The program drafts could not be copied, so the page stays behind the revision.
	Draft_Copy_Failed,
}

// Replaces `p` with `next`, the page rebuilt for a new revision, carrying what the user was doing:
// program drafts, the search, the selected row with its focus and any draft, and the scroll. A
// program draft whose groups changed underneath, or a field draft whose row is gone, is a semantic
// conflict; then `p` keeps its old source and drafts and is marked behind the file, so saving cannot
// silently recreate a removed profile or discard the draft. On success `next` is left empty.
editor_adopt :: proc(p, next: ^Editor, adoption: Editor_Adoption) -> Editor_Adoption_Result {
	preserve_draft := adoption != .Saved_Origin
	if p.process_dirty {
		if preserve_draft && p.process_source != next.process_source {
			editor_revision_stale(p, .Draft_Conflict)
			return .Draft_Conflict
		}
		if editor_process_copy_draft(p, next) != nil {
			editor_revision_stale(p, .Refresh_Failed)
			return .Draft_Copy_Failed
		}
	}
	field_set(&next.filter, field_string(&p.filter))
	editor_filter(next)
	row := editor_row(p)
	selected := row != nil && editor_reveal(next, Reveal_Row{row.key})
	// Program drafts already rode along above; only a draft on a selected row can be orphaned.
	draft := preserve_draft && row != nil && editor_draft(p)
	if draft && !selected {
		editor_revision_stale(p, .Draft_Conflict)
		return .Draft_Conflict
	}
	next.filter.cursor, next.filter.anchor = p.filter.cursor, p.filter.anchor
	next.scroll = clamp(p.scroll, 0, max(0, len(next.items) - max(1, p.visible_rows)))
	if selected {editor_carry(next, p, draft)}
	editor_destroy(p)
	p^, next^ = next^, {}
	return .Adopted
}

// Moves what the user was doing into a rebuilt page that has the same setting selected. The keyboard
// focus survives, with a popup that saves as it changes: a multiple choice, or a colour picker whose
// drag saved on release. A draft also keeps its unsaved value, capture or popup, and its message.
// Pointer drags and the profile menu end with the page they belonged to.
@(private)
editor_carry :: proc(to, from: ^Editor, draft: bool) {
	row, next := editor_row(from), editor_row(to)
	to.profile_control = from.profile_control
	mode := focus_mode(editor_focus(from))
	popup := editor_popup(from)
	if popup == .Choice && row.multiple && next.multiple {
		mode = Editor_Choice_Popup{}
		to.choice_list = from.choice_list
	}
	// A picker keeps its hue and saturation even at black, where rebuilding them from RGB loses both.
	if popup == .Color && next.kind == row.kind {
		mode = Editor_Color_Popup{}
		previous_color, previous_ok, _ := settings.parse_color(field_string(&from.value))
		next_color, next_ok, _ := settings.parse_color(field_string(&to.value))
		if previous_ok && next_ok && previous_color == next_color {to.hsv = from.hsv}
	}
	if draft {
		delete(to.value.bytes)
		to.value, from.value = from.value, {}
		shortcut_capture_carry(&to.capture, &from.capture)
		to.choice_list = from.choice_list
		to.choice_set = from.choice_set
		to.hsv = from.hsv
		#partial switch _ in from.mode {
		case Editor_Choice_Popup:
			mode = Editor_Choice_Popup{}
		case Editor_Color_Popup:
			mode = Editor_Color_Popup{}
		case Editor_Shortcut:
			mode = Editor_Shortcut{}
		}
		editor_message(to, from.message, from.error)
		if from.error_key != "" {editor_error_set(to, from.error_profile, from.error_key, from.error_text)}
	}
	editor_mode_set(to, mode)
}

// Keeps the page scrolled to `scroll` as far as its current lines allow.
editor_scroll_keep :: proc(p: ^Editor, scroll: int) {
	p.scroll = clamp(scroll, 0, max_scroll(p))
}

// The page's theme state: the active theme of its revision, and Delete Theme's two-press prompt.
// The first press arms it and shows the prompt; only the next press on the same page deletes. Any
// other page action, focus leaving, Escape, the page falling behind a revision and the page itself
// ending disarm it, so a confirmation never reaches a theme the prompt did not name.
Theme_Page_State :: struct {
	// Owned.
	theme:         string,
	delete_armed:  bool,
	// The status line still shows the prompt; any other message replaces it.
	delete_prompt: bool,
}

@(require_results)
editor_theme_set :: proc(p: ^Editor, theme: string) -> runtime.Allocator_Error {
	owned := strings.clone(theme) or_return
	delete(p.theme)
	p.theme = owned
	return nil
}

// A Delete Theme press: true when it answers the prompt, which disarms it; otherwise it arms the
// prompt for the page's theme.
editor_theme_delete_press :: proc(p: ^Editor) -> bool {
	if p.delete_armed {
		editor_theme_delete_disarm(p)
		return true
	}
	editor_message(
		p,
		fmt.tprintf("Delete theme %s and its colors? Press Delete Theme again to confirm.", p.theme),
		true,
	)
	p.delete_armed, p.delete_prompt = true, true
	return false
}

// Also takes down the prompt, which would otherwise ask for a press that no longer deletes.
editor_theme_delete_disarm :: proc(p: ^Editor) {
	if !p.delete_armed {return}
	if p.delete_prompt {editor_message(p, "", false)}
	p.delete_armed = false
}

// Every outcome the page owner handles first ends a Delete Theme prompt, except the press that
// answers it.
editor_outcome_begin :: proc(p: ^Editor, outcome: Editor_Outcome) {
	row := editor_row(p)
	answers := (outcome == .Save || outcome == .Reset) && row != nil && row.action == .Theme_Delete
	if !answers {editor_theme_delete_disarm(p)}
}

@(private)
editor_has_profile_row :: proc(p: ^Editor, id: string) -> bool {
	for row in p.rows {
		if row.kind == .Profile && row.profile == id {return true}
	}
	return false
}

// The only writer of p.request. The editor takes ownership of the request's strings.
editor_request_set :: proc(p: ^Editor, request: Editor_Request) {
	editor_request_destroy(&p.request)
	p.request = request
}

// Hands the pending request to the page owner, who frees it with editor_request_destroy.
@(require_results)
editor_request_take :: proc(p: ^Editor) -> Editor_Request {
	request := p.request
	p.request = nil
	return request
}

editor_request_destroy :: proc(request: ^Editor_Request) {
	switch r in request^ {
	case Profile_Request:
		delete(r.id)
	case Profile_Hidden_Request:
		delete(r.id)
	case Profile_Order_Request:
		delete(r.id)
	case Process_Remove_Request:
	}
	request^ = nil
}

@(private)
profile_request :: proc(p: ^Editor, action: Profile_Action, id: string) -> Editor_Outcome {
	editor_request_set(p, Profile_Request{action, strings.clone(id)})
	return .Profile_Action
}

// Marks one field row with an inline problem. The status line keeps the long form.
editor_error_set :: proc(p: ^Editor, profile, key, text: string) {
	editor_error_clear(p)
	p.error_key = strings.clone(key)
	p.error_profile = strings.clone(profile)
	p.error_text = strings.clone(text)
}

editor_error_clear :: proc(p: ^Editor) {
	delete(p.error_key)
	delete(p.error_profile)
	delete(p.error_text)
	p.error_key, p.error_profile, p.error_text = "", "", ""
}

@(require_results)
editor_add :: proc(p: ^Editor, row: Editor_Row, group: string) -> runtime.Allocator_Error {
	group_index := -1
	for g, i in p.groups {if g.title == group {group_index = i}}
	if group_index < 0 {
		title := strings.clone(group) or_return
		if _, err := append(&p.groups, Editor_Group{title = title});
		   err != nil {delete(title); return err}
		group_index = len(p.groups) - 1
	}
	source := row
	added := row
	added.choices, added.choice_labels = nil, nil
	targets := row_owned_strings(&added)
	for target in targets {target^ = ""}
	success := false
	defer if !success {editor_row_destroy(&added)}
	for text, i in row_owned_strings(&source) {targets[i]^ = strings.clone(text^) or_return}
	if len(row.choices) > 0 {
		added.choices = make([]string, len(row.choices)) or_return
		for choice, i in row.choices {added.choices[i] = strings.clone(choice) or_return}
	}
	if len(row.choice_labels) > 0 {
		assert(len(row.choice_labels) == len(row.choices))
		added.choice_labels = make([]string, len(row.choice_labels)) or_return
		for label, i in row.choice_labels {added.choice_labels[i] = strings.clone(label) or_return}
	}
	added.group = group_index
	_, err := append(&p.rows, added)
	success = err == nil
	return err
}

// Marks a group as the profile table so its header carries the column captions.
editor_group_table :: proc(p: ^Editor, group: string) {
	for &g in p.groups {
		if g.title == group {g.table = true}
	}
}

editor_message :: proc(p: ^Editor, text: string, error: bool) {
	delete(p.message)
	p.message = strings.clone(text)
	p.error = error
	p.delete_prompt = false
}

editor_row :: proc(p: ^Editor) -> ^Editor_Row {
	if p.selected < 0 || p.selected >= len(p.items) || p.items[p.selected].row < 0 {return nil}
	return &p.rows[p.items[p.selected].row]
}

editor_capturing :: proc(p: ^Editor) -> bool {
	_, shortcut := p.mode.(Editor_Shortcut)
	return shortcut && shortcut_capture_recording(&p.capture)
}

editor_focus :: proc(p: ^Editor) -> Editor_Focus {
	#partial switch _ in p.mode {
	case Editor_Browsing:
		return .Search
	case Editor_Positions:
		return .Positions
	case Editor_Reset_All:
		return .Reset_All
	}
	return .Control
}

editor_popup :: proc(p: ^Editor) -> Editor_Popup {
	#partial switch _ in p.mode {
	case Editor_Choice_Popup:
		return .Choice
	case Editor_Color_Popup:
		return .Color
	case Editor_Shortcut:
		if p.capture.state == .Alternatives {return .Shortcuts}
	}
	return .None
}

editor_editing :: proc(p: ^Editor) -> bool {return editor_focus(p) == .Control}

// Whether the keyboard is on the font search's Show All Fonts switch.
editor_choice_toggle_focused :: proc(p: ^Editor) -> bool {
	choice, open := p.mode.(Editor_Choice_Popup)
	return open && choice.toggle_focus
}

// Whether the pointer holds anything on the page: a selection, a slider, a picker, a scrollbar thumb
// or a reordering block.
editor_dragging :: proc(p: ^Editor) -> bool {
	if _, reordering := p.order.(Order_Dragging); reordering {return true}
	switch m in p.mode {
	case Editor_Browsing:
		return m.selecting
	case Editor_Editing:
		return m.drag != .None
	case Editor_Choice_Popup:
		return m.drag != nil
	case Editor_Color_Popup:
		return m.drag != .None
	case Editor_Positions, Editor_Reset_All, Editor_Shortcut, Editor_Profile_Menu:
	}
	return false
}

// Whether the pointer holds the choice list's scrollbar thumb.
editor_scrollbar_dragging :: proc(p: ^Editor) -> bool {
	choice, open := p.mode.(Editor_Choice_Popup)
	if !open {return false}
	_, holding := choice.drag.(Scroll_Drag)
	return holding
}

// Moves the keyboard to the search field, closing whatever the selected row had open.
editor_browse :: proc(p: ^Editor) {editor_mode_set(p, Editor_Browsing{})}

// Moves the keyboard to the selected row's control.
editor_focus_row :: proc(p: ^Editor) {editor_mode_set(p, Editor_Editing{})}

// The only writer of p.mode, which is also what shows the profile menu. A capture's or the alternatives
// list's hint is cleared by the moves that dismiss them, not by every exit: saving keeps it, so a
// refused save that resumes the capture still shows it.
@(private)
editor_mode_set :: proc(p: ^Editor, next: Editor_Mode) {
	p.mode = next
	// The capture's state means something only while its field has the keyboard.
	if _, shortcut := next.(Editor_Shortcut); !shortcut {p.capture.state = .Idle}
}

@(private)
mode_shows_hint :: proc(mode: Editor_Mode) -> bool {
	#partial switch _ in mode {
	case Editor_Shortcut:
		return true
	}
	return false
}

// The resting state with the keyboard at `focus`.
@(private)
focus_mode :: proc(focus: Editor_Focus) -> Editor_Mode {
	switch focus {
	case .Search:
		return Editor_Browsing{}
	case .Control:
		return Editor_Editing{}
	case .Positions:
		return Editor_Positions{}
	case .Reset_All:
		return Editor_Reset_All{}
	}
	return Editor_Browsing{}
}

@(private)
filtering :: proc(p: ^Editor) -> bool {return strings.trim_space(field_string(&p.filter)) != ""}

// A swatch shows a translucent color as it blends over the row.
@(private)
swatch_color :: proc(value: string) -> (render.Color, bool) {
	c, ok := colour.parse_translucent(value, .Permissive)
	return colour.rgba(c.rgb, f32(c.a) / 255), ok
}

@(private)
sync_color :: proc(p: ^Editor) {
	row := editor_row(p)
	if row == nil || (row.kind != .Color && row.kind != .Optional_Color) {return}
	c, ok, _ := settings.parse_color(field_string(&p.value))
	if !ok || colour.hsv_to_rgb(p.hsv[0], p.hsv[1], p.hsv[2]) == c {return}
	h, s, v := colour.rgb_to_hsv(c)
	if s == 0 || v == 0 {h = p.hsv[0]}
	if v == 0 {s = p.hsv[1]}
	p.hsv = {h, s, v}
}

// Leaves the selected row's control, discarding an unsaved value.
@(private)
stop_editing :: proc(p: ^Editor) {
	if p.error || mode_shows_hint(p.mode) {editor_message(p, "", false)}
	if p.error_text != "" {
		editor_message(p, "", false)
		editor_error_clear(p)
	}
	editor_mode_set(p, Editor_Browsing{})
	order_cancel(p)
	if row := editor_row(p); row != nil {
		field_set(&p.value, row.value)
		p.choice_set = row.choice_mask
		sync_color(p)
	}
}

// Selects a page line. Whatever the previous row had open closes; a field keeps the keyboard when
// the next row can take it.
editor_select :: proc(p: ^Editor, index: int) {
	if !editor_process_capture(p) {return}
	if p.error || mode_shows_hint(p.mode) {editor_message(p, "", false)}
	if p.error_text != "" {
		editor_message(p, "", false)
		editor_error_clear(p)
	}
	p.jump_group = -1
	p.selected = clamp(index, 0, max(0, len(p.items) - 1))
	row := editor_row(p)
	focus := editor_focus(p)
	if row == nil || row.kind == .Shortcut || focus == .Positions {focus = .Search}
	editor_mode_set(p, focus_mode(focus))
	order_cancel(p)
	if row != nil {
		field_set(&p.value, row.value)
		p.choice_set = row.choice_mask
		p.hsv = {0, 0, 1}
		sync_color(p)
	}
	p.profile_control = .Radio
	if p.selected < p.scroll {p.scroll = p.selected}
	if p.selected >= p.scroll + max(1, p.visible_rows) {
		p.scroll = p.selected - max(1, p.visible_rows) + 1
	}
}

editor_select_key :: proc(p: ^Editor, key: string) -> bool {
	for row, i in p.rows {
		if row.key != key {continue}
		for item, index in p.items {
			if item.row == i {editor_select(p, index); return true}
		}
	}
	return false
}

// What a reveal selects: one row by key, or the first row of a section whose rows have no fixed key.
Reveal_Target :: union #no_nil {
	Reveal_Row,
	// The first profile, or Add Profile when there is none.
	Reveal_Profiles,
	// The first program group, or Add Group when there is none.
	Reveal_Program_Groups,
}

Reveal_Row :: struct {
	key: string,
}

Reveal_Profiles :: struct {}

Reveal_Program_Groups :: struct {}

// Selects a row, opening the profile or program group that owns it first. A palette jump or a
// reveal must be able to land on a field the collapsed table is not showing.
editor_reveal :: proc(p: ^Editor, target: Reveal_Target) -> bool {
	key: string
	switch t in target {
	case Reveal_Row:
		key = t.key
	case Reveal_Profiles:
		for row in p.rows {
			if row.kind == .Profile {key = row.key; break}
			if row.kind == .Profile_Add && key == "" {key = row.key}
		}
	case Reveal_Program_Groups:
		key = process_key(0, ".add")
		for row in p.rows {if row.process_field == .Group {key = row.key; break}}
	}
	for row in p.rows {
		if row.key != key {continue}
		if row.process > 0 && row.process_field != .Group {
			p.process_expanded = row.process
			editor_rebuild(p)
		}
		if row.kind != .Profile && row.profile != "" && p.expanded != row.profile {
			editor_profile_set_expanded(p, row.profile)
			editor_rebuild(p)
		}
		break
	}
	return editor_select_key(p, key)
}

// Each query word matches as written or, for plurals such as "panes", without its final s.
@(private)
row_matches :: proc(words: []string, haystack: string, fuzzy: bool = false) -> bool {
	for word in words {
		if strings.contains(haystack, word) {continue}
		if len(word) > 3 &&
		   word[len(word) - 1] == 's' &&
		   strings.contains(haystack, word[:len(word) - 1]) {
			continue
		}
		if !fuzzy {return false}
		at := 0
		for c in haystack {
			if at >= len(word) {break}
			wanted, size := utf8.decode_rune(word[at:])
			if wanted == c {at += size}
		}
		if at != len(word) {return false}
	}
	return true
}

// Whether a row belongs to the page in the current expansion state, before search ranks it.
@(private)
row_available :: proc(p: ^Editor, row: Editor_Row) -> bool {
	if row.process_field != .None {
		return row.process == 0 || row.process_field == .Group || row.process == p.process_expanded
	}
	#partial switch row.kind {
	case .Profile, .Profile_Add:
		return true
	}
	return row.profile == "" || row.profile == p.expanded
}

// Rebuilds the visible lines, keeping the current selection when it stays visible.
editor_rebuild :: proc(p: ^Editor) {
	selected := Editor_Item{-1, -1, 0}
	if p.selected >= 0 && p.selected < len(p.items) {selected = p.items[p.selected]}
	clear(&p.items)
	query := strings.to_lower(strings.trim_space(field_string(&p.filter)), context.temp_allocator)
	words := strings.fields(query, context.temp_allocator)
	ranks := make([]u8, len(p.rows), context.temp_allocator)
	best: u8
	for row, i in p.rows {
		if !row_available(p, row) {continue}
		haystack := strings.to_lower(
			fmt.tprintf(
				"%s %s %s %s %s %s %s",
				row.key,
				row.title,
				p.groups[row.group].title,
				row.description,
				row.detail,
				row.badge,
				row.kind == .Shortcut ? row.value : "",
			),
			context.temp_allocator,
		)
		if row_matches(words, haystack) {
			ranks[i] = 4
		} else if row.kind == .Shortcut &&
		   row_matches(words, strings.to_lower(row.value, context.temp_allocator), true) {
			ranks[i] = 3
		} else if row_matches(words, strings.to_lower(row.title, context.temp_allocator), true) {
			ranks[i] = 2
		} else if row_matches(words, haystack, true) {ranks[i] = 1}
		best = max(best, ranks[i])
	}
	matched := make([dynamic]int, context.temp_allocator)
	for _, g in p.groups {
		clear(&matched)
		for row, i in p.rows {
			if row.group != g {continue}
			if best > 0 && ranks[i] == best {append(&matched, i)}
		}
		if len(matched) == 0 {continue}
		append(&p.items, Editor_Item{g, -1, len(matched)})
		for i in matched {append(&p.items, Editor_Item{g, i, 0})}
	}
	p.selected = 0
	for item, index in p.items {
		if item.group == selected.group && item.row == selected.row {p.selected = index}
	}
}

editor_filter :: proc(p: ^Editor) {
	clear(&p.items)
	editor_rebuild(p)
	first := 0
	for item, index in p.items {if item.row >= 0 {first = index; break}}
	p.scroll, p.outline_scroll = 0, 0
	editor_select(p, first)
}

// Sets the one profile whose inline editor is open, "" for none; only a reload's view writes it
// otherwise. A page about to reload calls this directly, since the reload rebuilds the page.
editor_profile_set_expanded :: proc(p: ^Editor, id: string) {
	delete(p.expanded)
	p.expanded = strings.clone(id)
}

// Opens one profile's inline editor and closes any other. The table's row key is profile.ID.
editor_profile_expand :: proc(p: ^Editor, id: string) {
	if id == "" {return}
	if p.expanded != id {editor_profile_set_expanded(p, id)}
	editor_rebuild(p)
	editor_select_key(p, fmt.tprintf("profile.%s", id))
}

editor_profile_collapse :: proc(p: ^Editor) {
	if p.expanded == "" {return}
	id := strings.clone(p.expanded, context.temp_allocator)
	editor_profile_set_expanded(p, "")
	editor_rebuild(p)
	editor_select_key(p, fmt.tprintf("profile.%s", id))
}

editor_profile_toggle :: proc(p: ^Editor, id: string) {
	if p.expanded == id {editor_profile_collapse(p)} else {editor_profile_expand(p, id)}
}


// The profile table's index for a page item, counting only table rows before it.
@(private)
profile_index_at :: proc(p: ^Editor, item_index: int) -> int {
	count := 0
	for item, index in p.items {
		if index >= item_index {break}
		if item.row >= 0 && p.rows[item.row].kind == .Profile {count += 1}
	}
	return count
}

@(private)
profile_row_count :: proc(p: ^Editor) -> int {
	count := 0
	for item in p.items {
		if item.row >= 0 && p.rows[item.row].kind == .Profile {count += 1}
	}
	return count
}

// A reorderable block's first row and the inline editor rows under it, as page lines: a profile
// with its expanded editor, or a process group with its fields.
@(private)
Profile_Block :: struct {
	start, count: int,
}

// Which blocks are reordering or still settling, if any are.
@(private)
order_kind :: proc(p: ^Editor) -> (kind: Order_Kind, ok: bool) {
	switch o in p.order {
	case Order_Dragging:
		_, group := o.block.(Order_Group)
		return group ? .Process_Groups : .Profiles, true
	case Order_Settling:
		return o.kind, true
	}
	return
}

@(private)
order_processes :: proc(p: ^Editor) -> bool {
	kind, ok := order_kind(p)
	return ok && kind == .Process_Groups
}

// Whether a reorder drag of `kind` holds the pointer.
editor_order_dragging :: proc(p: ^Editor, kind: Order_Kind) -> bool {
	_, dragging := p.order.(Order_Dragging)
	current, _ := order_kind(p)
	return dragging && current == kind
}

// The insertion slot a drop would save, or -1 without a reorder drag.
editor_order_target :: proc(p: ^Editor) -> int {
	drag, dragging := p.order.(Order_Dragging)
	return dragging ? drag.target : -1
}

// The profile a reorder drag holds, or "".
editor_order_profile :: proc(p: ^Editor) -> string {
	drag, dragging := p.order.(Order_Dragging)
	if !dragging {return ""}
	profile, _ := drag.block.(Order_Profile)
	return profile.id
}

@(private)
order_block_free :: proc(block: Order_Block) {
	if profile, held := block.(Order_Profile); held {delete(profile.id)}
}

// Starts a reorder drag, taking ownership of a profile block's ID. Blocks still settling from an
// earlier drag of the same kind keep their drawn lines.
@(private)
order_begin :: proc(p: ^Editor, block: Order_Block, from: int, grab: f32) {
	grabbed: string
	kind := Order_Kind.Profiles
	switch b in block {
	case Order_Profile:
		grabbed = b.id
	case Order_Group:
		grabbed, kind = process_key(b.id), .Process_Groups
	}
	if current, ok := order_kind(p); ok && current != kind {profile_positions_clear(&p.profile_positions)}
	if drag, dragging := p.order.(Order_Dragging); dragging {order_block_free(drag.block)}
	p.order = Order_Dragging{block, from, from, grab}
	profile_positions_begin(p, grabbed)
}

// Ends a reorder drag, if one holds the pointer; its blocks settle from where they are drawn. The
// caller owns the returned block.
@(private)
order_release :: proc(p: ^Editor) -> (drag: Order_Dragging, ok: bool) {
	drag = p.order.(Order_Dragging) or_return
	kind, _ := order_kind(p)
	order_settle(p, kind)
	return drag, true
}

// Ends a drag's hold on the blocks: they settle while any have a drawn position, else the reorder
// is over. The caller has already freed or taken the grabbed block.
@(private)
order_settle :: proc(p: ^Editor, kind: Order_Kind) {
	p.order = nil
	if len(p.profile_positions) > 0 {p.order = Order_Settling{kind}}
}

// Drops a reorder drag without saving: the grabbed block eases back to its own place.
@(private)
order_cancel :: proc(p: ^Editor) {
	if drag, ok := order_release(p); ok {order_block_free(drag.block)}
}

@(private)
order_head :: proc(row: Editor_Row, processes: bool) -> bool {
	return processes ? row.process_field == .Group : row.kind == .Profile
}

// The reorderable blocks in page order. An expanded block includes its editor rows.
@(private)
profile_blocks :: proc(p: ^Editor) -> []Profile_Block {
	blocks := make([dynamic]Profile_Block, context.temp_allocator)
	processes := order_processes(p)
	for item, index in p.items {
		if item.row < 0 || !order_head(p.rows[item.row], processes) {continue}
		head := p.rows[item.row]
		end := index + 1
		for end < len(p.items) && p.items[end].row >= 0 {
			row := p.rows[p.items[end].row]
			if processes {
				if row.process != head.process || row.process_field == .Group {break}
			} else if row.kind == .Profile || row.profile != head.profile {break}
			end += 1
		}
		append(&blocks, Profile_Block{index, end - index})
	}
	return blocks[:]
}

// The identity a block's position is kept under across a settings reload.
@(private)
profile_block_id :: proc(p: ^Editor, block: Profile_Block) -> string {
	row := p.rows[p.items[block.start].row]
	return order_processes(p) ? row.key : row.profile
}

// Where block `index` belongs: its own line, or while a reorder drag is active, its line with the
// grabbed block's lines opened at the slot the pointer is nearest.
@(private)
profile_block_line :: proc(p: ^Editor, blocks: []Profile_Block, index: int) -> int {
	drag, dragging := p.order.(Order_Dragging)
	if !dragging || drag.from >= len(blocks) {return blocks[index].start}
	slot := drag.target <= drag.from ? drag.target : drag.target - 1
	line, others := blocks[0].start, 0
	for block, i in blocks {
		if i == drag.from {continue}
		if others == slot {line += blocks[drag.from].count}
		if i == index {return line}
		line += block.count
		others += 1
	}
	return line
}

@(private)
profile_positions_clear :: proc(positions: ^[dynamic]Profile_Position) {
	for entry in positions {delete(entry.id)}
	clear(positions)
}

@(private)
profile_position :: proc(p: ^Editor, id: string) -> ^Profile_Position {
	for &entry in p.profile_positions {if entry.id == id {return &entry}}
	return nil
}

// The position of the block the page line at `index` belongs to, and that block's first line.
@(private)
profile_line_entry :: proc(p: ^Editor, index: int) -> (entry: ^Profile_Position, start: int) {
	if len(p.profile_positions) == 0 || index < 0 || index >= len(p.items) || p.items[index].row < 0 {
		return nil, 0
	}
	row := p.rows[p.items[index].row]
	processes := order_processes(p)
	if processes ? row.process <= 0 : row.profile == "" {return nil, 0}
	start = index
	for start >= 0 && (p.items[start].row < 0 || !order_head(p.rows[p.items[start].row], processes)) {
		start -= 1
	}
	if start < 0 {return nil, 0}
	head := p.rows[p.items[start].row]
	if processes {
		if head.process != row.process {return nil, 0}
		return profile_position(p, head.key), start
	}
	if head.profile != row.profile {return nil, 0}
	return profile_position(p, row.profile), start
}

// How many lines from its own place the page line at `index` is drawn while rows reorder.
@(private)
editor_line_shift :: proc(p: ^Editor, index: int) -> f32 {
	entry, start := profile_line_entry(p, index)
	return entry == nil ? 0 : entry.position.value - f32(start)
}

// Whether the page line at `index` belongs to the block a reorder drag lifted, which draws on top.
@(private)
editor_line_lifted :: proc(p: ^Editor, index: int) -> bool {
	entry, _ := profile_line_entry(p, index)
	return entry != nil && entry.lifted
}

// Starts presenting every block at its drawn line, keeping blocks still settling where they are,
// and lifts the grabbed one. Call after the drag starts, which names the kind of block.
@(private)
profile_positions_begin :: proc(p: ^Editor, grabbed: string) {
	for block in profile_blocks(p) {
		id := profile_block_id(p, block)
		entry := profile_position(p, id)
		if entry == nil {
			owned, clone_error := strings.clone(id)
			if clone_error != nil {continue}
			line := f32(block.start)
			if _, append_error := append(
				&p.profile_positions,
				Profile_Position{id = owned, position = {value = line, target = line}},
			); append_error != nil {delete(owned); continue}
			entry = &p.profile_positions[len(p.profile_positions) - 1]
		}
		entry.lifted = id == grabbed
	}
}

// Moves the grabbed block with the pointer and opens its slot among the others, as the tab strip
// does. The drag's target keeps the insertion slot the drop will save.
@(private)
profile_drag_move :: proc(p: ^Editor, l: Editor_Layout, y: f32) -> bool {
	drag, dragging := &p.order.(Order_Dragging)
	if !dragging {return false}
	blocks := profile_blocks(p)
	if drag.from >= len(blocks) {return false}
	grabbed := blocks[drag.from]
	first := blocks[0].start
	last := blocks[len(blocks) - 1].start + blocks[len(blocks) - 1].count
	top := clamp(
		(y - l.list.y) / l.row_height + f32(p.scroll) - drag.grab,
		f32(first),
		f32(last - grabbed.count),
	)
	slot, others, line := 0, 0, first
	nearest := abs(top - f32(line))
	for block, i in blocks {
		if i == drag.from {continue}
		line += block.count
		others += 1
		if distance := abs(top - f32(line)); distance < nearest {slot, nearest = others, distance}
	}
	drag.target = slot <= drag.from ? slot : slot + 1
	if entry := profile_position(p, profile_block_id(p, grabbed)); entry != nil {
		motion_target(&entry.position, top, 0, .Linear, false, time.tick_now())
	}
	return true
}

// Eases reordering blocks toward their lines; returns whether the page must redraw. Positions are
// dropped, and the reorder ends, once the drag has ended and every block has settled.
editor_profiles_animate :: proc(p: ^Editor, enabled: bool, now: time.Tick) -> bool {
	if len(p.profile_positions) == 0 {return false}
	blocks := profile_blocks(p)
	_, dragging := p.order.(Order_Dragging)
	changed, moving := false, false
	for i := 0; i < len(p.profile_positions); {
		entry := &p.profile_positions[i]
		block := -1
		for b, index in blocks {
			if profile_block_id(p, b) == entry.id {block = index; break}
		}
		if block < 0 {
			delete(entry.id)
			ordered_remove(&p.profile_positions, i)
			changed = true
			continue
		}
		if !dragging || !entry.lifted {
			line := f32(profile_block_line(p, blocks, block))
			motion_target(&entry.position, line, 140 * time.Millisecond, .Decelerate, enabled, now)
		}
		changed = motion_update(&entry.position, now) || changed
		moving ||= motion_active(entry.position)
		i += 1
	}
	if !dragging && !moving {
		profile_positions_clear(&p.profile_positions)
		order_settle(p, .Profiles)
	}
	return changed
}

// The page lines to draw, in paint order. Rows that are reordering may be drawn away from their own
// lines, so every block line is considered and the lifted block paints last.
@(private)
editor_drawn_lines :: proc(p: ^Editor, l: Editor_Layout) -> []int {
	first, last := p.scroll, min(len(p.items), p.scroll + l.rows)
	if len(p.profile_positions) == 0 {
		lines := make([]int, max(0, last - first), context.temp_allocator)
		for &line, i in lines {line = first + i}
		return lines
	}
	if blocks := profile_blocks(p); len(blocks) > 0 {
		first = min(first, blocks[0].start)
		last = max(last, blocks[len(blocks) - 1].start + blocks[len(blocks) - 1].count)
	}
	lines := make([dynamic]int, 0, last - first, context.temp_allocator)
	for lifted in ([?]bool{false, true}) {
		for index in first ..< last {
			if editor_line_lifted(p, index) != lifted {continue}
			drawn := f32(index - p.scroll) + editor_line_shift(p, index)
			if drawn <= -1 || drawn >= f32(l.rows) {continue}
			append(&lines, index)
		}
	}
	return lines[:]
}

// Whether reordering rows are moving, or have settled after a drop and still need releasing.
editor_profiles_animating :: proc(p: ^Editor) -> bool {
	for entry in p.profile_positions {if motion_active(entry.position) {return true}}
	_, settling := p.order.(Order_Settling)
	return settling && len(p.profile_positions) > 0
}

@(private)
profile_menu_shown :: proc(p: ^Editor) -> bool {
	_, shown := p.mode.(Editor_Profile_Menu)
	return shown
}

// Moves the selection by `delta` lines, passing over group headers in the direction of travel.
@(private)
editor_step :: proc(p: ^Editor, delta: int) {
	if len(p.items) == 0 {return}
	direction := delta < 0 ? -1 : 1
	index := clamp(p.selected + delta, 0, len(p.items) - 1)
	for index >= 0 && index < len(p.items) && p.items[index].row < 0 {index += direction}
	if index < 0 || index >= len(p.items) {
		index = clamp(p.selected + delta, 0, len(p.items) - 1)
		for index >= 0 && index < len(p.items) && p.items[index].row < 0 {index -= direction}
	}
	if index >= 0 && index < len(p.items) {editor_select(p, index)}
}

@(private)
max_scroll :: proc(p: ^Editor) -> int {return max(0, len(p.items) - max(1, p.visible_rows))}

// Scrolls the page, or the outline under the pointer, without moving the selection.
editor_wheel :: proc(p: ^Editor, l: Editor_Layout, x, y: f32, rows: int) {
	if profile_menu_shown(p) {menu_wheel(&p.profile_menu, rows); return}
	if editor_popup(p) == .Choice && render.rect_contains(editor_popup_rect(p, l), x, y) {
		if row := editor_row(p); row != nil {choice_scroll_to(p, row, l, p.choice_list.scroll - rows)}
		return
	}
	if editor_popup(p) == .Shortcuts && render.rect_contains(editor_popup_rect(p, l), x, y) {
		if row := editor_row(p); row != nil {
			shortcut_capture_wheel(&p.capture, row.value, l.page, l.scale, rows)
		}
		return
	}
	if render.rect_contains(l.outline, x, y) {
		p.outline_scroll = clamp(
			p.outline_scroll - rows,
			0,
			max(0, len(outline_entries(p)) - outline_rows(l)),
		)
		return
	}
	p.jump_group = -1
	p.scroll = clamp(p.scroll - rows, 0, max_scroll(p))
}

// The page lines of every group header, in page order; the outline lists them.
@(private)
outline_entries :: proc(p: ^Editor) -> []int {
	entries := make([dynamic]int, context.temp_allocator)
	for item, index in p.items {if item.row < 0 {append(&entries, index)}}
	return entries[:]
}

@(private)
outline_rows :: proc(l: Editor_Layout) -> int {
	return l.outline_row_height > 0 ? int(l.outline.height / l.outline_row_height) : 0
}

// The group the page is showing: the one last chosen in the outline, otherwise the one at the top.
editor_active_group :: proc(p: ^Editor) -> int {
	if len(p.items) == 0 {return -1}
	for item in p.items {if item.row < 0 && item.group == p.jump_group {return p.jump_group}}
	return p.items[clamp(p.scroll, 0, len(p.items) - 1)].group
}

// Scrolls the chosen outline group's header to the top of the page and selects its first setting.
editor_jump :: proc(p: ^Editor, entry: int) {
	entries := outline_entries(p)
	if entry < 0 || entry >= len(entries) {return}
	header := entries[entry]
	if editor_focus(p) != .Search {stop_editing(p)}
	p.scroll = clamp(header, 0, max_scroll(p))
	editor_select(p, header + 1)
	p.scroll = clamp(header, 0, max_scroll(p))
	p.jump_group = p.items[header].group
}

@(private)
flip_toggle :: proc(p: ^Editor) -> Editor_Outcome {
	field_set(&p.value, field_string(&p.value) == "true" ? "false" : "true")
	return .Save
}

@(private)
choice_index :: proc(row: ^Editor_Row, value: string) -> int {
	for name, i in row.choices {if name == value {return i}}
	return 0
}

// What a single choice displays: its label, or the value itself.
@(private)
choice_label :: proc(row: ^Editor_Row, value: string) -> string {
	if len(row.choice_labels) == 0 {return value}
	for name, i in row.choices {if name == value && row.choice_labels[i] != "" {return row.choice_labels[i]}}
	return value
}

// What a choice's field shows: a multiple choice lists the labels of its options that are on.
@(private)
choice_text :: proc(p: ^Editor, row: ^Editor_Row, selected: bool, value: string) -> string {
	if row.multiple {return choice_set_label(row, selected ? p.choice_set : row.choice_mask)}
	return choice_label(row, value)
}

@(private)
choose :: proc(p: ^Editor, row: ^Editor_Row, index: int) -> Editor_Outcome {
	if len(row.choices) == 0 {return .None}
	next := clamp(index, 0, len(row.choices) - 1)
	if row.multiple {return choice_set_toggle(p, next)}
	editor_mode_set(p, Editor_Editing{})
	if row.choices[next] == field_string(&p.value) {return .Changed}
	field_set(&p.value, row.choices[next])
	return .Save
}

@(private)
open_choices :: proc(p: ^Editor, row: ^Editor_Row) {
	editor_mode_set(p, Editor_Choice_Popup{})
	if choice_searchable(row) {
		field_set(&p.choice_search, "")
		choice_filter(p, row)
	}
	p.choice_list.index = row.multiple ? 0 : choice_index(row, field_string(&p.value))
	p.choice_list.scroll = p.choice_list.index
	p.popup_bar_hover = false
}

@(private)
start_capture :: proc(p: ^Editor) {
	shortcut_capture_start(&p.capture)
	editor_mode_set(p, Editor_Shortcut{})
	editor_message(p, p.capture.hint, false)
}

@(private)
open_shortcuts :: proc(p: ^Editor) {
	shortcut_capture_open(&p.capture)
	editor_mode_set(p, Editor_Shortcut{})
	editor_message(p, p.capture.hint, false)
}

// What a capture outcome means for the page: a save leaves the field, Escape closes it, Tab moves to
// the Key positions switch, and a new hint shows in the header.
@(private)
shortcut_outcome :: proc(p: ^Editor, outcome: Shortcut_Capture_Outcome) -> Editor_Outcome {
	switch outcome {
	case .None:
		return .None
	case .Changed:
	case .Hinted:
		editor_message(p, p.capture.hint, p.capture.error)
	case .Save:
		editor_mode_set(p, Editor_Editing{})
		return .Save
	case .Cancel:
		stop_editing(p)
	case .Positions:
		editor_mode_set(p, Editor_Positions{})
		editor_message(p, "", false)
	}
	return .Changed
}

@(private)
text_kind :: proc(kind: Row_Kind) -> bool {
	return(
		kind == .Text ||
		kind == .Integer ||
		kind == .Number ||
		kind == .Color ||
		kind == .Optional_Color ||
		kind == .Profile_Icon \
	)
}

// Moves the focus ring across a table row's controls.
@(private)
profile_control_step :: proc(p: ^Editor, row: ^Editor_Row, step: int) {
	order: [5]Profile_Control
	order[0], order[1], order[2], order[3], order[4] = .Expand, .Radio, .Hidden, .Duplicate, .Remove
	count := .Protected in row.flags ? 4 : 5
	if p.profile_menu_parts.more.width > 0 {
		order[0] = .Expand
		count = 1
		if p.profile_menu_parts.radio.width > 0 {order[count] = .Radio; count += 1}
		if p.profile_menu_parts.toggle.width > 0 {order[count] = .Hidden; count += 1}
		order[count] = .More
		count += 1
	}
	index := 0
	for control, i in order[:count] {if control == p.profile_control {index = i}}
	p.profile_control = order[(index + step + count) % count]
}

// Runs the control under the focus ring of a profile row. Radio, Hidden, Duplicate and Remove name
// a settings write the page owner performs; Expand stays inside the editor.
@(private)
profile_activate :: proc(p: ^Editor, row: ^Editor_Row) -> Editor_Outcome {
	switch p.profile_control {
	case .Radio:
		return profile_request(p, .Default, row.profile)
	case .Hidden:
		editor_request_set(p, Profile_Hidden_Request{strings.clone(row.profile), .Hidden not_in row.flags})
		return .Profile_Action
	case .Expand:
		editor_profile_toggle(p, row.profile)
		return .Changed
	case .Duplicate:
		return profile_request(p, .Duplicate, row.profile)
	case .Remove:
		return profile_request(p, .Remove, row.profile)
	case .More:
		editor_profile_menu_open(p, row, p.profile_menu_parts)
		return .Changed
	}
	return .None
}

// Activates the selected row from the keyboard: toggles flip, lists open, fields take the keyboard.
@(private)
activate :: proc(p: ^Editor, row: ^Editor_Row) -> Editor_Outcome {
	switch row.kind {
	case .Action:
		return .Save
	case .Toggle:
		editor_mode_set(p, Editor_Editing{})
		return flip_toggle(p)
	case .Choice:
		open_choices(p, row)
	case .Shortcut:
		if row.shortcut_mode == .Alternatives {open_shortcuts(p)} else {start_capture(p)}
	case .Color, .Optional_Color:
		editor_mode_set(p, Editor_Color_Popup{})
		field_select_all(&p.value)
	case .Text, .Integer, .Number, .Profile_Icon:
		editor_mode_set(p, Editor_Editing{})
		field_select_all(&p.value)
	case .Process_Group:
	case .Profile:
		if editor_focus(p) == .Control {return profile_activate(p, row)}
		editor_profile_toggle(p, row.profile)
	case .Profile_Add:
		return .Save
	}
	return .Changed
}

@(private)
popup_key :: proc(p: ^Editor, row: ^Editor_Row, e: input.Key_Event) -> (Editor_Outcome, bool) {
	popup := editor_popup(p)
	if choice, open := p.mode.(Editor_Choice_Popup); open && choice_searchable(row) {
		if row.font_filter && e.key == .Tab {
			choice.toggle_focus = !choice.toggle_focus
			editor_mode_set(p, choice)
			return .Changed, true
		}
		if choice.toggle_focus {
			// The page owner saves the other filter; the page it publishes lists those fonts.
			if e.key == .Space || e.key == .Enter || e.key == .Numpad_Enter {return .Font_Filter, true}
			if e.key != .Escape && e.key != .Arrow_Down && e.key != .Arrow_Up {return .None, true}
			choice.toggle_focus = false
			editor_mode_set(p, choice)
		}
		#partial switch e.key {
		case .Backspace, .Delete, .Arrow_Left, .Arrow_Right, .A, .Space:
			if field_key(&p.choice_search, e) == .Edited {choice_filter(p, row)}
			return .Changed, true
		}
		if e.text != "" && e.text[0] >= ' ' && e.text[0] != 0x7f {
			if field_key(&p.choice_search, e) == .Edited {choice_filter(p, row)}
			return .Changed, true
		}
	}
	if popup == .Choice {
		count := editor_choice_count(p, row)
		if choice_list_key(&p.choice_list, e, count) {return .Changed, true}
		if e.key == .Home || e.key == .End {
			choice_list_move(&p.choice_list, e.key == .Home ? -count : count, count)
			return .Changed, true
		}
	}
	#partial switch e.key {
	case .Escape:
		editor_mode_set(p, Editor_Editing{})
		return .Changed, true
	case .Arrow_Up, .Arrow_Down, .P, .N, .Home, .End, .Page_Up, .Page_Down:
		return .None, false
	case .Enter, .Numpad_Enter, .Space:
		if popup == .Choice {return choice_choose(p, row, p.choice_list.index), true}
		if e.key == .Space {return .None, false}
		editor_mode_set(p, Editor_Editing{})
		return .Save, true
	}
	return .None, popup == .Choice
}

// Takes the raw key event: capture needs the physical key, and navigation uses the layout's key.
editor_key :: proc(p: ^Editor, raw: input.Key_Event) -> Editor_Outcome {
	if !raw.pressed {return .None}
	if profile_menu_shown(p) {
		switch menu_key(&p.profile_menu, raw) {
		case .Chosen: return editor_profile_menu_choose(p)
		// Escape closes the menu; the keyboard stays on the row's More control.
		case .Closed: editor_mode_set(p, Editor_Editing{})
		case .None, .Changed:
		}
		return .Changed
	}
	row := editor_row(p)
	if _, shortcut := p.mode.(Editor_Shortcut); shortcut && row != nil {
		outcome := shortcut_capture_key(&p.capture, &p.value, row.value, row.shortcut_mode, raw)
		return shortcut_outcome(p, outcome)
	}
	e := raw
	e.key = commands.logical_key(raw.key, raw.unshifted)
	// Escape drops a reorder drag before anything else, and the block eases back to its place.
	if _, reordering := p.order.(Order_Dragging); reordering && e.key == .Escape {
		order_cancel(p)
		return .Changed
	}
	if row != nil && row.kind == .Profile && e.key == .Context_Menu {
		editor_profile_menu_open(p, row, p.profile_menu_parts)
		return .Changed
	}
	focus := editor_focus(p)
	if focus == .Reset_All {
		if e.key == .Enter || e.key == .Numpad_Enter || e.key == .Space {return .Reset_All}
		if e.key == .Escape {editor_mode_set(p, Editor_Browsing{}); return .Changed}
		if e.key != .Tab {return .None}
	}
	if result, handled := editor_process_key(p, row, e); handled {return result}
	if editor_popup(p) != .None && row != nil {
		if outcome, handled := popup_key(p, row, e); handled {return outcome}
	}
	control := .Control in e.modifiers && .Alt not_in e.modifiers
	if .Alt in e.modifiers && (e.key == .Arrow_Up || e.key == .Arrow_Down) {
		entries := outline_entries(p)
		for header, entry in entries {
			if p.items[header].group == editor_active_group(p) {
				editor_jump(p, clamp(entry + (e.key == .Arrow_Up ? -1 : 1), 0, len(entries) - 1))
				break
			}
		}
		return .Changed
	}
	#partial switch e.key {
	case .Escape:
		// Escape leaves an expanded field first, then collapses the row from its table line.
		if row != nil &&
		   row.profile != "" &&
		   row.profile == p.expanded &&
		   (focus != .Control || row.kind == .Profile) {
			editor_profile_collapse(p)
			return .Changed
		}
		if focus != .Search {
			stop_editing(p)
			return .Changed
		}
		if len(p.filter.bytes) == 0 {return .None}
		field_set(&p.filter, "")
		editor_filter(p)
		return .Changed
	case .Tab:
		stops := 2
		if row == nil || row.kind == .Profile_Add {stops = 1}
		if row != nil && row.kind == .Shortcut {stops = 3}
		current := focus == .Reset_All ? stops : int(focus)
		next := Editor_Focus((current + (.Shift in e.modifiers ? stops : 1)) % (stops + 1))
		if int(next) == stops {editor_mode_set(p, Editor_Reset_All{}); return .Changed}
		if editor_popup(p) != .None {editor_mode_set(p, Editor_Editing{})}
		if next == .Control && row != nil {
			if row.kind == .Profile {
				editor_mode_set(p, Editor_Editing{})
				p.profile_control = .Radio
				return .Changed
			}
			return activate(p, row)
		}
		if focus == .Control {stop_editing(p)}
		editor_mode_set(p, focus_mode(next))
		return .Changed
	case .Arrow_Up:
		editor_step(p, -1); return .Changed
	case .Arrow_Down:
		editor_step(p, 1); return .Changed
	case .P, .N:
		if control {
			editor_step(p, e.key == .N ? 1 : -1)
			return .Changed
		}
	case .Page_Up:
		editor_step(p, -max(1, p.visible_rows)); return .Changed
	case .Page_Down:
		editor_step(p, max(1, p.visible_rows)); return .Changed
	case .Enter, .Numpad_Enter:
		if row == nil {return .None}
		if focus == .Positions {p.capture.physical = !p.capture.physical; return .Changed}
		if focus == .Control && text_kind(row.kind) {
			editor_mode_set(p, Editor_Editing{})
			return .Save
		}
		if row.kind == .Profile && focus == .Control {return profile_activate(p, row)}
		return activate(p, row)
	case .Space:
		if focus == .Positions {p.capture.physical = !p.capture.physical; return .Changed}
		if row == nil {return .None}
		if focus == .Control && row.kind == .Profile {
			return profile_activate(p, row)
		}
		if focus == .Control && row.kind == .Toggle {return flip_toggle(p)}
	case .Arrow_Left, .Arrow_Right:
		left := e.key == .Arrow_Left
		if row != nil && row.kind == .Profile {
			if focus == .Control {
				profile_control_step(p, row, left ? -1 : 1)
				return .Changed
			}
			if left {editor_profile_collapse(p)} else {editor_profile_expand(p, row.profile)}
			return .Changed
		}
		if focus == .Control && row != nil && row.kind == .Choice {
			return choose(p, row, choice_index(row, field_string(&p.value)) + (left ? -1 : 1))
		}
	case .D:
		if control {break}
		// Row shortcuts only run from the row's own control focus. While the search has focus,
		// the same letters belong to the filter.
		if focus == .Control && row != nil && row.kind == .Profile {
			return profile_request(p, .Default, row.profile)
		}
	case .Delete, .Backspace:
		if control {break}
		if focus == .Control && row != nil && row.kind == .Profile {
			if .Protected in row.flags {return .Changed}
			return profile_request(p, .Remove, row.profile)
		}
	case .R:
		if control {return row == nil ? .None : .Reset}
	}
	switch focus {
	case .Positions, .Reset_All:
		return .None
	case .Control:
		if row != nil && text_kind(row.kind) {
			if field_key(&p.value, e) == .Edited {sync_color(p)}
			return .Changed
		}
		editor_mode_set(p, Editor_Browsing{})
	case .Search:
	}
	if field_key(&p.filter, e) == .Edited {editor_filter(p)}
	return .Changed
}

editor_text :: proc(p: ^Editor, text: string) {
	if editor_capturing(p) {return}
	#partial switch _ in p.mode {
	case Editor_Positions, Editor_Reset_All:
		return
	}
	row := editor_row(p)
	if choice, open := p.mode.(Editor_Choice_Popup); open && choice_searchable(row) {
		if choice.toggle_focus {return}
		if field_text(&p.choice_search, text) == .Edited {choice_filter(p, row)}
		return
	}
	focus := editor_focus(p)
	if focus == .Control && row != nil && text_kind(row.kind) {
		if field_text(&p.value, text) == .Edited {sync_color(p)}
		return
	}
	if focus == .Control && row != nil && (row.kind == .Profile || row.kind == .Profile_Add) {return}
	if focus != .Search {editor_mode_set(p, Editor_Browsing{})}
	if field_text(&p.filter, text) == .Edited {
		editor_filter(p)
	}
}

// Pasted text replaces the focused field's selection up to its first line break.
editor_paste :: proc(p: ^Editor, text: string) {
	line := text
	if end := strings.index_any(text, "\r\n"); end >= 0 {line = text[:end]}
	editor_text(p, line)
}

// The selected text of the focused field, for copying.
editor_selection :: proc(p: ^Editor) -> string {
	if editor_popup(p) == .Choice && choice_searchable(editor_row(p)) {
		return field_selected_text(&p.choice_search)
	}
	switch editor_focus(p) {
	case .Search:
		return field_selected_text(&p.filter)
	case .Control:
		if !editor_capturing(p) {return field_selected_text(&p.value)}
	case .Positions, .Reset_All:
	}
	return ""
}

// Removes the selected text of the focused field after it was copied.
editor_cut :: proc(p: ^Editor) {
	if editor_selection(p) == "" {return}
	if row := editor_row(p); editor_popup(p) == .Choice && choice_searchable(row) {
		field_text(&p.choice_search, "")
		choice_filter(p, row)
		return
	}
	if editor_focus(p) == .Control {
		if row := editor_row(p); row != nil && text_kind(row.kind) {
			field_text(&p.value, "")
			sync_color(p)
		}
	} else {
		field_text(&p.filter, "")
		editor_filter(p)
	}
}

// Lays the page out inside a settings tab's card.
editor_layout :: proc(area: render.Rect, scale: f32) -> Editor_Layout {
	s := scale
	pad := 24 * s
	bottom := area.y + area.height - pad / 2
	l := Editor_Layout {
		page       = area,
		row_height = ROW_HEIGHT * s,
		scale      = s,
	}
	if area.width < OUTLINE_MIN_PAGE * s {
		width := max(0, min(960 * s, area.width - 2 * pad))
		x := area.x + max(pad, (area.width - width) / 2)
		l.filter = {x, area.y + 52 * s, width, HEIGHT_STANDARD * s}
		top := l.filter.y + l.filter.height + 12 * s
		l.rows = max(0, int((bottom - top) / l.row_height))
		l.list = {x, top, width, f32(l.rows) * l.row_height}
		return l
	}
	// The outline and list stay together as one block, centered once the list reaches its maximum width.
	gutter := 24 * s
	width := max(0, min(960 * s, area.width - 2 * pad - OUTLINE_WIDTH * s - gutter))
	outline_x := area.x + max(pad, (area.width - OUTLINE_WIDTH * s - gutter - width) / 2)
	l.filter = {outline_x, area.y + 52 * s, OUTLINE_WIDTH * s, HEIGHT_STANDARD * s}
	outline_top := l.filter.y + l.filter.height + 12 * s
	l.outline_row_height = OUTLINE_ROW_HEIGHT * s
	l.outline = {outline_x, outline_top, OUTLINE_WIDTH * s, max(0, bottom - outline_top)}
	x := outline_x + OUTLINE_WIDTH * s + gutter
	top := l.filter.y
	l.rows = max(0, int((bottom - top) / l.row_height))
	l.list = {x, top, width, f32(l.rows) * l.row_height}
	l.status_x = x
	return l
}

// The clear button inside the search field, shown while the field has text.
editor_clear_rect :: proc(p: ^Editor, l: Editor_Layout) -> render.Rect {
	if len(p.filter.bytes) == 0 {return {}}
	s := l.scale
	return {
		l.filter.x + l.filter.width - (SPACE_1 + HEIGHT_COMPACT) * s,
		l.filter.y + (l.filter.height - HEIGHT_COMPACT * s) / 2,
		HEIGHT_COMPACT * s,
		HEIGHT_COMPACT * s,
	}
}

@(private)
filter_text_rect :: proc(p: ^Editor, l: Editor_Layout) -> render.Rect {
	r := l.filter
	if clear := editor_clear_rect(p, l); clear.width > 0 {r.width = clear.x - r.x}
	return r
}

// The value field of one row. Every row kind that shows editable text shares this box.
@(private)
value_box :: proc(p: ^Editor, parts: Row_Parts, text: ^Text, scale: f32) -> Field_Box {
	return {
		field = &p.value,
		text = text,
		rect = parts.field,
		inset = CONTROL_INSET,
		caret_width = 1,
		radius = RADIUS_CONTROL,
		style = .Body,
		scale = scale,
	}
}

// The search field, narrowed to leave room for the clear button when it is shown.
@(private)
filter_box :: proc(p: ^Editor, l: Editor_Layout, text: ^Text) -> Field_Box {
	return {
		field = &p.filter,
		text = text,
		rect = filter_text_rect(p, l),
		inset = CONTROL_INSET,
		caret_width = 1,
		radius = RADIUS_CONTROL,
		style = .Body,
		scale = l.scale,
	}
}

editor_row_parts :: proc(p: ^Editor, l: Editor_Layout, index: int) -> Row_Parts {
	s := l.scale
	r := render.Rect {
		l.list.x,
		l.list.y + (f32(index - p.scroll) + editor_line_shift(p, index)) * l.row_height,
		l.list.width,
		l.row_height,
	}
	parts := Row_Parts {
		row = r,
	}
	item := p.items[index]
	cy := r.y + r.height / 2
	parts.reset = reset_slot(r, s)
	right := parts.reset.x - SPACE_3 * s
	parts.text_right = right
	if item.row < 0 {return parts}
	row := p.rows[item.row]
	if row.process_field != .None {return editor_process_field_parts(&row, parts, s)}
	field := proc(right, cy, width, s: f32) -> render.Rect {return {
			right - width * s,
			cy - HEIGHT_STANDARD / 2 * s,
			width * s,
			HEIGHT_STANDARD * s,
		}}
	switch row.kind {
	case .Action:
		parts.field = field(right, cy, 148, s)
		parts.reset = {}
	case .Toggle:
		parts.toggle = {right - SWITCH_WIDTH * s, cy - SWITCH_HEIGHT / 2 * s, SWITCH_WIDTH * s, SWITCH_HEIGHT * s}
		parts.text_right = parts.toggle.x - 48 * s
	case .Choice:
		parts.field = field(right, cy, 180, s)
	case .Integer, .Number:
		parts.field = field(right, cy, 88, s)
		parts.slider = {parts.field.x - 176 * s, cy - SLIDER_THUMB / 2 * s, 160 * s, SLIDER_THUMB * s}
		parts.text_right = parts.slider.x - SPACE_3 * s
	case .Text:
		parts.field = field(right, cy, min(360, r.width / s * 0.42), s)
	case .Profile_Icon:
		edge := r.x + r.width - SPACE_3 * s
		parts.clear = {edge - 56 * s, cy - HEIGHT_COMPACT / 2 * s, 56 * s, HEIGHT_COMPACT * s}
		parts.field = field(parts.clear.x - SPACE_2 * s, cy, min(300, r.width / s * 0.38), s)
		parts.swatch = swatch_slot(parts.field, s)
		parts.reset = {}
		parts.text_right = parts.swatch.x - SPACE_3 * s
	case .Color, .Optional_Color:
		parts.field = field(right, cy, 120, s)
		parts.swatch = swatch_slot(parts.field, s)
		parts.text_right = parts.swatch.x - SPACE_3 * s
	case .Shortcut:
		shortcut_parts(&parts, s, index == p.selected)
	case .Process_Group, .Profile, .Profile_Add:
		parts.reset = {}
	}
	if parts.field.width > 0 && parts.text_right > parts.field.x {parts.text_right = parts.field.x}
	parts.text_right -= 16 * s
	return parts
}

// Group headings sit at the control inset; their settings indent one SPACE_6 step further.
@(private)
ITEM_INSET :: CONTROL_INSET + SPACE_6

// Baselines for a title over a detail line, centred together in `row` with 2 DIPs between the
// line boxes.
stacked_baselines :: proc(row: render.Rect, first, second: ^Text, scale: f32) -> (f32, f32) {
	gap := 2 * scale
	top := row.y + (row.height - first.line_height - gap - second.line_height) / 2
	return top + first.ascent, top + first.line_height + gap + second.ascent
}

// The reset button at a row's right edge, shared by Settings and the palette.
reset_slot :: proc(row: render.Rect, s: f32) -> render.Rect {
	size := HEIGHT_COMPACT * s
	return {row.x + row.width - SPACE_2 * s - size, row.y + (row.height - size) / 2, size, size}
}

// A colour swatch the height of a standard field, SPACE_2 before it.
@(private)
swatch_slot :: proc(field: render.Rect, s: f32) -> render.Rect {
	size := HEIGHT_STANDARD * s
	return {field.x - SPACE_2 * s - size, field.y + (field.height - size) / 2, size, size}
}

// The table cells of the item at `index`. The editor's row rect is the only shared part.
editor_profile_parts :: proc(p: ^Editor, l: Editor_Layout, index: int) -> Profile_Parts {
	if index < 0 || index >= len(p.items) || p.items[index].row < 0 {return {}}
	row := &p.rows[p.items[index].row]
	return profile_row_parts(row.kind, editor_row_parts(p, l, index).row, l.scale)
}

@(private)
choice_popup_rows :: proc(p: ^Editor, row: ^Editor_Row, l: Editor_Layout) -> int {
	header := choice_search_height(row, l.scale)
	return min(editor_choice_count(p, row), CHOICE_LIST_ROWS,
	           max(1, int((l.page.height - 24 * l.scale - header) / (CHOICE_HEIGHT * l.scale))))
}

// Scrolls the choice list, keeping the highlighted option on a visible row.
@(private)
choice_scroll_to :: proc(p: ^Editor, row: ^Editor_Row, l: Editor_Layout, offset: int) {
	visible := choice_popup_rows(p, row, l)
	_ = choice_list_scroll_to(&p.choice_list, offset, editor_choice_count(p, row), visible)
}

@(private)
choice_scrollbar :: proc(p: ^Editor, l: Editor_Layout) -> (bar: Scrollbar, visible: bool) {
	row := editor_row(p)
	if editor_popup(p) != .Choice || row == nil {return}
	r := editor_popup_rect(p, l)
	if r.width == 0 {return}
	s := l.scale
	header := choice_search_height(row, s)
	area := render.Rect{r.x, r.y + header + 4 * s, r.width - s, r.height - header - 8 * s}
	extent := Scroll_Extent{editor_choice_count(p, row), choice_popup_rows(p, row, l), p.choice_list.scroll}
	return scrollbar_layout(area, extent, scrollbar_state(p.popup_bar_hover, choice_bar_drag(p)), s)
}

// The choice list's scrollbar thumb drag; inactive unless the pointer holds it.
@(private)
choice_bar_drag :: proc(p: ^Editor) -> Scroll_Drag {
	choice, _ := p.mode.(Editor_Choice_Popup)
	bar, _ := choice.drag.(Scroll_Drag)
	return bar
}

@(private)
choice_option_right :: proc(p: ^Editor, l: Editor_Layout, popup: render.Rect) -> f32 {
	if bar, visible := choice_scrollbar(p, l); visible {return bar.track.x}
	return popup.x + popup.width - 4 * l.scale
}

editor_popup_rect :: proc(p: ^Editor, l: Editor_Layout) -> render.Rect {
	row := editor_row(p)
	popup := editor_popup(p)
	if popup == .None || row == nil || p.selected < p.scroll || p.selected >= p.scroll + l.rows {
		return {}
	}
	parts := editor_row_parts(p, l, p.selected)
	s := l.scale
	if popup == .Shortcuts {return shortcut_capture_popup_rect(&p.capture, parts, l.page, row.value, s)}
	if popup == .Choice {
		count := choice_popup_rows(p, row, l)
		shown := &p.choice_list
		shown.scroll = clamp(shown.scroll, max(0, shown.index - max(1, count) + 1), shown.index)
		shown.scroll = min(shown.scroll, max(0, editor_choice_count(p, row) - count))
		width := max(parts.field.width, row.choice_min_width * s)
		r := render.Rect {
			parts.field.x,
			parts.field.y + parts.field.height + 4 * s,
			width,
			f32(max(1, count)) * CHOICE_HEIGHT * s + 8 * s + choice_search_height(row, s),
		}
		return dropdown_place(r, parts.row, l.page, s)
	}
	r := render.Rect {
		parts.field.x + parts.field.width - 292 * s,
		parts.field.y + parts.field.height + 6 * s,
		292 * s,
		(row.kind == .Optional_Color ? 206 : 166) * s,
	}
	if r.y + r.height > l.page.y + l.page.height - 8 * s {r.y = parts.row.y - r.height - 4 * s}
	return r
}

@(private)
Color_Parts :: struct {
	wheel, ramp, swatch, no_color: render.Rect,
}

@(private)
color_parts :: proc(popup: render.Rect, optional: bool, scale: f32) -> Color_Parts {
	s := scale
	c := Color_Parts {
		wheel = {popup.x + 12 * s, popup.y + 12 * s, 140 * s, 140 * s},
	}
	c.ramp = {popup.x + 168 * s, popup.y + 24 * s, 112 * s, 16 * s}
	c.swatch = {popup.x + 168 * s, popup.y + 60 * s, 112 * s, 40 * s}
	if optional {c.no_color = {popup.x + 12 * s, popup.y + 166 * s, 140 * s, 28 * s}}
	return c
}

@(private)
pick_color :: proc(p: ^Editor, c: Color_Parts, drag: Color_Drag, x, y: f32) {
	if drag == .Wheel {
		radius := c.wheel.width / 2
		dx, dy := x - (c.wheel.x + radius), y - (c.wheel.y + radius)
		hue := math.to_degrees(math.atan2(dy, dx))
		if hue < 0 {hue += 360}
		p.hsv[0], p.hsv[1] = hue, min(1, math.sqrt(dx * dx + dy * dy) / max(1, radius))
	} else {
		p.hsv[2] = clamp((x - c.ramp.x) / max(1, c.ramp.width), 0, 1)
	}
	// The picker chooses hue, saturation and value; a translucent color keeps its typed alpha.
	picked := colour.hsv_to_rgb(p.hsv[0], p.hsv[1], p.hsv[2])
	previous, _ := colour.parse_translucent(field_string(&p.value), .Permissive)
	buffer: [colour.HEX_ALPHA_LENGTH]u8
	text := colour.format_translucent({picked.r, picked.g, picked.b, previous.a}, buffer[:])
	if previous.a == 0 {text = colour.format(picked, buffer[:])}
	field_set(&p.value, text)
}

@(private)
slide :: proc(p: ^Editor, row: ^Editor_Row, slider: render.Rect, x: f32) {
	number := slider_value(row.minimum, row.maximum, (x - slider.x) / max(1, slider.width))
	field_set(&p.value, number_text(row_step(row), number))
}

// A press inside the page; `extend` (Shift) grows a text selection instead of moving the caret.
editor_press :: proc(
	p: ^Editor,
	l: Editor_Layout,
	text: ^Text,
	x, y: f32,
	extend: bool,
) -> Editor_Outcome {
	s := l.scale
	p.profile_menu.bounds = l.page
	if profile_menu_shown(p) {
		hit := menu_hit(&p.profile_menu, x, y, l.page.x + l.page.width, l.page.y + l.page.height, s)
		if hit >= 0 {
			menu_select(&p.profile_menu, hit)
			return editor_profile_menu_choose(p)
		}
		editor_mode_set(p, Editor_Editing{})
		return .Changed
	}
	popup := editor_popup(p)
	if popup == .None && render.rect_contains(editor_reset_all_rect(l), x, y) {return .Reset_All}
	if popup != .None {
		r := editor_popup_rect(p, l)
		row := editor_row(p)
		if !render.rect_contains(r, x, y) || row == nil {
			if popup == .Shortcuts {editor_message(p, "", false)}
			editor_mode_set(p, Editor_Editing{})
			return .Changed
		}
		if choice, open := p.mode.(Editor_Choice_Popup); open {
			if render.rect_contains(choice_font_toggle_rect(p, l), x, y) {
				choice.toggle_focus = true
				editor_mode_set(p, choice)
				return .Font_Filter
			}
			if choice_searchable(row) && y < r.y + 4 * s + choice_search_height(row, s) {
				box := choice_search_box(p, l, text)
				if text != nil {
					field_pointer(&p.choice_search, field_box_offset(box, x), true, extend)
				} else {field_select_all(&p.choice_search)}
				editor_mode_set(p, Editor_Choice_Popup{drag = Choice_Search_Drag{}})
				return .Changed
			}
			if bar, visible := choice_scrollbar(p, l); visible && scrollbar_contains(bar, x, y) {
				held: Scroll_Drag
				choice_scroll_to(p, row, l, scrollbar_press(&held, bar, y))
				if held.active {
					choice.drag = held
					editor_mode_set(p, choice)
				}
				return .Changed
			}
			r.y += choice_search_height(row, s)
			index := int((y - r.y - 4 * s) / (CHOICE_HEIGHT * s))
			if y < r.y + 4 * s || index >= choice_popup_rows(p, row, l) {return .None}
			return choice_choose(p, row, index + p.choice_list.scroll)
		}
		if popup == .Shortcuts {
			return shortcut_outcome(p, shortcut_capture_press(&p.capture, &p.value, row.value, r, x, y, s))
		}
		c := color_parts(r, row.kind == .Optional_Color, s)
		drag: Color_Drag
		switch {
		case render.rect_contains(c.wheel, x, y):
			drag = .Wheel
		case render.rect_contains({c.ramp.x, c.ramp.y - 6 * s, c.ramp.width, c.ramp.height + 12 * s}, x, y):
			drag = .Ramp
		case render.rect_contains(c.no_color, x, y):
			field_set(&p.value, "")
			editor_mode_set(p, Editor_Editing{})
			return .Save
		case:
			return .None
		}
		editor_mode_set(p, Editor_Color_Popup{drag})
		pick_color(p, c, drag, x, y)
		return .Changed
	}
	if render.rect_contains(editor_clear_rect(p, l), x, y) {
		if editor_focus(p) != .Search {stop_editing(p)}
		field_set(&p.filter, "")
		editor_filter(p)
		return .Changed
	}
	if render.rect_contains(l.filter, x, y) {
		if editor_focus(p) != .Search {stop_editing(p)}
		field_pointer(&p.filter, field_box_offset(filter_box(p, l, text), x), true, extend)
		editor_mode_set(p, Editor_Browsing{selecting = true})
		return .Changed
	}
	if render.rect_contains(l.outline, x, y) {
		entry := p.outline_scroll + int((y - l.outline.y) / l.outline_row_height)
		if entry >= len(outline_entries(p)) {return .None}
		editor_jump(p, entry)
		return .Changed
	}
	if !render.rect_contains(l.list, x, y) {return .None}
	index := p.scroll + int((y - l.list.y) / l.row_height)
	if index >= len(p.items) || p.items[index].row < 0 {return .None}
	if index != p.selected {editor_select(p, index)}
	row := editor_row(p)
	parts := editor_row_parts(p, l, index)
	if row.process_field != .None {
		if result, handled := editor_process_press(p, row, parts, x, y, s); handled {return result}
	}
	if row.kind == .Profile || row.kind == .Profile_Add {
		table := profile_row_parts(row.kind, parts.row, s)
		switch {
		case row.kind == .Profile && render.rect_contains(table.more, x, y):
			editor_profile_menu_open(p, row, table)
			return .Changed
		case row.kind == .Profile && render.rect_contains(table.handle, x, y):
			if filtering(p) {return .Changed}
			grab := (y - parts.row.y) / l.row_height
			order_begin(p, Order_Profile{strings.clone(row.profile)}, profile_index_at(p, index), grab)
			return .Changed
		case row.kind == .Profile && render.rect_contains(table.radio, x, y):
			editor_mode_set(p, Editor_Editing{})
			p.profile_control = .Radio
			return profile_request(p, .Default, row.profile)
		case row.kind == .Profile && render.rect_contains(table.toggle, x, y):
			editor_mode_set(p, Editor_Editing{})
			p.profile_control = .Hidden
			editor_request_set(p, Profile_Hidden_Request{strings.clone(row.profile), .Hidden not_in row.flags})
			return .Profile_Action
		case row.kind == .Profile && render.rect_contains(table.expand, x, y):
			editor_mode_set(p, Editor_Editing{})
			p.profile_control = .Expand
			editor_profile_toggle(p, row.profile)
			return .Changed
		case row.kind == .Profile && render.rect_contains(table.duplicate, x, y):
			editor_mode_set(p, Editor_Editing{})
			p.profile_control = .Duplicate
			return profile_request(p, .Duplicate, row.profile)
		case row.kind == .Profile &&
		     .Protected not_in row.flags &&
		     render.rect_contains(table.remove, x, y):
			editor_mode_set(p, Editor_Editing{})
			p.profile_control = .Remove
			return profile_request(p, .Remove, row.profile)
		case row.kind == .Profile_Add:
			return .Save
		case row.kind == .Profile:
			if .Protected in row.flags &&
			   render.rect_contains(table.remove, x, y) {
				return .Changed
			}
			editor_profile_toggle(p, row.profile)
			return .Changed
		}
		return .Changed
	}
	switch {
	case render.rect_contains(parts.reset, x, y):
		return .Reset
	case render.rect_contains(parts.clear, x, y):
		field_set(&p.value, "")
		return .Save
	case render.rect_contains(parts.toggle, x, y):
		editor_mode_set(p, Editor_Editing{})
		return flip_toggle(p)
	case render.rect_contains(parts.positions, x, y):
		p.capture.physical = !p.capture.physical
		return .Changed
	case render.rect_contains(parts.swatch, x, y) && row.kind != .Profile_Icon:
		editor_mode_set(p, Editor_Color_Popup{})
		return .Changed
	case render.rect_contains(parts.slider, x, y) ||
	     render.rect_contains(
		     {
			     parts.slider.x - 8 * s,
			     parts.slider.y - 10 * s,
			     parts.slider.width + 16 * s,
			     parts.slider.height + 20 * s,
		     },
		     x,
		     y,
	     ) &&
		     parts.slider.width > 0:
		editor_mode_set(p, Editor_Editing{drag = .Slider})
		slide(p, row, parts.slider, x)
		return .Changed
	case render.rect_contains(parts.field, x, y):
		#partial switch row.kind {
		case .Choice:
			open_choices(p, row)
			return .Changed
		case .Shortcut:
			return activate(p, row)
		case .Action:
			return .Save
		}
		if editor_capturing(p) {stop_editing(p)}
		field_pointer(&p.value, field_box_offset(value_box(p, parts, text, s), x), true, extend)
		editor_mode_set(p, Editor_Editing{drag = .Value})
		return .Changed
	}
	if editor_capturing(p) {stop_editing(p)}
	return .Changed
}

// Continues a pointer drag; returns whether anything changed.
editor_drag :: proc(p: ^Editor, l: Editor_Layout, text: ^Text, x, y: f32) -> bool {
	if browsing, ok := p.mode.(Editor_Browsing); ok && browsing.selecting {
		return field_pointer(&p.filter, field_box_offset(filter_box(p, l, text), x), false, true) != .None
	}
	row := editor_row(p)
	if row == nil {return false}
	if drag, reordering := &p.order.(Order_Dragging); reordering {
		moved := profile_drag_move(p, l, y)
		// A drop outside the page keeps the saved order; the group eases back to its place.
		if _, group := drag.block.(Order_Group); group && !render.rect_contains(l.list, x, y) {
			drag.target = drag.from
		}
		return moved
	}
	switch m in p.mode {
	case Editor_Editing:
		switch m.drag {
		case .None:
			return false
		case .Value:
			parts := editor_row_parts(p, l, p.selected)
			box := value_box(p, parts, text, l.scale)
			return field_pointer(&p.value, field_box_offset(box, x), false, true) != .None
		case .Slider:
			slide(p, row, editor_row_parts(p, l, p.selected).slider, x)
			return true
		}
	case Editor_Choice_Popup:
		switch drag in m.drag {
		case Choice_Search_Drag:
			box := choice_search_box(p, l, text)
			return field_pointer(&p.choice_search, field_box_offset(box, x), false, true) != .None
		case Scroll_Drag:
			bar, visible := choice_scrollbar(p, l)
			if !visible {return false}
			before := p.choice_list.scroll
			choice_scroll_to(p, row, l, scrollbar_drag(drag, bar, y))
			return p.choice_list.scroll != before
		}
	case Editor_Color_Popup:
		if m.drag == .None {return false}
		pick_color(p, color_parts(editor_popup_rect(p, l), row.kind == .Optional_Color, l.scale), m.drag, x, y)
		return true
	case Editor_Browsing, Editor_Positions, Editor_Reset_All, Editor_Shortcut, Editor_Profile_Menu:
	}
	return false
}

// Ends a pointer drag; a slider or colour drag saves the value it settled on. Dropping a profile
// row names its ID and insertion slot.
editor_release :: proc(p: ^Editor) -> Editor_Outcome {
	field_release(&p.filter)
	field_release(&p.value)
	field_release(&p.choice_search)
	if _, reordering := p.order.(Order_Dragging); reordering {return order_drop(p)}
	settled := false
	switch m in p.mode {
	case Editor_Browsing:
		if m.selecting {editor_mode_set(p, Editor_Browsing{})}
	case Editor_Editing:
		settled = m.drag == .Slider
		if m.drag != .None {editor_mode_set(p, Editor_Editing{})}
	case Editor_Choice_Popup:
		if m.drag == nil {break}
		editor_mode_set(p, Editor_Choice_Popup{toggle_focus = m.toggle_focus})
		if _, bar := m.drag.(Scroll_Drag); bar {return .Changed}
	case Editor_Color_Popup:
		settled = m.drag != .None
		if settled {editor_mode_set(p, Editor_Color_Popup{})}
	case Editor_Positions, Editor_Reset_All, Editor_Shortcut, Editor_Profile_Menu:
	}
	row := editor_row(p)
	if row == nil || !settled {return .None}
	return field_string(&p.value) == row.value ? .Changed : .Save
}

// Ends whatever the pointer holds without a result, for a gesture the system took away. A reorder
// drag saves nothing; its block eases back.
editor_pointer_cancel :: proc(p: ^Editor) {
	order_cancel(p)
	_ = editor_release(p)
}

// Drops a reorder drag at its target slot. A profile names its new place in a request; a process
// group moves within the page's draft.
@(private)
order_drop :: proc(p: ^Editor) -> Editor_Outcome {
	drag, dropped := order_release(p)
	if !dropped {return .None}
	switch block in drag.block {
	case Order_Group:
		slot := drag.target
		if slot > drag.from {slot -= 1}
		if slot == drag.from {return .Changed}
		editor_process_move(p, block.id, slot)
		return .Process_Save
	case Order_Profile:
		if drag.target == drag.from {
			delete(block.id)
			return .Changed
		}
		editor_request_set(p, Profile_Order_Request{block.id, drag.target})
		return .Profile_Action
	}
	return .None
}

// Hover state for row highlights and reset buttons; returns whether the page must redraw.
editor_hover :: proc(p: ^Editor, l: Editor_Layout, x, y: f32) -> bool {
	if profile_menu_shown(p) {
		hit := menu_hit(&p.profile_menu, x, y, l.page.x + l.page.width, l.page.y + l.page.height, l.scale)
		if hit < 0 || hit == menu_selected(&p.profile_menu) {return false}
		menu_select(&p.profile_menu, hit)
		return true
	}
	// An open dropdown highlights the option under the pointer, like the menus.
	bar_changed := false
	popup_open := editor_popup(p)
	if popup_open != .None {
		bar, bar_visible := choice_scrollbar(p, l)
		over := bar_visible && scrollbar_contains(bar, x, y)
		bar_changed = over != p.popup_bar_hover
		p.popup_bar_hover = over
		row := editor_row(p)
		if row != nil && popup_open == .Shortcuts &&
		   shortcut_capture_hover(&p.capture, editor_popup_rect(p, l), l.page, row.value, x, y, l.scale) {
			return true
		}
		if row != nil && popup_open == .Choice {
			popup := editor_popup_rect(p, l)
			right := choice_option_right(p, l, popup)
			top := popup.y + choice_search_height(row, l.scale) + 4 * l.scale
			if render.rect_contains(popup, x, y) && x >= popup.x + 4 * l.scale && x < right {
				index := choice_list_at(p.choice_list, top, CHOICE_HEIGHT * l.scale, y,
				                        editor_choice_count(p, row), choice_popup_rows(p, row, l))
				if index >= 0 && index != p.choice_list.index {
					p.choice_list.index = index
					return true
				}
			}
		}
	}
	item, reset, outline := -1, -1, -1
	profile_item, profile_control := -1, Profile_Control.Radio
	if popup_open == .None && !editor_order_dragging(p, .Profiles) && render.rect_contains(l.list, x, y) {
		index := p.scroll + int((y - l.list.y) / l.row_height)
		if index < len(p.items) && p.items[index].row >= 0 {
			item = index
			parts := editor_row_parts(p, l, index)
			if render.rect_contains(parts.reset, x, y) {reset = index}
			row := &p.rows[p.items[index].row]
			if row.kind == .Profile {
				table := profile_row_parts(row.kind, parts.row, l.scale)
				profile_item = index
				switch {
				case render.rect_contains(table.more, x, y):
					profile_control = .More
				case render.rect_contains(table.radio, x, y):
					profile_control = .Radio
				case render.rect_contains(table.toggle, x, y):
					profile_control = .Hidden
				case render.rect_contains(table.expand, x, y):
					profile_control = .Expand
				case render.rect_contains(table.duplicate, x, y):
					profile_control = .Duplicate
				case .Protected not_in row.flags &&
				     render.rect_contains(table.remove, x, y):
					profile_control = .Remove
				case:
					profile_item = -1
				}
			}
		}
	}
	if popup_open == .None && render.rect_contains(l.outline, x, y) {
		entry := p.outline_scroll + int((y - l.outline.y) / l.outline_row_height)
		if entry < len(outline_entries(p)) {outline = entry}
	}
	clear := render.rect_contains(editor_clear_rect(p, l), x, y)
	if item == p.hover_item &&
	   reset == p.hover_reset &&
	   outline == p.hover_outline &&
	   clear == p.hover_clear &&
	   profile_item == p.hover_profile_item &&
	   profile_control == p.hover_profile_control {
		return bar_changed
	}
	p.hover_item, p.hover_reset, p.hover_outline, p.hover_clear = item, reset, outline, clear
	p.hover_profile_item, p.hover_profile_control = profile_item, profile_control
	return true
}

// Drops every hover; reports whether one was shown.
editor_hover_clear :: proc(p: ^Editor) -> (changed: bool) {
	changed =
		p.hover_item >= 0 || p.hover_reset >= 0 || p.hover_outline >= 0 || p.hover_clear ||
		p.hover_profile_item >= 0 || p.popup_bar_hover
	p.hover_item, p.hover_reset, p.hover_outline, p.hover_clear = -1, -1, -1, false
	p.popup_bar_hover = false
	p.hover_profile_item, p.hover_profile_control = -1, .Radio
	return
}

// Whether the pointer is over editable text, which shows a text cursor.
editor_over_text :: proc(p: ^Editor, l: Editor_Layout, x, y: f32) -> bool {
	if profile_menu_shown(p) {return false}
	if render.rect_contains(editor_popup_rect(p, l), x, y) {return false}
	if render.rect_contains(filter_text_rect(p, l), x, y) {return true}
	if !render.rect_contains(l.list, x, y) {return false}
	index := p.scroll + int((y - l.list.y) / l.row_height)
	if index >= len(p.items) || p.items[index].row < 0 {return false}
	kind := p.rows[p.items[index].row].kind
	return text_kind(kind) && render.rect_contains(editor_row_parts(p, l, index).field, x, y)
}

// The pointer for the page: text over editable text, a hand over anything a click changes.
editor_pointer :: proc(p: ^Editor, l: Editor_Layout, x, y: f32) -> platform.Cursor_Shape {
	if profile_menu_shown(p) {return .Hand}
	s := l.scale
	if popup := editor_popup_rect(p, l); render.rect_contains(popup, x, y) {
		row := editor_row(p)
		if row == nil {return .Arrow}
		if editor_popup(p) == .Choice {
			if bar, visible := choice_scrollbar(p, l); visible && scrollbar_contains(bar, x, y) {return .Arrow}
			if render.rect_contains(choice_font_toggle_rect(p, l), x, y) {return .Hand}
			if choice_searchable(row) && y < popup.y + 4 * s + choice_search_height(row, s) {return .Text}
			popup.y += choice_search_height(row, s)
		}
		option := int((y - popup.y - 4 * s) / (CHOICE_HEIGHT * s))
		#partial switch editor_popup(p) {
		case .Choice:
			if option >= 0 && option + p.choice_list.scroll < editor_choice_count(p, row) {return .Hand}
		case .Shortcuts:
			count := len(commands.shortcut_alternatives(row.value, context.temp_allocator))
			if option >= 0 && option + p.capture.alternatives.scroll <= count {return .Hand}
		case .Color:
			c := color_parts(popup, row.kind == .Optional_Color, s)
			ramp := render.Rect{c.ramp.x, c.ramp.y - 6 * s, c.ramp.width, c.ramp.height + 12 * s}
			if render.rect_contains(c.wheel, x, y) ||
			   render.rect_contains(ramp, x, y) ||
			   render.rect_contains(c.no_color, x, y) {
				return .Hand
			}
		}
		return .Arrow
	}
	if render.rect_contains(editor_reset_all_rect(l), x, y) {return .Hand}
	if render.rect_contains(editor_clear_rect(p, l), x, y) {return .Hand}
	if render.rect_contains(filter_text_rect(p, l), x, y) {return .Text}
	if render.rect_contains(l.outline, x, y) {
		entry := p.outline_scroll + int((y - l.outline.y) / l.outline_row_height)
		return entry < len(outline_entries(p)) ? .Hand : .Arrow
	}
	if !render.rect_contains(l.list, x, y) {return .Arrow}
	index := p.scroll + int((y - l.list.y) / l.row_height)
	if index >= len(p.items) || p.items[index].row < 0 {return .Arrow}
	row := &p.rows[p.items[index].row]
	parts := editor_row_parts(p, l, index)
	if row.process_field == .Group {
		cells := editor_process_parts(parts.row, s)
		if render.rect_contains(cells.handle, x, y) {return editor_process_orderable(p) ? .Resize_All : .Arrow}
		return .Hand
	}
	#partial switch row.kind {
	case .Profile, .Profile_Add:
		return .Hand
	}
	slider := render.Rect {
		parts.slider.x - 8 * s,
		parts.slider.y - 10 * s,
		parts.slider.width + 16 * s,
		parts.slider.height + 20 * s,
	}
	switch {
	case render.rect_contains(parts.reset, x, y),
	     render.rect_contains(parts.clear, x, y),
	     render.rect_contains(parts.toggle, x, y),
	     render.rect_contains(parts.positions, x, y),
	     render.rect_contains(parts.swatch, x, y) && row.kind != .Profile_Icon,
	     parts.slider.width > 0 && render.rect_contains(slider, x, y):
		return .Hand
	case render.rect_contains(parts.field, x, y):
		#partial switch row.kind {
		case .Choice, .Shortcut, .Action:
			return .Hand
		}
		return .Text
	}
	return .Arrow
}

@(private)
row_preview :: proc(row: ^Editor_Row, value: string) -> string {
	#partial switch row.kind {
	case .Optional_Color:
		if value == "" {return "None"}
	}
	return value
}

@(private)
switch_draw :: proc(
	list: ^render.Draw_List,
	track: render.Rect,
	on, focused: bool,
	theme: Theme,
	scale: f32,
) {
	draw_rect(
		list,
		{rect = track, color = on ? theme.accent : theme.border, radius = track.height / 2},
	)
	knob := track.height - 6 * scale
	knob_x := on ? track.x + track.width - 3 * scale - knob : track.x + 3 * scale
	draw_rect(
		list,
		{
			rect = {knob_x, track.y + 3 * scale, knob, knob},
			color = on ? theme.accent_text : theme.text,
			radius = knob / 2,
		},
	)
	if focused {focus_ring_draw(list, track, theme, scale)}
}

@(private)
box_draw :: proc(
	list: ^render.Draw_List,
	r: render.Rect,
	theme: Theme,
	focused: bool,
	scale: f32,
) {
	draw_rect(list, {rect = r, color = theme.border, radius = RADIUS_CONTROL * scale})
	if focused {focus_ring_draw(list, r, theme, scale)}
}

// The square text badge a pane header and the profile table use for a shell.
@(private)
profile_badge_draw :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	badge: string,
	rect: render.Rect,
	theme: Theme,
	scale: f32,
	muted: bool,
) {
	if rect.width <= 0 {return}
	draw_rect(list, {rect = rect, color = theme.surface, radius = RADIUS_CONTROL * scale})
	draw_rect(list, {rect = rect, color = theme.border, radius = RADIUS_CONTROL * scale, stroke = scale})
	small := text_styled(text, .Detail)
	width := min(rect.width - 4 * scale, text_width(&small, badge))
	draw_text(
		&small,
		list,
		badge,
		rect.x + (rect.width - width) / 2,
		rect.y + (rect.height - small.line_height) / 2 + small.ascent,
		muted ? theme.muted : theme.text,
		width,
	)
}

// A 22px radio dot with a pointer and keyboard focus state.
@(private)
profile_radio_draw :: proc(
	list: ^render.Draw_List,
	rect: render.Rect,
	on, focused, hovered: bool,
	theme: Theme,
	scale: f32,
) {
	if rect.width <= 0 {return}
	if hovered {
		hover := render.Rect {
			rect.x - 4 * scale,
			rect.y - 4 * scale,
			rect.width + 8 * scale,
			rect.height + 8 * scale,
		}
		draw_rect(list, {rect = hover, color = theme.hover, radius = hover.width / 2})
	}
	dot := render.Rect {
		rect.x + rect.width / 2 - 8 * scale,
		rect.y + rect.height / 2 - 8 * scale,
		16 * scale,
		16 * scale,
	}
	draw_rect(list, {rect = dot, color = on ? theme.accent : theme.border, radius = pill_radius(dot)})
	draw_rect(list, {rect = dot, color = theme.border, radius = pill_radius(dot), stroke = scale})
	if on {
		inner := render.Rect{dot.x + 4 * scale, dot.y + 4 * scale, 8 * scale, 8 * scale}
		draw_rect(list, {rect = inner, color = theme.accent_text, radius = pill_radius(inner)})
	}
	if focused {focus_ring_draw(list, dot, theme, scale)}
}

// A small icon button inside a table row.
@(private)
profile_button_draw :: proc(
	list: ^render.Draw_List,
	rect: render.Rect,
	icon: Icon,
	size: f32,
	theme: Theme,
	scale: f32,
	focused, hovered, enabled: bool,
) {
	if rect.width <= 0 {return}
	if enabled && (hovered || focused) {
		draw_rect(
			list,
			{rect = rect, color = hovered ? theme.hover : theme.selection, radius = RADIUS_CONTROL * scale},
		)
	}
	color := enabled ? theme.muted : theme.faint
	if hovered || focused {color = theme.text}
	if focused {focus_ring_draw(list, rect, theme, scale)}
	icon_draw(list, icon, rect, color, size, scale)
}

@(private)
profile_row_draw :: proc(
	p: ^Editor,
	row: ^Editor_Row,
	parts: Row_Parts,
	index: int,
	selected: bool,
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	scale: f32,
) -> render.Build_Status {
	table := profile_row_parts(.Profile, parts.row, scale)
	if selected {p.profile_menu_parts = table}
	small := text_styled(text, .Detail)
	cy := parts.row.y + parts.row.height / 2
	focused := selected && editor_editing(p)
	hovered := index == p.hover_profile_item
	strong := (selected || index == p.hover_item) && !(.Hidden in row.flags)
	grip_ink := selected || index == p.hover_item ? theme.muted : theme.faint
	icon_draw(list, .Grip, table.handle, grip_ink, ICON_BUTTON, scale)
	badge_size := HEIGHT_COMPACT * scale
	badge := render.Rect {table.icon.x, cy - badge_size / 2, badge_size, badge_size}
	if table.icon.width > 0 {
		profile_badge_draw(list, text, row.badge, badge, theme, scale, .Hidden in row.flags)
	}
	name_color := strong ? theme.text : theme.muted
	if .Hidden in row.flags {name_color = theme.muted}
	name_baseline, note_baseline := stacked_baselines(parts.row, text, &small, scale)
	auto_detected := .Builtin in row.flags
	if row.note == "" && !auto_detected {name_baseline = cy - text.line_height / 2 + text.ascent}
	if result := draw_text(
		text,
		list,
		row.title,
		table.name.x,
		name_baseline,
		name_color,
		max(1, table.name.width),
	); result != .Ok {return result}
	if row.note != "" || auto_detected {
		note := row.note != "" ? row.note : "Auto-detected"
		if result := draw_text(
			&small,
			list,
			note,
			table.name.x,
			note_baseline,
			row.note != "" ? theme.error : theme.muted,
			max(1, table.name.width),
		); result != .Ok {return result}
	}
	if result := draw_fading_text(
		&small,
		list,
		row.description,
		table.command.x,
		cy - small.line_height / 2 + small.ascent,
		theme.muted,
		max(1, table.command.width),
	); result != .Ok {return result}
	if table.directory.width > 0 {
		if result := draw_fading_text(
			&small,
			list,
			row.value,
			table.directory.x,
			cy - small.line_height / 2 + small.ascent,
			theme.faint,
			max(1, table.directory.width),
		); result != .Ok {return result}
	}
	radio_focus := focused && p.profile_control == .Radio
	if table.radio.width > 0 {profile_radio_draw(
		list,
		table.radio,
		.Default in row.flags,
		radio_focus,
		hovered && p.hover_profile_control == .Radio,
		theme,
		scale,
	)}
	profile_button_draw(
		list,
		table.toggle,
		.Hidden in row.flags ? .Eye_Off : .Eye,
		ICON_BUTTON,
		theme,
		scale,
		focused && p.profile_control == .Hidden,
		hovered && p.hover_profile_control == .Hidden,
		true,
	)
	if table.expand.width > 0 {
		controls := [?]struct {
			rect: render.Rect,
			icon: Icon,
			size: f32,
			kind: Profile_Control,
		} {
			{table.expand, p.expanded == row.profile ? .Chevron_Down : .Chevron_Right, ICON_INDICATOR, .Expand},
			{table.duplicate, .Copy, ICON_BUTTON, .Duplicate},
			{table.remove, .Trash, ICON_BUTTON, .Remove},
			{table.more, .More_Vertical, ICON_BUTTON, .More},
		}
		for control in controls {
			if control.rect.width <= 0 {continue}
			if control.kind == .Remove && .Protected in row.flags {continue}
			profile_button_draw(
				list,
				control.rect,
				control.icon,
				control.size,
				theme,
				scale,
				focused && p.profile_control == control.kind,
				hovered && p.hover_profile_control == control.kind,
				true,
			)
		}
	}
	if p.error_profile != "" && p.error_profile == row.profile {
		draw_rect(list, {rect = parts.row, color = theme.error, radius = RADIUS_CONTROL * scale, stroke = scale})
	}
	return .Ok
}

@(private)
profile_add_draw :: proc(
	row: ^Editor_Row,
	row_rect: render.Rect,
	selected: bool,
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	scale: f32,
) -> render.Build_Status {
	label := text^
	icon := render.Rect {
		row_rect.x + SPACE_3 * scale,
		row_rect.y + (row_rect.height - ICON_BUTTON * scale) / 2,
		ICON_BUTTON * scale,
		ICON_BUTTON * scale,
	}
	icon_draw(list, .Add, icon, theme.muted, ICON_INDICATOR, scale)
	color := selected ? theme.text : theme.muted
	return draw_text(
		&label,
		list,
		row.title,
		icon.x + icon.width + 8 * scale,
		row_rect.y + (row_rect.height - label.line_height) / 2 + label.ascent,
		color,
		max(1, row_rect.width - 60 * scale),
	)
}

// Draws a control's resting value, or for the selected row its pending value and focus.
@(private)
control_draw :: proc(
	p: ^Editor,
	row: ^Editor_Row,
	parts: Row_Parts,
	selected: bool,
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	page: render.Rect,
	scale: f32,
) -> render.Build_Status {
	value := selected ? field_string(&p.value) : row.value
	focused := selected && editor_editing(p)
	input_text := text_styled(text, .Body)
	baseline :=
		parts.field.y + (parts.field.height - input_text.line_height) / 2 + input_text.ascent
	switch row.kind {
	case .Action:
		return text_button_draw(list, text, theme, parts.field, value, focused, scale, {})
	case .Toggle:
		on := value == "true"
		if row.profile != "" {
			profile_button_draw(list, parts.toggle, on ? .Eye : .Eye_Off, ICON_BUTTON,
			                    theme, scale, focused, false, true)
			return .Ok
		}
		switch_draw(list, parts.toggle, on, focused, theme, scale)
		label := on ? "On" : "Off"
		return draw_text(
			text,
			list,
			label,
			parts.toggle.x - 12 * scale - text_width(text, label),
			parts.toggle.y + (parts.toggle.height - text.line_height) / 2 + text.ascent,
			theme.muted,
		)
	case .Choice:
		box_draw(list, parts.field, theme, focused, scale)
		if r := draw_text(
			&input_text,
			list,
			choice_text(p, row, selected, value),
			parts.field.x + CONTROL_INSET * scale,
			baseline,
			theme.text,
			max(1, parts.field.width - (2 * CONTROL_INSET + ICON_INDICATOR + SPACE_1) * scale),
		); r != .Ok {return r}
		chevron := render.Rect {
			parts.field.x + parts.field.width - (CONTROL_INSET + ICON_INDICATOR) * scale,
			parts.field.y,
			ICON_INDICATOR * scale,
			parts.field.height,
		}
		icon_draw(list, .Chevron_Down, chevron, theme.muted, ICON_INDICATOR, scale)
		return .Ok
	case .Integer, .Number:
		number, ok := strconv.parse_f64(value)
		if !ok {number, _ = strconv.parse_f64(row.value)}
		slider_draw(list, parts.slider, slider_fraction(row.minimum, row.maximum, number), theme, scale)
	case .Color, .Optional_Color:
		if c, ok := swatch_color(value); ok {
			draw_rect(list, {rect = parts.swatch, color = c, radius = RADIUS_CONTROL * scale})
		}
		draw_rect(
			list,
			{rect = parts.swatch, color = theme.border, radius = RADIUS_CONTROL * scale, stroke = scale},
		)
		if selected && editor_popup(p) == .Color {focus_ring_draw(list, parts.swatch, theme, scale)}
	case .Shortcut:
		return shortcut_field_draw(list, text, theme, parts, shortcut_summary(value), {
			capturing = selected && editor_capturing(p), focused = focused,
			positions_focused = selected && editor_focus(p) == .Positions, physical = p.capture.physical,
			empty_label = row.shortcut_mode == .Alternatives ? "Add shortcut" : "None",
		}, page, scale)
	case .Text:
	case .Profile_Icon:
		profile_badge_draw(list, text, row.badge, parts.swatch, theme, scale, false)
	case .Process_Group, .Profile, .Profile_Add:
		return .Ok
	}
	if selected {
		placeholder := row.kind == .Optional_Color ? "None" : "Empty"
		box := value_box(p, parts, text, scale)
		box_draw(list, parts.field, theme, focused, scale)
		if r := field_box_draw(box, list, theme, field_box_baseline(box), focused, placeholder);
		   r != .Ok {
			return r
		}
		return .Ok
	}
	box_draw(list, parts.field, theme, false, scale)
	shown := row_preview(row, value)
	color := row.value == "" ? theme.muted : theme.text
	return draw_text(
		&input_text,
		list,
		shown,
		parts.field.x + CONTROL_INSET * scale,
		baseline,
		color,
		max(1, parts.field.width - 2 * CONTROL_INSET * scale),
	)
}

@(private)
popup_draw :: proc(
	p: ^Editor,
	l: Editor_Layout,
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	pointer: [2]f32 = {},
) -> render.Build_Status {
	r := editor_popup_rect(p, l)
	row := editor_row(p)
	if r.width == 0 || row == nil {return .Ok}
	s := l.scale
	if editor_popup(p) == .Shortcuts {
		return shortcut_capture_popup_draw(&p.capture, list, text, theme, r, l.page, row.value, pointer, s)
	}
	if render.push_layer(list, l.page) != .None {return .Ok}
	frame := popover_panel(r, s)
	if panel_draw(list, frame, theme) != .None {return .Ok}
	if editor_popup(p) == .Choice {
		count := choice_popup_rows(p, row, l)
		if choice_searchable(row) {
			box := choice_search_box(p, l, text)
			toggle_focus := editor_choice_toggle_focused(p)
			box_draw(list, box.rect, theme, !toggle_focus, s)
			if result := field_box_draw(box, list, theme, field_box_baseline(box),
			                           !toggle_focus, "Search fonts");
			   result != .Ok {return result}
			if render.push_layer(list, l.page) != .None {return .Ok}
			if row.font_filter {
				toggle := choice_font_toggle_rect(p, l)
				switch_w, switch_h := SWITCH_WIDTH * s, SWITCH_HEIGHT * s
				switch_rect := render.Rect {
					toggle.x + toggle.width - CONTROL_INSET * s - switch_w,
					toggle.y + (toggle.height - switch_h) / 2,
					switch_w,
					switch_h,
				}
				switch_draw(list, switch_rect, row.show_all_fonts, toggle_focus, theme, s)
				if result := draw_text(text, list, "Show all fonts", toggle.x + CONTROL_INSET * s,
				                       toggle.y + (toggle.height - text.line_height) / 2 + text.ascent,
				                       theme.text, switch_rect.x - toggle.x - 2 * CONTROL_INSET * s);
				   result != .Ok {return result}
			}
			r.y += choice_search_height(row, s)
			r.height -= choice_search_height(row, s)
			if count == 0 {
				return draw_text(text, list, "No fonts found", r.x + SPACE_3 * s,
				                 r.y + (r.height - text.line_height) / 2 + text.ascent,
				                 theme.muted, r.width - 28 * s)
			}
		}
		right := choice_option_right(p, l, r)
		for visible in 0 ..< count {
			i := p.choice_list.scroll + visible
			name := row.choices[choice_source_index(p, row, i)]
			option := render.Rect {
				r.x + 4 * s,
				r.y + 4 * s + f32(visible) * CHOICE_HEIGHT * s,
				right - r.x - 4 * s,
				CHOICE_HEIGHT * s,
			}
			if i == p.choice_list.index {
				draw_rect(list, {rect = option, color = theme.selection, radius = RADIUS_CONTROL * s})
			}
			if render.rect_contains(option, pointer.x, pointer.y) {
				// Options carry the selection tint, not the paper fill, so no hairline.
				if result := hover_rim_draw(list, theme, option, RADIUS_CONTROL * s, 1, s, pointer, false);
				   result != .None {return .Ok}
			}
			if row.multiple {
				if choice_set_has(p.choice_set, choice_source_index(p, row, i)) {
					check := render.Rect{option.x + option.width - 28 * s, option.y, 24 * s, option.height}
					icon_draw(list, .Check, check, theme.accent, ICON_INDICATOR, s)
				}
			} else if name == field_string(&p.value) {
				mark := render.Rect{option.x, option.y + 8 * s, 3 * s, option.height - 16 * s}
				draw_rect(list, {rect = mark, color = theme.accent, radius = pill_radius(mark)})
			}
			if result := draw_text(
				text,
				list,
				row.multiple ? row.choice_labels[i] : choice_label(row, name),
				option.x + 12 * s,
				option.y + (option.height - text.line_height) / 2 + text.ascent,
				theme.text,
				option.width - (row.multiple ? 44 : 24) * s,
			); result != .Ok {return result}
		}
		if bar, visible := choice_scrollbar(p, l); visible {
			scrollbar_draw(list, theme, bar, scrollbar_state(p.popup_bar_hover, choice_bar_drag(p)))
		}
		return .Ok
	}
	c := color_parts(r, row.kind == .Optional_Color, s)
	wheel := c.wheel
	draw_rect(
		list,
		{
			rect = wheel,
			color = {p.hsv[2], 0, 0, 1},
			radius = wheel.width / 2,
			fill = render.RECT_FILL_HUE_WHEEL,
		},
	)
	draw_rect(list, {rect = wheel, color = theme.border, radius = wheel.width / 2, stroke = s})
	angle := math.to_radians(p.hsv[0])
	reach := wheel.width / 2 * p.hsv[1]
	mx := wheel.x + wheel.width / 2 + math.cos(angle) * reach
	my := wheel.y + wheel.height / 2 + math.sin(angle) * reach
	draw_rect(
		list,
		{
			rect = {mx - 7 * s, my - 7 * s, 14 * s, 14 * s},
			color = {0, 0, 0, 0.6},
			radius = pill_radius({0, 0, 14 * s, 14 * s}),
			stroke = s,
		},
	)
	draw_rect(
		list,
		{
			rect = {mx - 6 * s, my - 6 * s, 12 * s, 12 * s},
			color = {1, 1, 1, 1},
			radius = RADIUS_CONTROL * s,
			stroke = 2 * s,
		},
	)
	full := colour.rgba(colour.hsv_to_rgb(p.hsv[0], p.hsv[1], 1))
	draw_rect(
		list,
		{rect = c.ramp, color = full, radius = RADIUS_CONTROL * s, fill = render.RECT_FILL_VALUE_RAMP},
	)
	draw_rect(list, {rect = c.ramp, color = theme.border, radius = RADIUS_CONTROL * s, stroke = s})
	marker := c.ramp.x + c.ramp.width * p.hsv[2]
	draw_rect(
		list,
		{
			rect = {marker - 3 * s, c.ramp.y - 3 * s, 6 * s, c.ramp.height + 6 * s},
			color = {1, 1, 1, 1},
			radius = pill_radius({0, 0, 6 * s, c.ramp.height + 6 * s}),
			stroke = 2 * s,
		},
	)
	if color, ok := swatch_color(field_string(&p.value)); ok {
		draw_rect(list, {rect = c.swatch, color = color, radius = RADIUS_CONTROL * s})
	}
	draw_rect(list, {rect = c.swatch, color = theme.border, radius = RADIUS_CONTROL * s, stroke = s})
	small := text_styled(text, .Detail)
	if result := draw_text(
		&small,
		list,
		"Enter saves, Esc closes",
		c.swatch.x,
		c.swatch.y + c.swatch.height + 22 * s,
		theme.muted,
		c.swatch.width,
	); result != .Ok {return result}
	if c.no_color.width == 0 {return .Ok}
	box_draw(list, c.no_color, theme, false, s)
	return draw_text(
		text,
		list,
		"No color",
		c.no_color.x + CONTROL_INSET * s,
		c.no_color.y + (c.no_color.height - text.line_height) / 2 + text.ascent,
		theme.text,
		c.no_color.width - 2 * CONTROL_INSET * s,
	)
}

@(private)
filter_draw :: proc(
	p: ^Editor,
	l: Editor_Layout,
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	focused: bool,
	pointer: [2]f32 = {},
) -> render.Build_Status {
	s := l.scale
	box := filter_box(p, l, text)
	box_draw(list, l.filter, theme, focused, s)
	placeholder :=
		l.outline.width > 0 ? "Search settings" : "Search settings, groups, and shortcuts"
	if result := field_box_draw(box, list, theme, field_box_baseline(box), focused, placeholder);
	   result != .Ok {
		return result
	}
	clear := editor_clear_rect(p, l)
	if clear.width == 0 {return .Ok}
	if render.push_layer(list, l.page) != .None {return .Ok}
	if p.hover_clear {
		draw_rect(list, {rect = clear, color = theme.hover, radius = RADIUS_CONTROL * s})
		if result := hover_rim_draw(list, theme, clear, RADIUS_CONTROL * s, 1, s, pointer);
		   result != .None {return .Ok}
	}
	icon_draw(list, .Close, clear, p.hover_clear ? theme.text : theme.muted, ICON_INDICATOR, s)
	return .Ok
}

@(private)
outline_draw :: proc(
	p: ^Editor,
	l: Editor_Layout,
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	pointer: [2]f32 = {},
) -> render.Build_Status {
	if l.outline.width == 0 {return .Ok}
	s := l.scale
	entries := outline_entries(p)
	rows := outline_rows(l)
	active := editor_active_group(p)
	if active != p.outline_active {
		for header, entry in entries {
			if p.items[header].group != active {continue}
			if entry < p.outline_scroll {p.outline_scroll = entry}
			if entry >= p.outline_scroll + rows {p.outline_scroll = entry - rows + 1}
		}
		p.outline_active = active
	}
	p.outline_scroll = clamp(p.outline_scroll, 0, max(0, len(entries) - rows))
	if render.push_layer(list, l.outline) != .None {return .Ok}
	small := text_styled(text, .Detail)
	for entry in p.outline_scroll ..< min(len(entries), p.outline_scroll + rows) {
		item := p.items[entries[entry]]
		r := render.Rect {
			l.outline.x,
			l.outline.y + f32(entry - p.outline_scroll) * l.outline_row_height,
			l.outline.width,
			l.outline_row_height,
		}
		baseline := r.y + (r.height - text.line_height) / 2 + text.ascent
		label := fmt.tprintf("%d", item.count)
		label_width := text_width(&small, label)
		if result := navigation_row_draw(list, text, theme, r,
			{title = p.groups[item.group].title, selected = item.group == active,
			 hovered = entry == p.hover_outline, trailing = label_width + CONTROL_INSET * s}, s, pointer);
		   result != .Ok {return result}
		if result := draw_text(
			&small,
			list,
			label,
			r.x + r.width - CONTROL_INSET * s - label_width,
			baseline,
			theme.faint,
		); result != .Ok {return result}
	}
	return .Ok
}

editor_draw :: proc(
	p: ^Editor,
	l: Editor_Layout,
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	focused: bool,
	pointer: [2]f32 = {},
) -> render.Build_Status {
	s := l.scale
	p.visible_rows = l.rows
	p.profile_menu.bounds = l.page
	p.scroll = clamp(p.scroll, 0, max_scroll(p))
	if render.push_layer(list, l.page) != .None {return .Ok}
	strong := text_styled(text, .Strong)
	small := text_styled(text, .Detail)
	heading := text_styled(text, .Display)
	x := l.filter.x
	// The summary shares the title's baseline.
	header_baseline := l.page.y + HEADER_CENTER * s - heading.line_height / 2 + heading.ascent
	if r := draw_text(&heading, list, "Settings", x, header_baseline, theme.text); r != .Ok {return r}
	status := p.message
	matches := 0
	for item in p.items {matches += item.count}
	if status == "" {
		status = fmt.tprintf(
			"%d settings and shortcuts · Alt+↑/↓ groups · Esc clears search",
			matches,
		)
	}
	status_x := x + text_width(&heading, "Settings") + 16 * s
	status_right := l.filter.x + l.filter.width
	if l.outline.width > 0 {status_x, status_right = l.status_x, l.list.x + l.list.width}
	status_right = min(status_right, editor_reset_all_rect(l).x - 12 * s)
	if r := draw_text(
		&small,
		list,
		status,
		status_x,
		header_baseline,
		p.error ? theme.error : theme.muted,
		max(1, status_right - status_x),
	); r != .Ok {return r}
	reset := editor_reset_all_rect(l)
	reset_focused := focused && editor_focus(p) == .Reset_All
	if r := text_button_draw(list, text, theme, reset, "Reset to Defaults", reset_focused, s, pointer);
	   r != .Ok {return r}
	if r := filter_draw(p, l, list, text, theme, focused && editor_focus(p) == .Search, pointer);
	   r != .Ok {return r}
	if r := outline_draw(p, l, list, text, theme, pointer); r != .Ok {return r}
	if len(p.items) == 0 && filtering(p) {
		if render.push_layer(list, l.page) != .None {return .Ok}
		return draw_text(
			text,
			list,
			"No matching settings or shortcuts",
			l.list.x + ITEM_INSET * s,
			l.list.y + (l.row_height - text.line_height) / 2 + text.ascent,
			theme.muted,
		)
	}
	if render.push_layer(list, l.list) != .None {return .Ok}
	for index in editor_drawn_lines(p, l) {
		item := p.items[index]
		parts := editor_row_parts(p, l, index)
		r := parts.row
		selected := index == p.selected
		if selected {
			draw_rect(list, {rect = r, color = theme.selection, radius = RADIUS_CONTROL * s})
			if p.error && item.row >= 0 && p.rows[item.row].kind == .Shortcut {
				draw_rect(list, {rect = r, color = theme.error, radius = RADIUS_CONTROL * s, stroke = 2 * s})
			}
		} else if index == p.hover_item {
			draw_rect(list, {rect = r, color = theme.hover, radius = RADIUS_CONTROL * s})
		}
		if index == p.hover_item {
			// A row is a reading surface: it takes the pointer light but never the lift. A
			// selected row keeps its tint and any error ring, so it takes no hairline.
			if result := hover_rim_draw(list, theme, r, RADIUS_CONTROL * s, 1, s, pointer, !selected);
			   result != .None {return .Ok}
		}
		if item.row < 0 {
			baseline := r.y + r.height - SPACE_3 * s
			inset := CONTROL_INSET * s
			if index > 0 {
				draw_rect(list, {rect = {r.x + inset, r.y + SPACE_2 * s, r.width - 2 * inset, s}, color = theme.border})
			}
			if result := draw_text(
				&strong,
				list,
				p.groups[item.group].title,
				r.x + inset,
				baseline,
				theme.text,
				max(1, r.width * 0.7),
			); result != .Ok {return result}
			label := fmt.tprintf("%d", item.count)
			if result := draw_text(
				&small,
				list,
				label,
				r.x + r.width - inset - text_width(&small, label),
				baseline,
				theme.faint,
			); result != .Ok {return result}
			continue
		}
		row := &p.rows[item.row]
		if row.process_field != .None {
			if result := editor_process_draw(p, row, parts, selected, list, text, theme, s);
			   result != .Ok {return result}
			// A selected text field leaves its own clip pushed; later rows draw in the list again.
			if render.push_layer(list, l.list) != .None {return .Ok}
			continue
		}
		if row.kind == .Profile {
			if result := profile_row_draw(p, row, parts, index, selected, list, text, theme, s);
			   result != .Ok {
				return result
			}
			continue
		}
		if row.kind == .Profile_Add {
			if result := profile_add_draw(row, r, selected, list, text, theme, s);
			   result != .Ok {
				return result
			}
			continue
		}
		if row.profile != "" {
			// Expanded editors carry an accent rail so they read as part of the row above.
			rail := render.Rect{r.x + 2 * s, r.y + SPACE_2 * s, 3 * s, r.height - 2 * SPACE_2 * s}
			draw_rect(list, {rect = rail, color = theme.accent, radius = pill_radius(rail)})
		}
		text_width_limit := max(1, parts.text_right - r.x - ITEM_INSET * s)
		baseline, detail_baseline := stacked_baselines(r, text, &small, s)
		if row.description == "" {baseline = r.y + (r.height - text.line_height) / 2 + text.ascent}
		if result := draw_text(
			text,
			list,
			row.title,
			r.x + ITEM_INSET * s,
			baseline,
			theme.text,
			text_width_limit,
		); result != .Ok {return result}
		note := row.note
		note_error := note != ""
		if p.error_key == row.key && p.error_text != "" {
			note, note_error = p.error_text, true
		}
		if note_error {
			if result := draw_text(
				&small,
				list,
				note,
				r.x + ITEM_INSET * s,
				detail_baseline,
				theme.error,
				text_width_limit,
			); result != .Ok {return result}
		} else if result := draw_text(
			&small,
			list,
			row.description,
			r.x + ITEM_INSET * s,
			detail_baseline,
			theme.muted,
			text_width_limit,
		); result != .Ok {return result}
		if result := control_draw(p, row, parts, selected, list, text, theme, l.list, s);
		   result != .Ok {
			return result
		}
		if row.kind == .Profile_Icon {
			if render.push_layer(list, l.list) != .None {return .Ok}
			box_draw(list, parts.clear, theme, false, s)
			label := "Clear"
			if result := draw_text(
				text,
				list,
				label,
				parts.clear.x + (parts.clear.width - text_width(text, label)) / 2,
				parts.clear.y + (parts.clear.height - text.line_height) / 2 + text.ascent,
				theme.muted,
			); result != .Ok {return result}
		}
		if p.error_key == row.key {
			draw_rect(list, {rect = r, color = theme.error, radius = RADIUS_CONTROL * s, stroke = s})
		}
		if render.push_layer(list, l.list) != .None {return .Ok}
		if row.kind == .Action {continue}
		modified := row.value != row.default_value
		if reset_button_draw(list, theme, parts.reset, modified, index == p.hover_reset, selected, pointer, s) !=
		   .None {return .Ok}
	}
	if profile_menu_shown(p) {
		return menu_draw(&p.profile_menu, list, text, theme,
		                 l.page.x + l.page.width, l.page.y + l.page.height, s, pointer)
	}
	return popup_draw(p, l, list, text, theme, pointer)
}
