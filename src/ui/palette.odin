package ui

import "aio:commands"
import "aio:fuzzy"
import "aio:input"
import "aio:platform"
import "aio:render"
import "base:runtime"
import "core:fmt"
import "core:log"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"

@(private) PALETTE_MAX_ROWS :: 8
@(private) PALETTE_WIDTH :: 560
@(private) PALETTE_MODE_HEIGHT :: HEIGHT_TOOLBAR + SPACE_4
@(private) PALETTE_INPUT_HEIGHT :: 64
@(private) PALETTE_ROW_HEIGHT :: 40
@(private) PALETTE_FOOTER_HEIGHT :: 32
@(private) PALETTE_PADDING :: 8
@(private) PALETTE_TEXT_INSET :: DIALOG_PADDING
@(private) PALETTE_SETTING_SUFFIX :: " SETTING"
@(private) PALETTE_KEYCAP_HEIGHT :: 20
// A leading icon and the gap after it.
@(private) PALETTE_GLYPH_WIDTH :: ICON_BUTTON + SPACE_2
@(private) PALETTE_NO_RANK :: 99
// Shortcut matches rank after label matches (exact, prefix, substring) and before a label's scattered
// letters: an exact chord, then a partial one, then letters through a shortcut's parts ("al8"); other
// fields follow.
@(private) PALETTE_RANK_CHORD :: 3
@(private) PALETTE_RANK_PARTIAL :: 4
@(private) PALETTE_RANK_LABEL :: 5
@(private) PALETTE_RANK_FUZZY :: 6
@(private) PALETTE_RANK_FIELDS :: 7

// What activating a result does.
Outcome :: enum {
	None,
	Changed,
	Closed,
	Run,
	Open_Setting,
	// A setting control chose a new value; the owner takes it with palette_chosen_take. The palette stays open.
	Set_Setting,
	Open_Tab,
	Open_Workspace,
}

// The kind a result belongs to. A row names it only when another result shares its title. Unassigned
// is the one row offering a chord the search named that no command uses.
Palette_Kind :: enum {
	Command,
	Setting,
	Tab,
	Workspace,
	Unassigned,
}

Palette_Mode :: enum {
	All,
	Tabs,
	Workspaces,
	Settings,
	Commands,
}

// `word` labels the mode's tab and `name` reports it; `prefix` typed first selects the mode.
Palette_Mode_Info :: struct {
	word, name, prefix, placeholder: string,
	icon:                            Icon,
}

@(private) PALETTE_MODES := [Palette_Mode]Palette_Mode_Info {
	.All         = {"All", "all", "", "Search anything", .Grid},
	.Tabs        = {"Tabs", "tabs", "t:", "Search tabs", .Layout_Top},
	.Workspaces  = {"Workspaces", "workspaces", "w:", "Search workspaces", .Workspace},
	.Settings    = {"Settings", "settings", "s:", "Search settings", .Settings},
	.Commands    = {"Commands", "commands", "c:", "Search commands", .Command},
}

@(private) PALETTE_CYCLE := [?]Palette_Mode {
	.All,
	.Tabs,
	.Workspaces,
	.Settings,
	.Commands,
}

@(private) PALETTE_MODE_WIDTHS := [Palette_Mode]f32 {
	.All = 72,
	.Tabs = 80,
	.Workspaces = 128,
	.Settings = 104,
	.Commands = 120,
}

// The order of an empty query's list and of equal-ranked matches: the original domains first.
@(private) PALETTE_DOMAIN_ORDER := [?]Palette_Kind{.Command, .Setting, .Tab, .Workspace}

@(private) PALETTE_KIND_WORDS := [Palette_Kind]string {
	.Command = "Command",
	.Setting = "Setting",
	.Tab = "Tab",
	.Workspace = "Workspace",
	.Unassigned = "Shortcut",
}

// The mode listing only one kind; its icon marks that kind's rows. Identity never relies on colour:
// every row carries this shape, and a type word on a title clash.
@(private) PALETTE_KIND_MODES := [Palette_Kind]Palette_Mode {
	.Command = .Commands,
	.Setting = .Settings,
	.Tab = .Tabs,
	.Workspace = .Workspaces,
	.Unassigned = .Commands,
}

// One footer entry: its keycaps, joined by a slash, and what they do.
Palette_Key_Hint :: struct {
	keys:  [2]string,
	label: string,
}

// At most navigate, three selection actions, keyboard search, and close.
@(private) PALETTE_HINT_CAP :: 6

// The palette's chords beyond list_key_step, each beside the keycap the footer shows for it. palette_key
// and edit_key match these, so changing a chord changes its hint. Enter and Numpad Enter both accept.
// The operate modifier with Enter edits a command's shortcut or operates a setting's control.
@(private) PALETTE_OPERATE :: input.Modifier.Control
@(private) PALETTE_OPERATE_LABEL :: "Ctrl+Enter"
// The adjust modifier with Left or Right steps the selected setting.
@(private) PALETTE_ADJUST :: input.Modifier.Alt
@(private) PALETTE_ADJUST_LABEL :: "Alt+←/→"
@(private) PALETTE_ACCEPT_LABEL :: "Enter"
@(private) PALETTE_CANCEL_KEY :: input.Key.Escape
@(private) PALETTE_CANCEL_LABEL :: "Esc"

// A setting the palette can open in the settings editor, and the control it offers in place.
// The strings are static schema text. A choice without `choices` asks Palette_Values for a live list.
Palette_Setting :: struct {
	key, title, group:      string,
	control:                Palette_Control,
	minimum, maximum, step: f64,
	choices, choice_labels: []string,
	// The choice list has a filter field, as the Settings page gives font pickers.
	searchable:             bool,
	// A reset button restores `default_value`, as on the Settings page.
	resettable:             bool,
	default_value:          string,
}

// One searchable tab or workspace. The strings are borrowed from its live record, so an opened
// palette reflects title changes; they are never stored past the frame that reads them.
Palette_Item :: struct {
	label, detail, owner: string,
	id:                     u64,
}

// A caller-owned list of tabs or workspaces. The palette reads it on every query so titles stay
// live and it never takes ownership of session data.
Palette_Source :: struct {
	user:  rawptr,
	count: proc(user: rawptr) -> int,
	item:  proc(user: rawptr, index: int) -> Palette_Item,
}

// Asks the caller, on every query, whether a command can run now; the palette leaves out one that
// cannot. Without a callback every command that is not hidden is listed.
Palette_Availability :: struct {
	user:      rawptr,
	available: proc(user: rawptr, id: commands.Command_Id) -> bool,
}

// A command result, a setting result, a tab/workspace result, or the Unassigned row for `chord`.
// `shortcut` is the command alternative a search matched.
Palette_Result :: struct {
	kind:        Palette_Kind,
	command:     ^commands.Command,
	setting:     int,
	source:      int,
	id:          u64,
	rank:        int,
	score:       f64,
	positions:   []int,
	title_match: bool,
	shortcut:    Shortcut_Highlight,
	chord:       commands.Shortcut,
}

// The identity activation needs, independent of the current result ordering.
Palette_Target :: struct {
	kind:    Palette_Kind,
	id:      u64,
	command: commands.Command_Id,
	setting: string,
}

Palette :: struct {
	using presence: Presence,
	query:          Text_Field,
	selected, scroll: int,
	visible_rows:   int,
	// The last explicit fit supplies geometry to keyboard-operated popups, before any draw.
	fit_page:       render.Rect,
	fit_scale:      f32,
	results:        [dynamic]Palette_Result,
	// Matches gathered per domain before sections are ordered into `results`.
	ordered:        [dynamic]Palette_Result,
	positions:      [dynamic]int,
	haystack:       [dynamic]u8,
	settings:       []Palette_Setting,
	tabs:           Palette_Source,
	workspaces:     Palette_Source,
	mode:           Palette_Mode,
	mode_hover:     int,
	chosen:       Palette_Chosen,
	// Storage for Chosen_Value's strings, reused from one choice to the next.
	chosen_key, chosen_value: [dynamic]u8,
	scratch:      ^fuzzy.Scratch,
	values:       Palette_Values,
	edit:         Palette_Edit,
	buffers:      Edit_Buffers,
	drag:         Palette_Drag,
	leader:       Maybe(commands.Shortcut),
	availability: Palette_Availability,
	reset_hover:  int,
	scroll_hover: bool,
	// The query's record mode, and the pointer over its keyboard button.
	keys:         Key_Search,
	keys_hover:   bool,
	// The chord the Unassigned row offered: the next command chosen opens its shortcut editor with it.
	assign:       Maybe(commands.Shortcut),
}

// What the last outcome names for the owner: the setting to reveal (Open_Setting), the value to save
// (Set_Setting), or the tab or workspace to show (Open_Tab, Open_Workspace). Set only with that
// outcome, by palette_choose; the owner takes it with palette_chosen_take as it handles the outcome,
// and opening or closing the palette drops one nobody took.
Palette_Chosen :: union {
	Chosen_Setting,
	Chosen_Value,
	Chosen_Tab,
	Chosen_Workspace,
}

Chosen_Setting :: struct {
	key: string,
}

// The strings stay valid until the palette's next choice.
Chosen_Value :: struct {
	key, value: string,
}

Chosen_Tab :: struct {
	id: u64,
}

Chosen_Workspace :: struct {
	id: u64,
}

Palette_Layout :: struct {
	panel, mode_bar, input, list, footer:     render.Rect,
	modes:                                  [Palette_Mode]render.Rect,
	viewport:                               render.Rect,
	// The keyboard button at the right of the query.
	keys:                                   render.Rect,
	row_height, scale:                      f32,
	rows:                                   int,
	bar:                                    Scrollbar,
	bar_visible:                            bool,
}

@(require_results)
palette_init :: proc(
	p: ^Palette,
	settings: []Palette_Setting,
	allocator := context.allocator,
) -> runtime.Allocator_Error {
	p.query.bytes = make([dynamic]u8, allocator)
	p.results = make([dynamic]Palette_Result, allocator)
	p.ordered = make([dynamic]Palette_Result, allocator)
	p.positions = make([dynamic]int, allocator)
	p.chosen_value = make([dynamic]u8, allocator)
	p.chosen_key = make([dynamic]u8, allocator)
	edit_init(&p.buffers, allocator)
	p.settings = settings
	p.visible_rows = PALETTE_MAX_ROWS
	p.fit_scale = 1
	p.mode_hover = -1
	p.reset_hover = -1
	err: runtime.Allocator_Error
	capacity := 0
	for s in settings {
		capacity = max(capacity, len(s.group) + len(PALETTE_SETTING_SUFFIX) + 2 + len(s.title))
	}
	p.haystack, err = make([dynamic]u8, 0, capacity, allocator)
	if err != nil { return err }
	p.scratch, err = new(fuzzy.Scratch, allocator)
	return err
}

palette_destroy :: proc(p: ^Palette) {
	edit_set(p, nil)
	delete(p.chosen_key)
	free(p.scratch, p.query.bytes.allocator)
	delete(p.query.bytes)
	delete(p.results)
	delete(p.ordered)
	delete(p.positions)
	delete(p.haystack)
	delete(p.chosen_value)
	edit_destroy(&p.buffers)
	p^ = {}
}

// The app supplies its live tab and workspace lists once; the callbacks read current records.
palette_set_sources :: proc(p: ^Palette, tabs, workspaces: Palette_Source) {
	p.tabs, p.workspaces = tabs, workspaces
}

palette_set_availability :: proc(p: ^Palette, availability: Palette_Availability) {
	p.availability = availability
}

palette_open :: proc(p: ^Palette, registry: ^commands.Registry) {
	palette_open_mode(p, registry, .All)
}

palette_open_mode :: proc(p: ^Palette, registry: ^commands.Registry, mode: Palette_Mode) {
	presence_open(&p.presence, DIALOG_PRESENCE)
	field_set(&p.query, "")
	p.selected, p.scroll = 0, 0
	p.mode = mode
	p.mode_hover = -1
	p.reset_hover = -1
	p.scroll_hover = false
	p.keys, p.keys_hover, p.assign = {}, false, nil
	drag_set(p, nil)
	palette_choose(p, nil)
	refresh(p, registry)
}

palette_close :: proc(p: ^Palette) {
	edit_set(p, nil)
	presence_close(&p.presence)

	p.mode_hover = -1
	p.scroll_hover = false
	p.keys, p.keys_hover, p.assign = {}, false, nil
	drag_set(p, nil)
	palette_choose(p, nil)
}

// The only writer of p.chosen besides palette_chosen_take.
@(private)
palette_choose :: proc(p: ^Palette, chosen: Palette_Chosen) {p.chosen = chosen}

// Values need owned storage, but schema keys outlive the palette. The embedded shortcut row's key
// needs a copy too, since closing that edit destroys its editor. A copy that cannot be stored chooses
// nothing, so the owner never applies a partial value.
@(private)
choose_setting :: proc(p: ^Palette, key, value: string, copy_key := false) -> Outcome {
	saved_key := key
	if copy_key {
		clear(&p.chosen_key)
		if _, err := append(&p.chosen_key, key); err != nil {return .None}
		saved_key = string(p.chosen_key[:])
	}
	clear(&p.chosen_value)
	if _, err := append(&p.chosen_value, value); err != nil {return .None}
	palette_choose(p, Chosen_Value{saved_key, string(p.chosen_value[:])})
	return .Set_Setting
}

// Hands the owner what the outcome it is handling names, once.
@(require_results)
palette_chosen_take :: proc(p: ^Palette) -> Palette_Chosen {
	chosen := p.chosen
	p.chosen = nil
	return chosen
}

palette_query :: proc(p: ^Palette) -> string {return field_string(&p.query)}

palette_mode_info :: proc(mode: Palette_Mode) -> Palette_Mode_Info {return PALETTE_MODES[mode]}

palette_mode_word :: proc(mode: Palette_Mode) -> string {return PALETTE_MODES[mode].name}

palette_mode_prefix :: proc(mode: Palette_Mode) -> string {return PALETTE_MODES[mode].prefix}

// The prefix a typed query starts with, or no length when it is literal text.
palette_parse_prefix :: proc(text: string) -> (mode: Palette_Mode, length: int) {
	for info, candidate in PALETTE_MODES {
		if info.prefix != "" && strings.has_prefix(text, info.prefix) {return candidate, len(info.prefix)}
	}
	return .All, 0
}

palette_next_mode :: proc(mode: Palette_Mode, reverse: bool = false) -> Palette_Mode {
	for candidate, i in PALETTE_CYCLE {
		if candidate == mode {
			step := reverse ? len(PALETTE_CYCLE) - 1 : 1
			return PALETTE_CYCLE[(i + step) % len(PALETTE_CYCLE)]
		}
	}
	return .All
}

// A mode change is a new search: the old selection has no meaning in the new domain. Recorded keys
// become typed text, which every mode can search, and a pending assignment ends.
palette_set_mode :: proc(p: ^Palette, registry: ^commands.Registry, mode: Palette_Mode) {
	if p.mode == mode {return}
	if p.keys.state != .Off {key_search_leave(&p.keys, &p.query)}
	p.assign = nil
	p.mode = mode
	p.selected, p.scroll = 0, 0
	refresh(p, registry)
}

palette_cycle_mode :: proc(p: ^Palette, registry: ^commands.Registry, reverse: bool = false) {
	palette_set_mode(p, registry, palette_next_mode(p.mode, reverse))
}

// Whether the query takes raw keys: record mode waits for a chord.
palette_recording :: proc(p: ^Palette) -> bool {return p.keys.state == .Recording}

// Turns the query's record mode on or off; on, it searches commands, so other scopes show Commands.
palette_key_search_toggle :: proc(p: ^Palette, registry: ^commands.Registry) -> Outcome {
	edit_set(p, nil)
	drag_set(p, nil)
	if p.keys.state != .Off {
		key_search_leave(&p.keys, &p.query)
	} else {
		if p.mode != .All && p.mode != .Commands {p.mode = .Commands}
		key_search_start(&p.keys)
	}
	p.selected, p.scroll = 0, 0
	refresh(p, registry)
	return .Changed
}

@(private)
palette_key_search_step :: proc(p: ^Palette, registry: ^commands.Registry, step: Key_Search_Step) -> Outcome {
	switch step {
	case .None:
		return .None
	case .Changed:
	case .Leave:
		key_search_leave(&p.keys, &p.query)
	}
	p.selected, p.scroll = 0, 0
	refresh(p, registry)
	return .Changed
}

// Lists commands for picking one to take `chord`, which the Unassigned row offered: choosing one opens
// its shortcut editor with the chord added, and Enter there saves it.
palette_assign :: proc(p: ^Palette, registry: ^commands.Registry, chord: commands.Shortcut) -> Outcome {
	edit_set(p, nil)
	p.keys = {}
	field_set(&p.query, "")
	p.mode = .Commands
	p.assign = chord
	p.selected, p.scroll = 0, 0
	refresh(p, registry)
	return .Changed
}

// Whether a command can run now. The palette leaves out unavailable commands unless a shortcut search
// matched them, since that answers what the keys do; run leaves them be. Hidden commands serve scripts
// and are never listed.
@(private)
palette_available :: proc(p: ^Palette, command: ^commands.Command) -> bool {
	a := p.availability
	return a.available == nil || a.available(a.user, command.id)
}

@(private)
source_item :: proc(source: Palette_Source, index: int) -> Palette_Item {
	if source.item == nil || index < 0 {return {}}
	return source.item(source.user, index)
}

palette_result_name :: proc(p: ^Palette, r: Palette_Result) -> string {
	switch r.kind {
	case .Command:
		return r.command != nil ? r.command.name : ""
	case .Setting:
		return r.setting >= 0 && r.setting < len(p.settings) ? p.settings[r.setting].key : ""
	case .Tab:
		return source_item(p.tabs, r.source).label
	case .Workspace:
		return source_item(p.workspaces, r.source).label
	case .Unassigned:
		return "unassigned"
	}
	return ""
}

palette_result_title :: proc(p: ^Palette, r: Palette_Result) -> string {
	switch r.kind {
	case .Command:
		return r.command != nil ? r.command.title : ""
	case .Setting:
		return r.setting >= 0 && r.setting < len(p.settings) ? p.settings[r.setting].title : ""
	case .Tab:
		return source_item(p.tabs, r.source).label
	case .Workspace:
		return source_item(p.workspaces, r.source).label
	case .Unassigned:
		return "Unassigned"
	}
	return ""
}

// The muted right-side field of a tab row: its workspace, which tells same-named tabs apart.
palette_result_context :: proc(p: ^Palette, r: Palette_Result) -> string {
	return r.kind == .Tab ? source_item(p.tabs, r.source).owner : ""
}

// Another result has the same title, so the row names its kind after the title.
palette_title_collides :: proc(p: ^Palette, index: int) -> bool {
	if index < 0 || index >= len(p.results) {return false}
	title := palette_result_title(p, p.results[index])
	if title == "" {return false}
	for other, i in p.results {
		if i != index && strings.equal_fold(palette_result_title(p, other), title) {return true}
	}
	return false
}

palette_target :: proc(p: ^Palette, r: Palette_Result) -> Palette_Target {
	switch r.kind {
	case .Command:
		return {kind = .Command, command = r.command != nil ? r.command.id : 0}
	case .Setting:
		return {
			kind = .Setting,
			setting = r.setting >= 0 && r.setting < len(p.settings) ? p.settings[r.setting].key : "",
		}
	case .Tab:
		return {kind = .Tab, id = r.id}
	case .Workspace:
		return {kind = .Workspace, id = r.id}
	case .Unassigned:
		return {kind = .Unassigned}
	}
	return {}
}

@(private)
setting_header_match :: proc(p: ^Palette, setting: int, query: string, highlights: []int) -> (
	match: fuzzy.Result, positions: []int,
) {
	s := p.settings[setting]
	clear(&p.haystack)
	// Room for the header alias and the title, so the text matched is never a truncated copy.
	needed := len(s.group) + len(PALETTE_SETTING_SUFFIX) + 2 + len(s.title)
	if reserve(&p.haystack, needed) != nil {return}
	append(&p.haystack, s.group)
	append(&p.haystack, PALETTE_SETTING_SUFFIX)
	// The displayed singular header is also a subsequence of this plural alias.
	append(&p.haystack, 's')
	by_header, header_error := fuzzy.score(query, string(p.haystack[:]), p.scratch)
	if header_error != .None {return}
	if by_header.matched {return by_header, nil}
	append(&p.haystack, ' ')
	title_start := len(p.haystack)
	append(&p.haystack, s.title)
	combined, combined_error := fuzzy.match_positions(query, string(p.haystack[:]), highlights, p.scratch)
	if combined_error != .None || !combined.matched {return}
	// The renderer expects UTF-8 byte offsets into the title, never the header.
	count := 0
	for pos in highlights {
		if pos >= title_start {
			highlights[count] = pos - title_start
			count += 1
		}
	}
	return combined, highlights[:count]
}

@(private)
fold_prefix :: proc(value, prefix: string) -> bool {
	s, p := value, prefix
	for len(p) > 0 {
		if len(s) == 0 {return false}
		_, s_size := utf8.decode_rune_in_string(s)
		_, p_size := utf8.decode_rune_in_string(p)
		if !strings.equal_fold(s[:s_size], p[:p_size]) {return false}
		s, p = s[s_size:], p[p_size:]
	}
	return true
}

@(private)
fold_contains :: proc(value, needle: string) -> bool {
	if len(needle) == 0 {return true}
	for offset := 0; offset < len(value); {
		if fold_prefix(value[offset:], needle) {return true}
		_, size := utf8.decode_rune_in_string(value[offset:])
		offset += size
	}
	return false
}

// The explainable match class of one field: exact, prefix, substring, then fuzzy.
@(private)
match_class :: proc(query, value: string) -> int {
	if strings.equal_fold(query, value) {return 0}
	if fold_prefix(value, query) {return 1}
	if fold_contains(value, query) {return 2}
	return 3
}

// Label matches always outrank secondary-field matches, keeping the palette's title-first rule.
// Within a field the classes run exact, prefix, substring, fuzzy; fields run label, then the
// caller's order, so a settings key match ranks below any label match but above a group match.
@(private)
rank_fields :: proc(
	query, primary: string,
	secondary: []string,
	scratch: ^fuzzy.Scratch,
	fuzzy_matches: bool,
) -> (
	rank: int,
	score: f64,
	matched, title_match: bool,
) {
	by_primary, primary_error := fuzzy.score(query, primary, scratch)
	if primary_error != .None {return}
	if by_primary.matched {
		class := match_class(query, primary)
		if class < 3 {return class, by_primary.score, true, true}
		if fuzzy_matches {return PALETTE_RANK_FUZZY, by_primary.score, true, true}
	}
	for field, i in secondary {
		by_field, field_error := fuzzy.score(query, field, scratch)
		if field_error != .None {continue}
		if !by_field.matched {continue}
		class := match_class(query, field)
		if class == 3 && !fuzzy_matches {continue}
		base := PALETTE_RANK_FIELDS + 3 * i
		return base + class, by_field.score, true, false
	}
	return 0, 0, false, false
}

@(private)
shortcut_rank :: proc(match: commands.Shortcut_Match) -> int {
	switch match {
	case .None:
		return -1
	case .Exact:
		return PALETTE_RANK_CHORD
	case .Partial, .Modifiers:
		return PALETTE_RANK_PARTIAL
	case .Label:
		return PALETTE_RANK_LABEL
	}
	return -1
}

// The command alternative that answers the search best: the recorded keys in record mode, otherwise
// the typed query.
@(private)
command_shortcut_match :: proc(
	p: ^Palette, q: ^commands.Shortcut_Query, command: ^commands.Command,
) -> Shortcut_Highlight {
	best: Shortcut_Highlight
	for shortcut, i in commands.active_shortcuts(command) {
		hit := commands.Shortcut_Hit{}
		if p.keys.state != .Off {
			hit = key_search_match(&p.keys, shortcut)
		} else {
			hit = commands.shortcut_query_match(q, shortcut)
		}
		if hit.match > best.hit.match {best = {i, hit}}
	}
	return best
}

@(private)
append_result :: proc(
	p: ^Palette,
	result: Palette_Result,
	width: int,
	query, primary: string,
	title_match: bool,
) {
	copy := result
	if width > 0 {
		start := len(p.ordered) * width
		highlights := p.positions[start:start + width]
		if title_match {
			if _, err := fuzzy.match_positions(query, primary, highlights, p.scratch); err == .None {
				copy.positions = highlights
			}
		}
	}
	append(&p.ordered, copy)
}

@(private)
consider_item :: proc(
	p: ^Palette,
	kind: Palette_Kind,
	command: ^commands.Command,
	setting, source: int,
	id: u64,
	title: string,
	query: string,
	width: int,
	secondary: []string,
	fuzzy_matches: bool,
	shortcut: Shortcut_Highlight = {},
) {
	rank, score, matched, title_match := rank_fields(
		query,
		title,
		secondary,
		p.scratch,
		fuzzy_matches,
	)
	if by_shortcut := shortcut_rank(shortcut.hit.match); by_shortcut >= 0 && (!matched || by_shortcut < rank) {
		rank, matched = by_shortcut, true
	}
	if !matched {return}
	result := Palette_Result {
		kind        = kind,
		command     = command,
		setting     = setting,
		source      = source,
		id          = id,
		rank        = rank,
		score       = score,
		title_match = title_match,
		shortcut    = shortcut,
	}
	append_result(p, result, width, query, title, title_match)
}

// Settings carry the existing title/group matcher's header alias and add the key as a field.
@(private)
consider_setting :: proc(p: ^Palette, setting: int, query: string, width: int) {
	s := p.settings[setting]
	rank, score, matched, title_match := rank_fields(
		query,
		s.title,
		[]string{s.key, s.group},
		p.scratch,
		true,
	)
	result := Palette_Result {
		kind        = .Setting,
		command     = nil,
		setting     = setting,
		source      = -1,
		rank        = rank,
		score       = score,
		title_match = title_match,
	}
	if matched {
		append_result(p, result, width, query, s.title, title_match)
		return
	}
	start := len(p.ordered) * width
	highlights := p.positions[start:start + width]
	by_header, positions := setting_header_match(p, setting, query, highlights)
	if !by_header.matched {return}
	result.rank, result.score, result.title_match = PALETTE_NO_RANK, by_header.score, false
	result.positions = positions
	append(&p.ordered, result)
}

@(private)
count_of :: proc(source: Palette_Source) -> int {
	if source.count == nil {return 0}
	return max(0, source.count(source.user))
}

@(private)
less_result :: proc(a, b: Palette_Result) -> bool {
	if a.rank != b.rank {return a.rank < b.rank}
	return a.score > b.score
}

// Rebuilds the visible result list for the active mode as one flat ranking. An empty query lists
// each domain in natural order; otherwise label matches rank first, then shortcut and secondary fields,
// by match class and score, with the palette's domain order and then insertion order breaking ties. A
// complete chord no command uses leads the list as the Unassigned row.
@(private)
refresh :: proc(p: ^Palette, registry: ^commands.Registry) {
	query := palette_query(p)
	// An open control belongs to a row this refresh may move or remove.
	edit_set(p, nil)
	clear(&p.results)
	clear(&p.ordered)
	if p.keys.state != .Off {
		refresh_keys(p, registry)
		return
	}
	if !utf8.valid_string(query) {query = ""}
	empty := strings.trim_space(query) == ""
	width := empty ? 0 : utf8.rune_count(query)
	tabs := (p.mode == .All || p.mode == .Tabs) ? count_of(p.tabs) : 0
	workspaces := (p.mode == .All || p.mode == .Workspaces) ? count_of(p.workspaces) : 0
	enabled_commands := 0
	if p.mode == .All || p.mode == .Commands {
		for &command in registry.items {if !command.hidden {enabled_commands += 1}}
	}
	setting_count := (p.mode == .All || p.mode == .Settings) ? len(p.settings) : 0
	candidates := tabs + workspaces + setting_count + enabled_commands
	// Every candidate's storage is in place before ranking, so the appends below cannot fail and the
	// published list is complete. Without room the palette lists nothing rather than a partial list.
	if reserve(&p.ordered, candidates) != nil || reserve(&p.results, candidates + 1) != nil ||
	   (width > 0 && resize(&p.positions, candidates * width) != nil) {
		log.errorf("palette: no room for %d results", candidates)
		p.selected, p.scroll = 0, 0
		return
	}
	shortcuts: commands.Shortcut_Query
	if !empty {shortcuts = commands.shortcut_query(query)}
	spans: [Palette_Kind][2]int
	if p.mode == .All || p.mode == .Tabs {
		start := len(p.ordered)
		for index in 0 ..< tabs {
			item := source_item(p.tabs, index)
			if empty {
				append(&p.ordered, Palette_Result{kind = .Tab, setting = -1, source = index, id = item.id,
					rank = PALETTE_NO_RANK})
			} else {
				consider_item(
					p,
					.Tab,
					nil,
					-1,
					index,
					item.id,
					item.label,
					query,
					width,
					[]string{item.detail, item.owner},
					false,
				)
			}
		}
		spans[.Tab] = {start, len(p.ordered)}
	}
	if p.mode == .All || p.mode == .Workspaces {
		start := len(p.ordered)
		for index in 0 ..< workspaces {
			item := source_item(p.workspaces, index)
			if empty {
				append(&p.ordered, Palette_Result{kind = .Workspace, setting = -1, source = index,
					id = item.id, rank = PALETTE_NO_RANK})
			} else {
				consider_item(
					p,
					.Workspace,
					nil,
					-1,
					index,
					item.id,
					item.label,
					query,
					width,
					[]string{item.detail},
					false,
				)
			}
		}
		spans[.Workspace] = {start, len(p.ordered)}
	}
	if p.mode == .All || p.mode == .Settings {
		start := len(p.ordered)
		for setting in 0 ..< setting_count {
			if empty {
				append(&p.ordered, Palette_Result{kind = .Setting, setting = setting, source = -1,
					rank = PALETTE_NO_RANK})
			} else {
				consider_setting(p, setting, query, width)
			}
		}
		spans[.Setting] = {start, len(p.ordered)}
	}
	if p.mode == .All || p.mode == .Commands {
		start := len(p.ordered)
		for &command in registry.items {
			if command.hidden {continue}
			if empty {
				if !palette_available(p, &command) {continue}
				append(&p.ordered, Palette_Result{kind = .Command, command = &command, setting = -1,
					rank = PALETTE_NO_RANK})
				continue
			}
			match := command_shortcut_match(p, &shortcuts, &command)
			if match.hit.match == .None && !palette_available(p, &command) {continue}
			consider_item(
				p,
				.Command,
				&command,
				-1,
				-1,
				0,
				command.title,
				query,
				width,
				[]string{commands.category(command.name).title},
				true,
				match,
			)
		}
		spans[.Command] = {start, len(p.ordered)}
	}
	if chord, named := commands.shortcut_query_chord(&shortcuts);
	   named && enabled_commands > 0 && (.Leader not_in chord.modifiers || p.leader != nil) &&
	   commands.shortcut_free(registry, chord, p.leader) {
		append(&p.results, Palette_Result{kind = .Unassigned, setting = -1, source = -1, chord = chord})
	}
	first := len(p.results)
	if len(p.ordered) > 0 {
		for kind in PALETTE_DOMAIN_ORDER {
			append(&p.results, ..p.ordered[spans[kind][0]:spans[kind][1]])
		}
		if !empty {slice.stable_sort_by(p.results[first:], less_result)}
	}
	p.selected = clamp(p.selected, 0, max(0, len(p.results) - 1))
	keep_selection_visible(p)
}

// Record mode lists the commands the recorded keys run, in registry order, after the Unassigned row
// for a complete chord that runs nothing.
@(private)
refresh_keys :: proc(p: ^Palette, registry: ^commands.Registry) {
	if reserve(&p.results, len(registry.items) + 1) != nil {
		log.errorf("palette: no room for %d results", len(registry.items) + 1)
		p.selected, p.scroll = 0, 0
		return
	}
	if chord, bindable := commands.key_press_chord(p.keys.press); bindable && keys_unbound(p, registry) {
		append(&p.results, Palette_Result{kind = .Unassigned, setting = -1, source = -1, chord = chord})
	}
	if p.mode == .All || p.mode == .Commands {
		for &command in registry.items {
			if command.hidden {continue}
			match := command_shortcut_match(p, nil, &command)
			if match.hit.match == .None {continue}
			append(&p.results, Palette_Result{kind = .Command, command = &command, setting = -1, source = -1,
				shortcut = match})
		}
	}
	p.selected = clamp(p.selected, 0, max(0, len(p.results) - 1))
	keep_selection_visible(p)
}

// Whether no command, listed or not, runs the recorded chord.
@(private)
keys_unbound :: proc(p: ^Palette, registry: ^commands.Registry) -> bool {
	for &command in registry.items {
		for shortcut in commands.active_shortcuts(&command) {
			if key_search_match(&p.keys, shortcut).match == .Exact {return false}
		}
	}
	return true
}

@(private)
keep_selection_visible :: proc(p: ^Palette) {
	rows := max(1, p.visible_rows)
	p.selected = clamp(p.selected, 0, max(0, len(p.results) - 1))
	p.scroll = clamp(p.scroll, 0, max(0, len(p.results) - rows))
	if p.selected < p.scroll {
		p.scroll = p.selected
	} else if p.selected >= p.scroll + rows {
		p.scroll = p.selected - rows + 1
	}
}

@(private)
move :: proc(p: ^Palette, delta: int) -> Outcome {
	if len(p.results) == 0 {
		return .None
	}
	p.selected = clamp(p.selected + delta, 0, len(p.results) - 1)
	keep_selection_visible(p)
	return .Changed
}

@(private)
run :: proc(p: ^Palette, registry: ^commands.Registry, index: int) -> (Outcome, commands.Command_Id) {
	if p.visible_rows == 0 || index < 0 || index >= len(p.results) {
		return .None, 0
	}
	result := p.results[index]
	if result.kind == .Unassigned {return palette_assign(p, registry, result.chord), 0}
	if _, assigning := p.assign.?; assigning && result.kind == .Command {
		return palette_binding_assign(p, index), 0
	}
	if result.kind == .Command && !palette_available(p, result.command) {return .None, 0}
	palette_close(p)
	switch result.kind {
	case .Command:
		return .Run, result.command.id
	case .Setting:
		palette_choose(p, Chosen_Setting{p.settings[result.setting].key})
		return .Open_Setting, 0
	case .Tab:
		palette_choose(p, Chosen_Tab{result.id})
		return .Open_Tab, 0
	case .Workspace:
		palette_choose(p, Chosen_Workspace{result.id})
		return .Open_Workspace, 0
	case .Unassigned:
	}
	return .None, 0
}

// Removes a consumed prefix without moving a caret that already sits after it.
@(private)
strip_prefix :: proc(f: ^Text_Field, length: int) {
	if length <= 0 || length > len(f.bytes) {return}
	copy(f.bytes[:], f.bytes[length:])
	resize(&f.bytes, len(f.bytes) - length)
	f.cursor = max(0, f.cursor - length)
	f.anchor = max(0, f.anchor - length)
}

@(private)
edited :: proc(p: ^Palette, registry: ^commands.Registry, change: Field_Change) -> Outcome {
	switch change {
	case .None:
		return .None
	case .Moved:
		return .Changed
	case .Edited:
	}
	if mode, length := palette_parse_prefix(field_string(&p.query)); length > 0 {
		strip_prefix(&p.query, length)
		p.mode = mode
	}
	p.selected, p.scroll = 0, 0
	refresh(p, registry)
	return .Changed
}

// Handles a key while the palette is open. Every key is consumed, so none reaches the terminal.
palette_key :: proc(
	p: ^Palette,
	registry: ^commands.Registry,
	e: input.Key_Event,
) -> (
	Outcome,
	commands.Command_Id,
) {
	if !e.pressed {
		return .None, 0
	}
	switch &edit in p.edit {
	case Shortcut_Edit:
		return palette_binding_key(p, &edit, e), 0
	case Choice_Edit, Text_Edit:
		return edit_key(p, e), 0
	}
	if _, sliding := p.drag.(Slider_Drag); sliding {return .None, 0}
	// Recording takes every key, app shortcuts included; a recorded search keeps its own few.
	if p.keys.state == .Recording {
		return palette_key_search_step(p, registry, key_search_record(&p.keys, e, p.leader)), 0
	}
	if key_search_toggles(e) {return palette_key_search_toggle(p, registry), 0}
	if p.keys.state == .Recorded {
		if step, handled := key_search_recorded_key(&p.keys, e); handled {
			return palette_key_search_step(p, registry, step), 0
		}
	}
	#partial switch e.key {
	case .Tab:
		palette_cycle_mode(p, registry, .Shift in e.modifiers)
		return .Changed, 0
	case .Backspace:
		if p.mode != .All && p.query.cursor == 0 && p.query.anchor == 0 {
			palette_set_mode(p, registry, .All)
			return .Changed, 0
		}
	}
	if (e.key == .Enter || e.key == .Numpad_Enter) && PALETTE_OPERATE in e.modifiers &&
	   p.selected >= 0 && p.selected < len(p.results) {
		#partial switch p.results[p.selected].kind {
		case .Command:
			if p.assign != nil {return palette_binding_assign(p, p.selected), 0}
			return palette_binding_open(p, p.selected), 0
		case .Unassigned:
			return run(p, registry, p.selected)
		}
	}
	// The adjust chord steps the selected setting; the operate chord operates its control.
	if s := result_setting(p, p.selected); s != nil && s.control != .None {
		setting := p.results[p.selected].setting
		alt := PALETTE_ADJUST in e.modifiers && PALETTE_OPERATE not_in e.modifiers
		#partial switch e.key {
		case .Arrow_Left:
			if alt {return control_step(p, setting, -1), 0}
		case .Arrow_Right:
			if alt {return control_step(p, setting, 1), 0}
		case .Enter, .Numpad_Enter:
			if PALETTE_OPERATE in e.modifiers {return control_activate(p, setting), 0}
		}
	}
	if step := list_key_step(e, p.visible_rows, len(p.results)); step != 0 {return move(p, step), 0}
	#partial switch e.key {
	case PALETTE_CANCEL_KEY:
		palette_close(p)
		return .Closed, 0
	case .Enter, .Numpad_Enter:
		return run(p, registry, p.selected)
	}
	// The hidden text of a recorded search is not edited; typing returns through palette_text.
	if p.keys.state != .Off {return .None, 0}
	return edited(p, registry, field_key(&p.query, e)), 0
}

palette_text :: proc(p: ^Palette, registry: ^commands.Registry, text: string) -> Outcome {
	if palette_editing(p) != .None {return edit_text(p, text)}
	switch p.keys.state {
	case .Off:
	case .Recording:
		return .None
	case .Recorded:
		// Typing over recorded keys starts a new text search.
		p.keys = {}
		field_set(&p.query, "")
	}
	return edited(p, registry, field_text(&p.query, text))
}

// Pastes the first line of `text` over the query selection.
palette_paste :: proc(p: ^Palette, registry: ^commands.Registry, text: string) -> Outcome {
	line := text
	if end := strings.index_any(text, "\r\n"); end >= 0 {line = text[:end]}
	return palette_text(p, registry, line)
}

palette_selection :: proc(p: ^Palette) -> string {
	if field := edit_field(p); field != nil {return field_selected_text(field)}
	// Recorded keys are drawn as keycaps; the text behind them is not on screen to copy.
	if p.keys.state != .Off {return ""}
	return field_selected_text(&p.query)
}

palette_cut :: proc(p: ^Palette, registry: ^commands.Registry) -> Outcome {
	if palette_selection(p) == "" {return .None}
	return palette_text(p, registry, "")
}

// The panel's bands for a viewport: where it starts, how tall each part is and how many result rows
// fit. palette_fit and palette_layout both measure from it.
@(private)
Palette_Frame :: struct {
	width, height, scale, border, panel_width, top:                f32,
	row_height, padding, footer_height, input_height, mode_height: f32,
	separator:                                                     f32,
	rows:                                                          int,
}

@(private)
palette_frame :: proc(viewport_width, viewport_height, viewport_scale: f32) -> Palette_Frame {
	width, height := max(0, viewport_width), max(0, viewport_height)
	scale := viewport_scale > 0 ? viewport_scale : 1
	border := min(scale, width / 2, height / 2)
	panel_width := min(PALETTE_WIDTH * scale, width - 2 * min(16 * scale, width / 4))
	row_height := PALETTE_ROW_HEIGHT * scale
	padding := PALETTE_PADDING * scale
	footer_height := PALETTE_FOOTER_HEIGHT * scale
	input_height := PALETTE_INPUT_HEIGHT * scale
	mode_height := PALETTE_MODE_HEIGHT * scale
	full_height := mode_height + input_height + 1 + 2 * padding +
		PALETTE_MAX_ROWS * row_height + footer_height
	// Caption controls claim pointer input in the title chrome and are hit before the
	// palette, so the panel starts below that band and gives up rows rather than put its
	// query or results where the chrome would take the press. When the client has no
	// room outside the chrome the band ends at the client edge and no panel is left.
	claim := min(height, caption_claim_height(scale))
	top := max(max(24 * scale, height * 0.12), claim)
	top = min(top, max(claim, height - border - full_height))
	available := max(0, height - border - top)
	// Keep the query usable before spending a short client's remaining height on modes.
	input_height = min(input_height, available)
	mode_height = min(mode_height, max(0, available - input_height))
	separator := min(f32(1), available - input_height - mode_height)
	remaining := max(0, available - input_height - mode_height - separator)
	padding = min(padding, remaining / 2)
	footer_height = min(footer_height, max(0, remaining - 2 * padding))
	// A last row matters more than the key hints on a very short client.
	if footer_height > 0 &&
	   remaining - 2 * padding - footer_height < row_height &&
	   remaining - 2 * padding >= row_height {
		footer_height = 0
	}
	rows_space := max(0, remaining - 2 * padding - footer_height)
	return {
		width = width, height = height, scale = scale, border = border, panel_width = panel_width,
		top = top, row_height = row_height, padding = padding, footer_height = footer_height,
		input_height = input_height, mode_height = mode_height, separator = separator,
		rows = clamp(int(rows_space / row_height), 0, PALETTE_MAX_ROWS),
	}
}

// Sizes the result list for a viewport: how many rows fit, with the selection kept on one of them.
// Owners fit whenever the viewport may have changed; palette_draw fits before it draws.
palette_fit :: proc(p: ^Palette, viewport_width, viewport_height, viewport_scale: f32) {
	frame := palette_frame(viewport_width, viewport_height, viewport_scale)
	p.visible_rows = frame.rows
	p.fit_page = {0, 0, frame.width, frame.height}
	p.fit_scale = frame.scale
	keep_selection_visible(p)
	palette_binding_fit(p)
}

// Measures the palette for a viewport without changing it.
palette_layout :: proc(p: ^Palette, viewport_width, viewport_height, viewport_scale: f32) -> Palette_Layout {
	f := palette_frame(viewport_width, viewport_height, viewport_scale)
	width, height, scale, border := f.width, f.height, f.scale, f.border
	panel_width, row_height, padding := f.panel_width, f.row_height, f.padding
	footer_height, input_height := f.footer_height, f.input_height
	mode_height, separator := f.mode_height, f.separator
	rows := clamp(len(p.results) - p.scroll, 0, f.rows)
	if len(p.results) == 0 && f.rows > 0 {rows = 1}
	used := f32(rows) * row_height
	list_padding := min(padding, panel_width / 2)
	panel := render.Rect {
		x      = (width - panel_width) / 2,
		y      = f.top,
		width  = panel_width,
		height = mode_height + input_height + separator + 2 * padding + used + footer_height,
	}
	mode_bar := render.Rect{panel.x, panel.y, panel.width, mode_height}
	input := render.Rect{panel.x, panel.y + mode_height, panel.width, input_height}
	l := Palette_Layout {
		panel      = panel,
		mode_bar   = mode_bar,
		input      = input,
		list       = {panel.x + list_padding, input.y + input_height + separator + padding,
			panel.width - 2 * list_padding, used},
		viewport   = {0, 0, width, height},
		row_height = row_height,
		scale      = scale,
		rows       = rows,
	}
	mode_inset := min(SPACE_2 * scale, panel.width / 2)
	mode_space := max(0, panel.width - 2 * mode_inset)
	minimum: f32
	for minimum_width in PALETTE_MODE_WIDTHS {minimum += minimum_width * scale}
	extra := max(0, mode_space - minimum) / f32(len(PALETTE_CYCLE))
	fit := min(1, mode_space / minimum)
	mode_x := panel.x + mode_inset
	for mode in PALETTE_CYCLE {
		mode_width := PALETTE_MODE_WIDTHS[mode] * scale * fit + extra
		l.modes[mode] = {mode_x, panel.y, mode_width, mode_height}
		mode_x += mode_width
	}
	if footer_height > 0 {l.footer = {panel.x, l.list.y + used + padding, panel.width, footer_height}}
	// The keyboard button closes the query row; a row too narrow for it and some text has none.
	button := min(HEIGHT_TOOLBAR * scale, input.height)
	needed := (2 * PALETTE_TEXT_INSET + ICON_BUTTON + SPACE_3 + HEIGHT_TOOLBAR + 3 * SPACE_6) * scale
	if input.width >= needed {
		right := input.x + input.width - (PALETTE_TEXT_INSET - SPACE_2) * scale
		l.keys = {right - button, input.y + (input.height - button) / 2, button, button}
	}
	// The track replaces the list's right padding, inside the panel border.
	extent := Scroll_Extent{len(p.results), f.rows, p.scroll}
	gutter := SCROLLBAR_TRACK * scale + border
	area := render.Rect{panel.x + panel.width - gutter, l.list.y, SCROLLBAR_TRACK * scale, used}
	state := palette_scrollbar_state(p)
	if l.bar, l.bar_visible = scrollbar_layout(area, extent, state, scale); l.bar_visible {
		l.list.width = max(0, area.x - l.list.x)
	}
	return l
}

@(private)
row_at :: proc(p: ^Palette, l: Palette_Layout, x, y: f32) -> int {
	r := l.list
	if !render.rect_contains(r, x, y) || l.row_height <= 0 {
		return -1
	}
	index := p.scroll + int((y - r.y) / l.row_height)
	return index < len(p.results) && index - p.scroll < l.rows ? index : -1
}

@(private)
mode_at :: proc(l: Palette_Layout, x, y: f32) -> int {
	for mode, i in PALETTE_CYCLE {
		if render.rect_contains(l.modes[mode], x, y) {return i}
	}
	return -1
}

palette_mouse_move :: proc(p: ^Palette, l: Palette_Layout, x, y: f32) -> Outcome {
	if _, sliding := p.drag.(Slider_Drag); sliding {return .None}
	switch &edit in p.edit {
	case Shortcut_Edit:
		return palette_binding_hover(p, &edit, l, x, y)
	case Choice_Edit:
		hover := popup_row_at(p, &edit, l, x, y)
		if hover == edit.hover {return .None}
		edit.hover = hover
		return .Changed
	case Text_Edit:
		return .None
	}
	hover := mode_at(l, x, y)
	mode_changed := hover != p.mode_hover
	p.mode_hover = hover
	over_bar := l.bar_visible && scrollbar_contains(l.bar, x, y)
	over_keys := render.rect_contains(l.keys, x, y)
	// The scrollbar, keyboard and reset buttons light only under the pointer, so entering or leaving
	// them redraws.
	reset := reset_at(p, l, x, y)
	reset_changed := reset != p.reset_hover || over_bar != p.scroll_hover || over_keys != p.keys_hover
	p.scroll_hover = over_bar
	p.keys_hover = over_keys
	p.reset_hover = reset
	index := row_at(p, l, x, y)
	if index < 0 || index == p.selected {
		return reset_changed || mode_changed ? .Changed : .None
	}
	p.selected = index
	return .Changed
}

palette_mouse_press :: proc(
	p: ^Palette,
	registry: ^commands.Registry,
	l: Palette_Layout,
	x, y: f32,
	text: ^Text = nil,
) -> (
	Outcome,
	commands.Command_Id,
) {
	if index := mode_at(l, x, y); index >= 0 && !palette_popup_contains(p, l, x, y) {
		edit_set(p, nil)
		drag_set(p, nil)
		palette_set_mode(p, registry, PALETTE_CYCLE[index])
		return .Changed, 0
	}
	if render.rect_contains(l.keys, x, y) && !palette_popup_contains(p, l, x, y) {
		return palette_key_search_toggle(p, registry), 0
	}
	if binding, open := &p.edit.(Shortcut_Edit); open {
		return palette_binding_press(p, binding, l, x, y), 0
	}
	if outcome, handled := edit_press(p, l, text, x, y); handled {return outcome, 0}
	if l.bar_visible && scrollbar_contains(l.bar, x, y) {
		drag: Scroll_Drag
		offset := scrollbar_press(&drag, l.bar, y)
		if drag.active {drag_set(p, Scrollbar_Drag{drag.grab})}
		palette_scroll_to(p, offset)
		return .Changed, 0
	}
	if index := row_at(p, l, x, y); index >= 0 {
		if p.results[index].kind == .Command {
			row, _ := row_rect(p, l, index)
			parts := palette_binding_parts(row, l.scale)
			if render.rect_contains(parts.reset, x, y) {return palette_binding_reset(p, index), 0}
			if render.rect_contains(parts.field, x, y) {
				if p.assign != nil {return palette_binding_assign(p, index), 0}
				return palette_binding_open(p, index), 0
			}
		}
		if outcome, handled := reset_press(p, l, index, x, y); handled {return outcome, 0}
		if outcome, handled := control_press(p, l, index, x, y); handled {return outcome, 0}
		return run(p, registry, index)
	}
	if !render.rect_contains(l.panel, x, y) {
		palette_close(p)
		return .Closed, 0
	}
	return .None, 0
}

palette_query_box :: proc(p: ^Palette, l: Palette_Layout, text: ^Text, scale: f32) -> Field_Box {
	box := Field_Box {
		field = &p.query,
		text = text,
		rect = l.input,
		inset = PALETTE_TEXT_INSET,
		caret_width = 1.5,
		radius = 0,
		style = .Display,
		scale = scale,
	}
	left := min(box.rect.width, (PALETTE_TEXT_INSET + ICON_BUTTON + SPACE_3) * scale)
	right := l.input.x + l.input.width - PALETTE_TEXT_INSET * scale
	if l.keys.width > 0 {right = l.keys.x - SPACE_2 * scale}
	box.rect.x += left
	box.rect.width = max(0, right - box.rect.x)
	box.inset = 0
	return box
}

// The query row, apart from its keyboard button.
palette_input_contains :: proc(l: Palette_Layout, x, y: f32) -> bool {
	return render.rect_contains(l.input, x, y) && !render.rect_contains(l.keys, x, y)
}

palette_over_text :: proc(l: Palette_Layout, x, y: f32) -> bool {
	return palette_input_contains(l, x, y)
}

palette_pointer :: proc(p: ^Palette, l: Palette_Layout, x, y: f32) -> platform.Cursor_Shape {
	if shape, ok := control_pointer(p, l, x, y); ok {return shape}
	if mode_at(l, x, y) >= 0 || render.rect_contains(l.keys, x, y) {return .Hand}
	if palette_over_text(l, x, y) {return .Text}
	if l.bar_visible && scrollbar_contains(l.bar, x, y) {return .Arrow}
	if row_at(p, l, x, y) >= 0 {return .Hand}
	return .Arrow
}

// Places the caret, or with `extend` grows the selection, and starts a drag selection.
palette_input_press :: proc(
	p: ^Palette,
	l: Palette_Layout,
	text: ^Text,
	x, y, scale: f32,
	extend: bool,
) -> Outcome {
	edit_set(p, nil)
	// Recorded keys hide the text, so there is no caret to place.
	if p.keys.state != .Off {return .None}
	at := field_box_offset(palette_query_box(p, l, text, scale), x)
	drag_set(p, Query_Drag{})
	return field_move(&p.query, at, extend) == .None ? .None : .Changed
}

palette_input_drag :: proc(p: ^Palette, l: Palette_Layout, text: ^Text, x, scale: f32) -> Outcome {
	if _, selecting := p.drag.(Query_Drag); !selecting {return .None}
	at := field_box_offset(palette_query_box(p, l, text, scale), x)
	return field_move(&p.query, at, true) == .None ? .None : .Changed
}

palette_scroll :: proc(p: ^Palette, rows: int) -> Outcome {
	if _, sliding := p.drag.(Slider_Drag); sliding {return .None}
	switch &edit in p.edit {
	case Shortcut_Edit:
		return .None
	case Choice_Edit:
		return popup_wheel(p, &edit, rows)
	case Text_Edit:
		edit_set(p, nil)
	}
	return palette_scroll_to(p, p.scroll - rows)
}

// Scrolls the results to `offset`, keeping the selection on a visible row.
@(private)
palette_scroll_to :: proc(p: ^Palette, offset: int) -> Outcome {
	if p.visible_rows == 0 || len(p.results) == 0 {return .None}
	scroll := clamp(offset, 0, max(0, len(p.results) - p.visible_rows))
	if scroll == p.scroll {return .None}
	p.scroll = scroll
	p.selected = clamp(p.selected, p.scroll, min(len(p.results), p.scroll + p.visible_rows) - 1)
	return .Changed
}

palette_scrollbar_state :: proc(p: ^Palette) -> Scrollbar_State {
	if _, holding := p.drag.(Scrollbar_Drag); holding {return .Active}
	return p.scroll_hover ? .Hovered : .Collapsed
}

// Tracks hover through the drag too, so the bar collapses on a release away from the track.
palette_scrollbar_drag :: proc(p: ^Palette, l: Palette_Layout, x, y: f32) -> Outcome {
	drag, holding := p.drag.(Scrollbar_Drag)
	if !holding || !l.bar_visible {return .None}
	p.scroll_hover = scrollbar_contains(l.bar, x, y)
	return palette_scroll_to(p, scrollbar_drag({active = true, grab = drag.grab}, l.bar, y))
}

@(private)
draw_footer :: proc(
	p: ^Palette,
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	l: Palette_Layout,
	scale: f32,
) -> render.Build_Status {
	if l.footer.width <= 0 || l.footer.height <= 0 {return .Ok}
	if render.push_layer(list, l.footer) != .None {return .Ok}
	draw_rect(list, {
		rect  = {l.footer.x, l.footer.y, l.footer.width, scale},
		color = theme.border,
	})
	if binding, open := &p.edit.(Shortcut_Edit); open {
		hint_text := text_styled(text, .Detail)
		message, error := shortcut_capture_footer(&binding.capture)
		return draw_text(&hint_text, list, message, l.footer.x + 12 * scale,
		                 l.footer.y + (l.footer.height - hint_text.line_height) / 2 + hint_text.ascent,
		                 error ? theme.error : theme.muted, max(1, l.footer.width - 24 * scale))
	}
	hints: [PALETTE_HINT_CAP]Palette_Key_Hint
	count := palette_key_hints(p, &hints)
	if count == 0 {return .Ok}
	keycap := text_styled(text, .Detail)
	label := text_styled(text, .Detail)
	inset, gap := DIALOG_PADDING * scale, SPACE_4 * scale
	baseline := l.footer.y + (l.footer.height - label.line_height) / 2 + label.ascent
	// Close is pinned right; the other hints run left to right and stop before they would meet it.
	last := hints[count - 1]
	last_x := l.footer.x + l.footer.width - inset - key_hint_width(&keycap, &label, last, scale)
	if result := draw_key_hint(list, &keycap, &label, theme, last, last_x, l.footer, baseline, scale);
	   result != .Ok {return result}
	x := l.footer.x + inset
	for hint in hints[:count - 1] {
		width := key_hint_width(&keycap, &label, hint, scale)
		if x + width > last_x - gap {break}
		if result := draw_key_hint(list, &keycap, &label, theme, hint, x, l.footer, baseline, scale);
		   result != .Ok {return result}
		x += width + gap
	}
	return .Ok
}

// The keys that apply to the current selection or open control, ending with the closing key.
palette_key_hints :: proc(p: ^Palette, out: ^[PALETTE_HINT_CAP]Palette_Key_Hint) -> int {
	count := 0
	add :: proc(out: ^[PALETTE_HINT_CAP]Palette_Key_Hint, count: ^int, first, second, label: string) {
		out[count^] = {keys = {first, second}, label = label}
		count^ += 1
	}
	#partial switch _ in p.edit {
	case Choice_Edit:
		add(out, &count, LIST_NEXT_LABEL, LIST_PREVIOUS_LABEL, "Navigate")
		add(out, &count, PALETTE_ACCEPT_LABEL, "", "Choose")
		add(out, &count, PALETTE_CANCEL_LABEL, "", "Cancel")
		return count
	case Text_Edit:
		add(out, &count, PALETTE_ACCEPT_LABEL, "", "Apply")
		add(out, &count, PALETTE_CANCEL_LABEL, "", "Cancel")
		return count
	}
	if p.keys.state == .Recording {
		add(out, &count, KEY_SEARCH_CLEAR_LABEL, "", "Clear")
		add(out, &count, PALETTE_CANCEL_LABEL, KEY_SEARCH_LABEL, "Search by text")
		return count
	}
	if p.selected >= 0 && p.selected < len(p.results) {
		add(out, &count, LIST_NEXT_LABEL, LIST_PREVIOUS_LABEL, "Navigate")
		switch p.results[p.selected].kind {
		case .Command:
			if p.assign != nil {
				add(out, &count, PALETTE_ACCEPT_LABEL, "", "Assign shortcut")
			} else {
				add(out, &count, PALETTE_ACCEPT_LABEL, "", "Run command")
				add(out, &count, PALETTE_OPERATE_LABEL, "", "Edit shortcut")
			}
		case .Setting:
			add(out, &count, PALETTE_ACCEPT_LABEL, "", "Go to setting")
			if s := result_setting(p, p.selected); s != nil && s.control != .None {
				add(out, &count, PALETTE_OPERATE_LABEL, "", "Change")
				if s.control != .Text {add(out, &count, PALETTE_ADJUST_LABEL, "", "Adjust")}
			}
		case .Tab:
			add(out, &count, PALETTE_ACCEPT_LABEL, "", "Switch tab")
		case .Workspace:
			add(out, &count, PALETTE_ACCEPT_LABEL, "", "Switch workspace")
		case .Unassigned:
			add(out, &count, PALETTE_ACCEPT_LABEL, "", "Assign to a command")
		}
	}
	if p.keys.state == .Recorded {
		add(out, &count, KEY_SEARCH_CLEAR_LABEL, "", "Record again")
		add(out, &count, PALETTE_CANCEL_LABEL, "", "Search by text")
		return count
	}
	add(out, &count, KEY_SEARCH_LABEL, "", "Search by keys")
	add(out, &count, PALETTE_CANCEL_LABEL, "", "Close")
	return count
}

@(private)
key_hint_width :: proc(keycap, label: ^Text, hint: Palette_Key_Hint, scale: f32) -> f32 {
	pad := KEYCAP_PADDING * scale
	width := text_width(keycap, hint.keys[0]) + 2 * pad
	if hint.keys[1] != "" {
		width += text_width(label, "/") + 2 * SPACE_1 * scale + text_width(keycap, hint.keys[1]) + 2 * pad
	}
	return width + SPACE_1 * scale + text_width(label, hint.label)
}

@(private)
draw_key_hint :: proc(
	list: ^render.Draw_List,
	keycap, label: ^Text,
	theme: Theme,
	hint: Palette_Key_Hint,
	x: f32,
	footer: render.Rect,
	baseline: f32,
	scale: f32,
) -> render.Build_Status {
	pen := x
	height := min(PALETTE_KEYCAP_HEIGHT * scale, footer.height)
	top := footer.y + (footer.height - height) / 2
	for key, i in hint.keys {
		if key == "" {continue}
		if i > 0 {
			pen += 4 * scale
			if result := draw_text(label, list, "/", pen, baseline, theme.faint); result != .Ok {return result}
			pen += text_width(label, "/") + 4 * scale
		}
		width := text_width(keycap, key) + 2 * KEYCAP_PADDING * scale
		draw_rect(list, {
			rect   = {pen, top, width, height},
			color  = theme.border,
			radius = RADIUS_CONTROL * scale,
			stroke = scale,
		})
		key_baseline := top + (height - keycap.line_height) / 2 + keycap.ascent
		key_x := pen + KEYCAP_PADDING * scale
		if result := draw_text(keycap, list, key, key_x, key_baseline, theme.muted); result != .Ok {
			return result
		}
		pen += width
	}
	return draw_text(label, list, hint.label, pen + SPACE_1 * scale, baseline, theme.muted)
}

@(private)
draw_modes :: proc(
	p: ^Palette,
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	l: Palette_Layout,
	scale: f32,
) -> render.Build_Status {
	if l.mode_bar.width <= 0 || l.mode_bar.height <= 0 {return .Ok}
	if render.push_layer(list, l.mode_bar) != .None {return .Ok}
	draw_rect(list, {
		rect = {l.mode_bar.x, l.mode_bar.y + l.mode_bar.height - scale, l.mode_bar.width, scale},
		color = theme.border,
	})
	mode_text := text_styled(text, .Body)
	for mode, i in PALETTE_CYCLE {
		row := l.modes[mode]
		inset := min(CONTROL_INSET * scale, row.width / 2)
		if p.mode_hover == i {
			hover := render.Rect{row.x, row.y + SPACE_1 * scale, row.width,
				max(0, row.height - 2 * SPACE_1 * scale)}
			draw_rect(list, {rect = hover, color = theme.hover, radius = RADIUS_CONTROL * scale})
		}
		if p.mode == mode {
			line_height := min(2 * scale, row.height)
			line := render.Rect{row.x + inset, row.y + row.height - line_height,
				max(0, row.width - 2 * inset), line_height}
			draw_rect(list, {rect = line, color = theme.accent, radius = pill_radius(line)})
		}
		room := max(0, row.width - 2 * inset)
		if room <= 0 {continue}
		word := PALETTE_MODES[mode].word
		icon_size := min(ICON_BUTTON * scale, room)
		gap := min(SPACE_2 * scale, max(0, room - icon_size))
		text_room := max(0, room - icon_size - gap)
		width := min(text_width(&mode_text, word), text_room)
		x := row.x + (row.width - icon_size - gap - width) / 2
		ink := p.mode == mode || p.mode_hover == i ? theme.text : theme.muted
		icon := render.Rect{x, row.y, icon_size, row.height}
		icon_draw(list, PALETTE_MODES[mode].icon, icon, ink, icon_size / scale, scale)
		if text_room <= 0 {continue}
		baseline := row.y + (row.height - mode_text.line_height) / 2 + mode_text.ascent
		if result := draw_text(&mode_text, list, word, x + icon_size + gap, baseline,
			ink, text_room); result != .Ok {return result}
	}
	return .Ok
}

palette_draw :: proc(
	p: ^Palette,
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	width, height, scale: f32,
	fade := FADE_NONE,
	pointer: [2]f32 = {},
) -> render.Build_Status {
	palette_fit(p, width, height, scale)
	l := palette_layout(p, width, height, scale)
	panel := l.panel
	if render.push_layer(list, {0, 0, width, height}) != .None {
		return .Ok
	}
	// The full-window clip stays put; the panel sinks no lower than the client's bottom edge.
	mark := render.draw_mark(list)
	bounded := Fade{fade.opacity, clamp(fade.rise, 0, max(0, height - scale - panel.y - panel.height))}
	defer fade_draw(list, mark, bounded)
	draw_rect(list, {rect = {0, 0, width, height}, color = theme.scrim})
	frame := dialog_panel(panel, scale)
	if panel_draw(list, frame, theme) != .None {return .Ok}
	draw_rect(list, {
		rect  = {panel.x, l.input.y + l.input.height, panel.width, scale},
		color = theme.border,
	})
	if result := draw_modes(p, list, text, theme, l, scale); result != .Ok {return result}
	if render.push_layer(list, l.input) != .None { return .Ok }
	padding := PALETTE_TEXT_INSET * scale
	search := render.Rect{l.input.x + padding, l.input.y, ICON_BUTTON * scale, l.input.height}
	icon_draw(list, .Search, search, theme.muted, ICON_BUTTON, scale)
	box := palette_query_box(p, l, text, scale)
	query_text := text_styled(text, .Display)
	if box.rect.width > 1 && p.keys.state != .Off {
		keycap_text := text_styled(text, .Body)
		if result := key_search_draw(&p.keys, list, &keycap_text, theme, box.rect, scale); result != .Ok {
			return result
		}
	} else if box.rect.width > 1 {
		placeholder := PALETTE_MODES[p.mode].placeholder
		buffer: [128]u8
		if chord, assigning := p.assign.?; assigning {
			label: [commands.SHORTCUT_TEXT_CAP]u8
			placeholder = fmt.bprintf(buffer[:], "Choose a command for %s", commands.shortcut_text(chord, label[:]))
		}
		baseline := l.input.y + (l.input.height - query_text.line_height) / 2 + query_text.ascent
		if result := field_box_draw(box, list, theme, baseline, true, placeholder); result != .Ok { return result }
	}
	if key_search_button_draw(list, theme, l.keys, p.keys.state != .Off, scale, pointer) != .None {return .Ok}
	title_text := text^
	if l.rows > 0 && l.list.width > 0 {
		if render.push_layer(list, l.list) != .None { return .Ok }
		if len(p.results) == 0 {
			empty := "No results"
			if p.keys.state != .Off {
				empty = p.keys.press.state == .Chord ? KEY_SEARCH_NO_MATCH : KEY_SEARCH_EMPTY_HINT
			}
			row_baseline := l.list.y + (l.row_height - title_text.line_height) / 2 + title_text.ascent
			if result := draw_text(&title_text, list, empty, l.list.x + padding, row_baseline,
				theme.muted, max(1, l.list.width - 2 * padding)); result != .Ok {return result}
		}
	}
	if len(p.results) > 0 && l.rows > 0 && l.list.width > 0 {
		small := text_styled(text, .Detail)
		kind_text := text_styled(text, .Detail)
		row_padding := PALETTE_PADDING * scale
		for rows in 0 ..< l.rows {
			index := p.scroll + rows
			if index >= len(p.results) {break}
			item := p.results[index]
			row := render.Rect{l.list.x, l.list.y + f32(rows) * l.row_height, l.list.width, l.row_height}
			if index == p.selected {
				draw_rect(list, {rect = row, color = theme.selection, radius = RADIUS_CONTROL * scale})
				if render.rect_contains(row, pointer.x, pointer.y) {
					// The row carries the selection tint, not the paper fill, so no hairline.
					if result := hover_rim_draw(list, theme, row, RADIUS_CONTROL * scale, 1, scale, pointer, false);
					   result != .None {return .Ok}
				}
			}
			// The right edge of the title's room: the row's one functional field starts there.
			side := row.x + row.width - row_padding
			if item.command != nil {
				parts := palette_binding_parts(row, scale)
				side = parts.field.x
				binding, open := &p.edit.(Shortcut_Edit)
				if open && binding.result == index && binding.capture.state != .Alternatives {
					side = parts.positions.x
				}
				if result := palette_binding_draw(p, item.command, index, row, list, text, theme, l, pointer);
				   result != .Ok {return result}
			}
			if item.kind == .Unassigned {
				parts := palette_binding_parts(row, scale)
				parts.positions = {}
				side = parts.field.x
				buffer: [commands.SHORTCUT_TEXT_CAP]u8
				positions: [commands.SHORTCUT_TEXT_CAP]int
				label := commands.shortcut_text(item.chord, buffer[:])
				lit := commands.Shortcut_Hit{.Exact, item.chord.modifiers, true}
				summary := Shortcut_Summary{first = label}
				summary.highlights = commands.shortcut_hit_positions(label, lit, positions[:])
				if result := shortcut_field_draw(list, text, theme, parts, summary, {}, l.viewport, scale);
				   result != .Ok {return result}
			}
			if s := result_setting(p, index); s != nil {
				if s.control != .None {side = min(side, control_rect(s, row, scale).x)}
				if s.resettable {side = min(side, reset_rect(s, row, scale).x)}
				if result := draw_reset(p, list, theme, l, index, row, pointer); result != .Ok {return result}
				if result := draw_control(p, list, text, theme, l, item.setting, row); result != .Ok {
					return result
				}
			}
			row_baseline := row.y + (row.height - title_text.line_height) / 2 + title_text.ascent
			if context_label := palette_result_context(p, item); context_label != "" {
				room := max(0, (row.width - 2 * row_padding - PALETTE_GLYPH_WIDTH * scale) * 0.4)
				label_width := min(text_width(&small, context_label), room)
				side = row.x + row.width - row_padding - label_width
				if result := draw_fading_text(&small, list, context_label, side, row_baseline, theme.muted,
					label_width); result != .Ok {return result}
			}
			icon_size := ICON_BUTTON * scale
			icon_y := row.y + (row.height - icon_size) / 2
			kind_icon := render.Rect{row.x + row_padding, icon_y, icon_size, icon_size}
			kind_mark := item.kind == .Unassigned ? Icon.Add : PALETTE_MODES[PALETTE_KIND_MODES[item.kind]].icon
			icon_draw(list, kind_mark, kind_icon, theme.muted, ICON_BUTTON, scale)
			title := palette_result_title(p, item)
			title_x := row.x + row_padding + PALETTE_GLYPH_WIDTH * scale
			room := max(0, side - 12 * scale - title_x)
			kind_width: f32
			kind_word := ""
			if palette_title_collides(p, index) {
				kind_word = PALETTE_KIND_WORDS[item.kind]
				kind_width = text_width(&kind_text, kind_word) + SPACE_2 * scale
			}
			title_width := min(text_width(&title_text, title), max(0, room - kind_width))
			if title_width <= 0 {continue}
			result := draw_text(
				&title_text,
				list,
				title,
				title_x,
				row_baseline,
				theme.text,
				title_width,
				item.positions,
				theme.accent,
			)
			if result != .Ok {
				return result
			}
			if kind_word != "" && room - title_width - SPACE_2 * scale > 0 {
				if kind_result := draw_text(&kind_text, list, kind_word, title_x + title_width + SPACE_2 * scale,
					row_baseline, theme.faint, max(0, room - title_width - SPACE_2 * scale)); kind_result != .Ok {
					return kind_result
				}
			}
		}
	}
	if l.bar_visible {scrollbar_draw(list, theme, l.bar, palette_scrollbar_state(p))}
	if result := draw_footer(p, list, text, theme, l, scale); result != .Ok {return result}
	if binding, open := &p.edit.(Shortcut_Edit); open {
		return palette_binding_popup_draw(p, binding, l, list, text, theme, pointer)
	}
	if result := draw_popup(p, list, text, theme, l); result != .Ok {return result}
	return .Ok
}
