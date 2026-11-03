package ui

import "aio:commands"
import "aio:fuzzy"
import "aio:glyphs"
import "aio:platform"
import "aio:render"
import "base:runtime"
import "core:slice"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

@(private) PALETTE_MAX_ROWS :: 8
@(private) PALETTE_WIDTH :: 560
@(private) PALETTE_INPUT_HEIGHT :: 64
@(private) PALETTE_ROW_HEIGHT :: 40
@(private) PALETTE_FOOTER_HEIGHT :: 32
@(private) PALETTE_PADDING :: 8
@(private) PALETTE_TEXT_INSET :: DIALOG_PADDING
@(private) PALETTE_SETTING_SUFFIX :: " SETTING"
@(private) PALETTE_CHIP_HEIGHT :: HEIGHT_COMPACT
@(private) PALETTE_CHIP_GAP :: SPACE_2
@(private) PALETTE_KEYCAP_HEIGHT :: 20
@(private) PALETTE_MENU_WIDTH :: 176
@(private) PALETTE_MENU_ROW :: MENU_ROW_HEIGHT
@(private) PALETTE_MENU_INSET :: OVERLAY_PADDING
// A leading icon and the gap after it.
@(private) PALETTE_GLYPH_WIDTH :: ICON_BUTTON + SPACE_2
@(private) PALETTE_NO_RANK :: 99
@(private) PALETTE_PRESENCE :: Presence_Spec {
	open  = 120 * time.Millisecond,
	close = 90 * time.Millisecond,
}

// What activating a result does.
Outcome :: enum {
	None,
	Changed,
	Closed,
	Run,
	Open_Setting,
	// A setting control chose a new value; palette_chosen_value names it. The palette stays open.
	Set_Setting,
	Open_Tab,
	Open_Workspace,
}

// The kind a result belongs to. A row names it only when another result shares its title.
Palette_Kind :: enum {
	Command,
	Setting,
	Tab,
	Workspace,
}

// The search domain carried by the removable query chip.
Palette_Mode :: enum {
	All,
	Tabs,
	Workspaces,
	Settings,
	Commands,
}

Palette_Mode_Info :: struct {
	word, prefix, placeholder: string,
}

@(private) PALETTE_MODES := [Palette_Mode]Palette_Mode_Info {
	.All         = {"All", "", "Search"},
	.Tabs        = {"Tabs", "t:", "Search tabs"},
	.Workspaces  = {"Workspaces", "w:", "Search workspaces"},
	.Settings    = {"Settings", "s:", "Search settings"},
	.Commands    = {"Commands", "c:", "Search commands"},
}

@(private) PALETTE_CYCLE := [?]Palette_Mode {
	.All,
	.Tabs,
	.Workspaces,
	.Settings,
	.Commands,
}

@(private) PALETTE_MENU_ORDER := [?]Palette_Mode {
	.All,
	.Tabs,
	.Workspaces,
	.Settings,
	.Commands,
}

// The order of an empty query's list and of equal-ranked matches: the original domains first.
@(private) PALETTE_DOMAIN_ORDER := [?]Palette_Kind{.Command, .Setting, .Tab, .Workspace}

@(private) PALETTE_KIND_WORDS := [Palette_Kind]string {
	.Command = "Command",
	.Setting = "Setting",
	.Tab = "Tab",
	.Workspace = "Workspace",
}

// Identity never relies on colour: every row carries this shape, and a type word on a title clash.
@(private) PALETTE_KIND_ICONS := [Palette_Kind]Icon {
	.Command = .Command,
	.Setting = .Settings,
	.Tab = .Layout_Top,
	.Workspace = .Workspace,
}

@(private) PALETTE_CHIP_WIDTHS := [Palette_Mode]f32 {
	.All = 48,
	.Tabs = 60,
	.Workspaces = 96,
	.Settings = 80,
	.Commands = 92,
}

// One footer entry: its keycaps, joined by a slash, and what they do.
Palette_Key_Hint :: struct {
	keys:  [2]string,
	label: string,
}

// At most navigate, three selection actions, and close.
@(private) PALETTE_HINT_CAP :: 5

// A setting the palette can open in the settings editor, and the control it offers in place.
// The strings are static schema text. A choice without `choices` asks Palette_Values for a live list.
Palette_Setting :: struct {
	key, title, group:      string,
	control:                Palette_Control,
	minimum, maximum, step: f64,
	choices:                []string,
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

// A command result, a setting result, or a tab/workspace result.
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
	results:        [dynamic]Palette_Result,
	// Matches gathered per domain before sections are ordered into `results`.
	ordered:        [dynamic]Palette_Result,
	positions:      [dynamic]int,
	haystack:       [dynamic]u8,
	settings:       []Palette_Setting,
	tabs:           Palette_Source,
	workspaces:     Palette_Source,
	mode:           Palette_Mode,
	mode_menu:      bool,
	menu_hover:     int,
	// The setting key of the last Open_Setting or Set_Setting outcome.
	chosen:       string,
	chosen_value: [dynamic]u8,
	chosen_id:    u64,
	scratch:      ^fuzzy.Scratch,
	values:       Palette_Values,
	edit:         Palette_Edit,
	// Shortcut editing uses the same capture and alternatives control as Settings.
	binding:      Editor,
	binding_result: int,
	chosen_key:   [dynamic]u8,
	leader:       Maybe(commands.Shortcut),
	reset_hover:  int,
	scroll_hover: bool,
	scroll_drag:  Scroll_Drag,
}

Palette_Layout :: struct {
	panel, input, list, footer, chip, menu: render.Rect,
	viewport:                               render.Rect,
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
	edit_init(&p.edit, allocator)
	p.settings = settings
	p.visible_rows = PALETTE_MAX_ROWS
	p.menu_hover = -1
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
	editor_destroy(&p.binding)
	delete(p.chosen_key)
	free(p.scratch, p.query.bytes.allocator)
	delete(p.query.bytes)
	delete(p.results)
	delete(p.ordered)
	delete(p.positions)
	delete(p.haystack)
	delete(p.chosen_value)
	edit_destroy(&p.edit)
	p^ = {}
}

// The app supplies its live tab and workspace lists once; the callbacks read current records.
palette_set_sources :: proc(p: ^Palette, tabs, workspaces: Palette_Source) {
	p.tabs, p.workspaces = tabs, workspaces
}

palette_open :: proc(p: ^Palette, registry: ^commands.Registry) {
	palette_open_mode(p, registry, .All)
}

palette_open_mode :: proc(p: ^Palette, registry: ^commands.Registry, mode: Palette_Mode) {
	presence_open(&p.presence, PALETTE_PRESENCE)
	field_set(&p.query, "")
	p.selected, p.scroll = 0, 0
	p.mode = mode
	p.mode_menu = false
	p.menu_hover = -1
	p.reset_hover = -1
	p.scroll_hover, p.scroll_drag = false, {}
	p.chosen, p.chosen_id = "", 0
	refresh(p, registry)
}

palette_close :: proc(p: ^Palette) {
	palette_edit_cancel(p)
	presence_close(&p.presence)
	p.query.dragging = false
	p.mode_menu = false
	p.scroll_hover, p.scroll_drag = false, {}
}

palette_query :: proc(p: ^Palette) -> string {return field_string(&p.query)}

palette_mode :: proc(p: ^Palette) -> Palette_Mode {return p.mode}

palette_mode_info :: proc(mode: Palette_Mode) -> Palette_Mode_Info {return PALETTE_MODES[mode]}

palette_mode_word :: proc(mode: Palette_Mode) -> string {
	switch mode {
	case .All:
		return "all"
	case .Tabs:
		return "tabs"
	case .Workspaces:
		return "workspaces"
	case .Settings:
		return "settings"
	case .Commands:
		return "commands"
	}
	return "all"
}

palette_mode_prefix :: proc(mode: Palette_Mode) -> string {return PALETTE_MODES[mode].prefix}

// The prefix a typed query starts with, or no length when it is literal text.
palette_parse_prefix :: proc(text: string) -> (mode: Palette_Mode, length: int) {
	if len(text) < 2 || text[1] != ':' {return .All, 0}
	switch text[0] {
	case 't':
		return .Tabs, 2
	case 'w':
		return .Workspaces, 2
	case 's':
		return .Settings, 2
	case 'c':
		return .Commands, 2
	}
	return .All, 0
}

palette_next_mode :: proc(mode: Palette_Mode) -> Palette_Mode {
	for candidate, i in PALETTE_CYCLE {
		if candidate == mode {return PALETTE_CYCLE[(i + 1) % len(PALETTE_CYCLE)]}
	}
	return .All
}

// A mode change is a new search: the old selection has no meaning in the new domain.
palette_set_mode :: proc(p: ^Palette, registry: ^commands.Registry, mode: Palette_Mode) {
	p.mode_menu = false
	p.menu_hover = -1
	if p.mode == mode {return}
	p.mode = mode
	p.selected, p.scroll = 0, 0
	refresh(p, registry)
}

palette_cycle_mode :: proc(p: ^Palette, registry: ^commands.Registry) {
	palette_set_mode(p, registry, palette_next_mode(p.mode))
}

// The category a command name belongs to, such as Panes for pane.split_right.
command_category :: proc(name: string) -> string {
	dot := strings.index_byte(name, '.')
	switch dot < 0 ? name : name[:dot] {
	case "app":
		return "Application"
	case "terminal":
		return "Terminal"
	case "pane":
		return "Panes"
	case "tab":
		return "Tabs"
	case "workspace":
		return "Workspaces"
	case "window":
		return "Windows"
	case "settings":
		return "Settings"
	case "edit":
		return "Edit"
	case "view":
		return "View"
	}
	return "Commands"
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
	}
	return {}
}

@(private)
setting_header_match :: proc(p: ^Palette, setting: int, query: string, highlights: []int) -> (
	match: fuzzy.Result, positions: []int,
) {
	s := p.settings[setting]
	clear(&p.haystack)
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
		if fuzzy_matches {return 3, by_primary.score, true, true}
	}
	for field, i in secondary {
		by_field, field_error := fuzzy.score(query, field, scratch)
		if field_error != .None {continue}
		if !by_field.matched {continue}
		class := match_class(query, field)
		if class == 3 && !fuzzy_matches {continue}
		base := 4 + 3 * i
		return base + class, by_field.score, true, false
	}
	return 0, 0, false, false
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
) {
	rank, score, matched, title_match := rank_fields(
		query,
		title,
		secondary,
		p.scratch,
		fuzzy_matches,
	)
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
// each domain in natural order; otherwise label matches rank first, then secondary fields, by match
// class and score, with the palette's domain order and then insertion order breaking ties.
@(private)
refresh :: proc(p: ^Palette, registry: ^commands.Registry) {
	query := palette_query(p)
	// An open control belongs to a row this refresh may move or remove.
	palette_edit_cancel(p)
	clear(&p.results)
	clear(&p.ordered)
	if !utf8.valid_string(query) {query = ""}
	empty := strings.trim_space(query) == ""
	width := empty ? 0 : utf8.rune_count(query)
	tabs := (p.mode == .All || p.mode == .Tabs) ? count_of(p.tabs) : 0
	workspaces := (p.mode == .All || p.mode == .Workspaces) ? count_of(p.workspaces) : 0
	enabled_commands := 0
	if p.mode == .All || p.mode == .Commands {
		for command in registry.items {if !command.disabled && !command.hidden {enabled_commands += 1}}
	}
	setting_count := (p.mode == .All || p.mode == .Settings) ? len(p.settings) : 0
	candidates := tabs + workspaces + setting_count + enabled_commands
	if !empty && width > 0 {resize(&p.positions, candidates * width)}
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
					[]string{item.detail},
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
			if command.disabled || command.hidden {continue}
			if empty {
				append(&p.ordered, Palette_Result{kind = .Command, command = &command, setting = -1,
					rank = PALETTE_NO_RANK})
			} else {
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
					[]string{command_category(command.name)},
					true,
				)
			}
		}
		spans[.Command] = {start, len(p.ordered)}
	}
	if len(p.ordered) > 0 {
		_ = reserve(&p.results, len(p.ordered))
		for kind in PALETTE_DOMAIN_ORDER {
			append(&p.results, ..p.ordered[spans[kind][0]:spans[kind][1]])
		}
		if !empty {slice.stable_sort_by(p.results[:], less_result)}
	}
	p.selected = clamp(p.selected, 0, max(0, len(p.results) - 1))
	keep_selection_visible(p)
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
run :: proc(p: ^Palette, index: int) -> (Outcome, commands.Command_Id) {
	if p.visible_rows == 0 || index < 0 || index >= len(p.results) {
		return .None, 0
	}
	result := p.results[index]
	palette_close(p)
	switch result.kind {
	case .Command:
		return .Run, result.command.id
	case .Setting:
		p.chosen = p.settings[result.setting].key
		p.chosen_id = 0
		return .Open_Setting, 0
	case .Tab:
		p.chosen_id = result.id
		return .Open_Tab, 0
	case .Workspace:
		p.chosen_id = result.id
		return .Open_Workspace, 0
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
		p.mode_menu = false
		p.menu_hover = -1
	}
	p.selected, p.scroll = 0, 0
	refresh(p, registry)
	return .Changed
}

// Handles a key while the palette is open. Every key is consumed, so none reaches the terminal.
palette_key :: proc(
	p: ^Palette,
	registry: ^commands.Registry,
	e: platform.Key_Event,
) -> (
	Outcome,
	commands.Command_Id,
) {
	if !e.pressed {
		return .None, 0
	}
	if p.edit.kind == .Shortcut {return palette_binding_key(p, e), 0}
	if p.edit.kind == .Choice || p.edit.kind == .Text {return edit_key(p, e), 0}
	if p.edit.kind == .Slider {return .None, 0}
	was_menu := p.mode_menu
	if was_menu {
		p.mode_menu = false
		p.menu_hover = -1
		if e.key == .Escape {return .Changed, 0}
	}
	#partial switch e.key {
	case .Tab:
		palette_cycle_mode(p, registry)
		return .Changed, 0
	case .Backspace:
		if p.mode != .All && p.query.cursor == 0 && p.query.anchor == 0 {
			palette_set_mode(p, registry, .All)
			return .Changed, 0
		}
	}
	shift := .Shift in e.modifiers
	if (e.key == .Enter || e.key == .Numpad_Enter) && .Control in e.modifiers &&
	   p.selected >= 0 && p.selected < len(p.results) && p.results[p.selected].kind == .Command {
		return palette_binding_open(p, p.selected), 0
	}
	// Alt+Left and Alt+Right step the selected setting; Ctrl+Enter operates its control.
	if s := result_setting(p, p.selected); s != nil && s.control != .None {
		setting := p.results[p.selected].setting
		alt := .Alt in e.modifiers && .Control not_in e.modifiers
		#partial switch e.key {
		case .Arrow_Left:
			if alt {return control_step(p, setting, -1), 0}
		case .Arrow_Right:
			if alt {return control_step(p, setting, 1), 0}
		case .Enter, .Numpad_Enter:
			if .Control in e.modifiers {return control_activate(p, setting), 0}
		}
	}
	if step := list_step(e); step != 0 {return move(p, step), 0}
	#partial switch e.key {
	case .Escape:
		palette_close(p)
		return .Closed, 0
	case .Enter, .Numpad_Enter:
		return run(p, p.selected)
	case .Page_Up:
		return move(p, -max(1, p.visible_rows)), 0
	case .Page_Down:
		return move(p, max(1, p.visible_rows)), 0
	case .Home:
		if !shift {return move(p, -len(p.results)), 0}
	case .End:
		if !shift {return move(p, len(p.results)), 0}
	}
	outcome := edited(p, registry, field_key(&p.query, e))
	if outcome == .None && was_menu {outcome = .Changed}
	return outcome, 0
}

palette_text :: proc(p: ^Palette, registry: ^commands.Registry, text: string) -> Outcome {
	if p.edit.kind != .None {return edit_text(p, text)}
	closed_menu := p.mode_menu
	p.mode_menu, p.menu_hover = false, -1
	outcome := edited(p, registry, field_text(&p.query, text))
	if outcome == .None && closed_menu {return .Changed}
	return outcome
}

// Pastes the first line of `text` over the query selection.
palette_paste :: proc(p: ^Palette, registry: ^commands.Registry, text: string) -> Outcome {
	line := text
	if end := strings.index_any(text, "\r\n"); end >= 0 {line = text[:end]}
	return palette_text(p, registry, line)
}

palette_selection :: proc(p: ^Palette) -> string {
	if field := edit_field(p); field != nil {return field_selected_text(field)}
	return field_selected_text(&p.query)
}

palette_cut :: proc(p: ^Palette, registry: ^commands.Registry) -> Outcome {
	if palette_selection(p) == "" {return .None}
	return palette_text(p, registry, "")
}

// The mode chip sits at the query's left inset, centred in the input band, in every mode.
@(private)
chip_rect :: proc(p: ^Palette, input: render.Rect, scale: f32) -> render.Rect {
	if input.width <= 0 || input.height <= 0 {return {}}
	inset := PALETTE_TEXT_INSET * scale
	width := min(PALETTE_CHIP_WIDTHS[p.mode] * scale, max(0, input.width / 2 - inset))
	height := min(PALETTE_CHIP_HEIGHT * scale, input.height)
	return {input.x + inset, input.y + (input.height - height) / 2, width, height}
}

palette_layout :: proc(p: ^Palette, viewport_width, viewport_height, viewport_scale: f32) -> Palette_Layout {
	width, height := max(0, viewport_width), max(0, viewport_height)
	scale := viewport_scale > 0 ? viewport_scale : 1
	border := min(scale, width / 2, height / 2)
	panel_width := min(PALETTE_WIDTH * scale, width - 2 * min(16 * scale, width / 4))
	row_height := PALETTE_ROW_HEIGHT * scale
	padding := PALETTE_PADDING * scale
	footer_height := PALETTE_FOOTER_HEIGHT * scale
	input_height := PALETTE_INPUT_HEIGHT * scale
	full_height := input_height + 1 + 2 * padding + PALETTE_MAX_ROWS * row_height + footer_height
	// Caption controls claim pointer input in the title chrome and are hit before the
	// palette, so the panel starts below that band and gives up rows rather than put its
	// query or results where the chrome would take the press. When the client has no
	// room outside the chrome the band ends at the client edge and no panel is left.
	claim := min(height, caption_claim_height(scale))
	top := max(max(24 * scale, height * 0.12), claim)
	top = min(top, max(claim, height - border - full_height))
	available := max(0, height - border - top)
	input_height = min(input_height, available)
	separator := min(f32(1), available - input_height)
	remaining := max(0, available - input_height - separator)
	padding = min(padding, remaining / 2)
	footer_height = min(footer_height, max(0, remaining - 2 * padding))
	// A last row matters more than the key hints on a very short client.
	if footer_height > 0 &&
	   remaining - 2 * padding - footer_height < row_height &&
	   remaining - 2 * padding >= row_height {
		footer_height = 0
	}
	rows_space := max(0, remaining - 2 * padding - footer_height)
	p.visible_rows = clamp(int(rows_space / row_height), 0, PALETTE_MAX_ROWS)
	keep_selection_visible(p)
	rows := clamp(len(p.results) - p.scroll, 0, p.visible_rows)
	if len(p.results) == 0 && p.visible_rows > 0 {rows = 1}
	used := f32(rows) * row_height
	list_padding := min(padding, panel_width / 2)
	panel := render.Rect {
		x      = (width - panel_width) / 2,
		y      = top,
		width  = panel_width,
		height = input_height + separator + 2 * padding + used + footer_height,
	}
	input := render.Rect{panel.x, panel.y, panel.width, input_height}
	l := Palette_Layout {
		panel      = panel,
		input      = input,
		list       = {panel.x + list_padding, input.y + input_height + separator + padding,
			panel.width - 2 * list_padding, used},
		chip       = chip_rect(p, input, scale),
		viewport   = {0, 0, width, height},
		row_height = row_height,
		scale      = scale,
		rows       = rows,
	}
	if footer_height > 0 {l.footer = {panel.x, l.list.y + used + padding, panel.width, footer_height}}
	// The track replaces the list's right padding, inside the panel border.
	extent := Scroll_Extent{len(p.results), p.visible_rows, p.scroll}
	gutter := SCROLLBAR_TRACK * scale + border
	area := render.Rect{panel.x + panel.width - gutter, l.list.y, SCROLLBAR_TRACK * scale, used}
	state := scrollbar_state(p.scroll_hover, p.scroll_drag)
	if l.bar, l.bar_visible = scrollbar_layout(area, extent, state, scale); l.bar_visible {
		l.list.width = max(0, area.x - l.list.x)
	}
	if p.mode_menu && l.chip.width > 0 {
		menu_width := min(PALETTE_MENU_WIDTH * scale, width - 2 * border)
		menu_height :=
			f32(len(PALETTE_MENU_ORDER) * PALETTE_MENU_ROW + 2 * PALETTE_MENU_INSET) * scale
		x := clamp(l.chip.x, border, max(border, width - menu_width - border))
		y := l.chip.y + l.chip.height + 4 * scale
		if y + menu_height > height - border {
			y = max(border, l.chip.y - menu_height - 4 * scale)
		}
		y = clamp(y, border, max(border, height - menu_height - border))
		l.menu = {x, y, menu_width, menu_height}
	}
	return l
}

@(private)
row_at :: proc(p: ^Palette, l: Palette_Layout, x, y: f32) -> int {
	r := l.list
	if x < r.x || x >= r.x + r.width || y < r.y || y >= r.y + r.height || l.row_height <= 0 {
		return -1
	}
	index := p.scroll + int((y - r.y) / l.row_height)
	return index < len(p.results) && index - p.scroll < l.rows ? index : -1
}

@(private)
menu_row_at :: proc(l: Palette_Layout, x, y: f32) -> int {
	if l.menu.width <= 0 || x < l.menu.x || x >= l.menu.x + l.menu.width {return -1}
	inset := PALETTE_MENU_INSET * (l.row_height / PALETTE_ROW_HEIGHT)
	if y < l.menu.y + inset || y >= l.menu.y + l.menu.height - inset {return -1}
	row_height := (l.menu.height - 2 * inset) / f32(len(PALETTE_MENU_ORDER))
	index := int((y - l.menu.y - inset) / row_height)
	if index < 0 || index >= len(PALETTE_MENU_ORDER) {return -1}
	return index
}

palette_mouse_move :: proc(p: ^Palette, l: Palette_Layout, x, y: f32) -> Outcome {
	switch p.edit.kind {
	case .Shortcut:
		return editor_hover(&p.binding, palette_binding_layout(p, l), x, y) ? .Changed : .None
	case .Choice:
		hover := popup_row_at(p, l, x, y)
		if hover == p.edit.hover {return .None}
		p.edit.hover = hover
		return .Changed
	case .Slider, .Text:
		return .None
	case .None:
	}
	if p.mode_menu {
		hover := menu_row_at(l, x, y)
		if hover == p.menu_hover {return .None}
		p.menu_hover = hover
		return .Changed
	}
	over_bar := l.bar_visible && scrollbar_contains(l.bar, x, y)
	// The scrollbar and reset button light only under the pointer, so entering or leaving them redraws.
	reset := reset_at(p, l, x, y)
	reset_changed := reset != p.reset_hover || over_bar != p.scroll_hover
	p.scroll_hover = over_bar
	p.reset_hover = reset
	index := row_at(p, l, x, y)
	if index < 0 || index == p.selected {
		return reset_changed ? .Changed : .None
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
	if p.edit.kind == .Shortcut {return palette_binding_press(p, l, text, x, y), 0}
	if outcome, handled := edit_press(p, l, text, x, y); handled {return outcome, 0}
	if p.mode_menu {
		if index := menu_row_at(l, x, y); index >= 0 {
			palette_set_mode(p, registry, PALETTE_MENU_ORDER[index])
		} else {
			p.mode_menu, p.menu_hover = false, -1
		}
		return .Changed, 0
	}
	if l.bar_visible && scrollbar_contains(l.bar, x, y) {
		palette_scroll_to(p, scrollbar_press(&p.scroll_drag, l.bar, y))
		return .Changed, 0
	}
	if index := row_at(p, l, x, y); index >= 0 {
		if p.results[index].kind == .Command {
			row, _ := row_rect(p, l, index)
			parts := palette_binding_parts(row, l.scale)
			if contains(parts.reset, x, y) {return palette_binding_reset(p, index), 0}
			if contains(parts.field, x, y) {return palette_binding_open(p, index), 0}
		}
		if outcome, handled := reset_press(p, l, index, x, y); handled {return outcome, 0}
		if outcome, handled := control_press(p, l, index, x, y); handled {return outcome, 0}
		return run(p, index)
	}
	r := l.panel
	if x < r.x || x >= r.x + r.width || y < r.y || y >= r.y + r.height {
		palette_close(p)
		return .Closed, 0
	}
	return .None, 0
}

// The query field's box: the input band right of the mode chip.
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
	if l.chip.width > 0 {
		left := l.chip.x + l.chip.width + PALETTE_CHIP_GAP * scale
		right := box.rect.x + box.rect.width - PALETTE_TEXT_INSET * scale
		box.rect.x = left
		box.rect.width = max(0, right - left)
		box.inset = 0
	}
	return box
}

palette_input_contains :: proc(l: Palette_Layout, x, y: f32) -> bool {
	r := l.input
	return x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height
}

palette_over_text :: proc(l: Palette_Layout, x, y: f32) -> bool {
	return palette_input_contains(l, x, y) && !contains(l.chip, x, y) && !contains(l.menu, x, y)
}

// Text over the query, a hand over the mode chip, mode menu rows and results.
palette_pointer :: proc(p: ^Palette, l: Palette_Layout, x, y: f32) -> platform.Cursor_Shape {
	if shape, ok := control_pointer(p, l, x, y); ok {return shape}
	if p.mode_menu && menu_row_at(l, x, y) >= 0 {return .Hand}
	if contains(l.chip, x, y) {return .Hand}
	if palette_over_text(l, x, y) {return .Text}
	// Outside the query, an open mode menu takes the next click only to close.
	if p.mode_menu {return .Arrow}
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
	palette_edit_cancel(p)
	if contains(l.chip, x, y) {
		p.mode_menu = !p.mode_menu
		p.menu_hover = -1
		return .Changed
	}
	closed_menu := p.mode_menu
	p.mode_menu, p.menu_hover = false, -1
	at := field_box_offset(palette_query_box(p, l, text, scale), x)
	if field_pointer(&p.query, at, true, extend) == .None {
		return closed_menu ? .Changed : .None
	}
	return .Changed
}

palette_input_drag :: proc(p: ^Palette, l: Palette_Layout, text: ^Text, x, scale: f32) -> Outcome {
	closed_menu := p.mode_menu
	p.mode_menu, p.menu_hover = false, -1
	at := field_box_offset(palette_query_box(p, l, text, scale), x)
	if field_pointer(&p.query, at, false, true) == .None {
		return closed_menu ? .Changed : .None
	}
	return .Changed
}

palette_input_release :: proc(p: ^Palette) -> bool {
	dragging := p.query.dragging
	p.query.dragging = false
	return dragging
}

palette_scroll :: proc(p: ^Palette, rows: int) -> Outcome {
	switch p.edit.kind {
	case .Shortcut:
		return .None
	case .Choice:
		return popup_wheel(p, rows)
	case .Slider:
		return .None
	case .Text:
		palette_edit_cancel(p)
	case .None:
	}
	if p.mode_menu {
		p.mode_menu, p.menu_hover = false, -1
		return .Changed
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

palette_scrollbar_dragging :: proc(p: ^Palette) -> bool {return p.scroll_drag.active}

// Tracks hover through the drag too, so the bar collapses on a release away from the track.
palette_scrollbar_drag :: proc(p: ^Palette, l: Palette_Layout, x, y: f32) -> Outcome {
	if !p.scroll_drag.active || !l.bar_visible {return .None}
	p.scroll_hover = scrollbar_contains(l.bar, x, y)
	return palette_scroll_to(p, scrollbar_drag(p.scroll_drag, l.bar, y))
}

@(private)
draw_footer :: proc(
	p: ^Palette,
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	l: Palette_Layout,
	scale: f32,
) -> glyphs.Result {
	if l.footer.width <= 0 || l.footer.height <= 0 {return .Ok}
	if render.push_layer(list, l.footer) != .None {return .Ok}
	draw_rect(list, {
		rect  = {l.footer.x, l.footer.y, l.footer.width, scale},
		color = theme.border,
	})
	if p.edit.kind == .Shortcut {
		hint_text := text_styled(text, .Detail)
		message := p.binding.message
		if !p.binding.error {
			message = p.binding.capturing ? "Press keys · Enter saves · Esc cancels · Backspace removes" :
			          "Enter replaces · Delete removes · Esc cancels"
		}
		return draw_text(&hint_text, list, message, l.footer.x + 12 * scale,
		                 l.footer.y + (l.footer.height - hint_text.line_height) / 2 + hint_text.ascent,
		                 p.binding.error ? theme.error : theme.muted, max(1, l.footer.width - 24 * scale))
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
	#partial switch p.edit.kind {
	case .Choice:
		add(out, &count, "Ctrl+N", "Ctrl+P", "Navigate")
		add(out, &count, "Enter", "", "Choose")
		add(out, &count, "Esc", "", "Cancel")
		return count
	case .Text:
		add(out, &count, "Enter", "", "Apply")
		add(out, &count, "Esc", "", "Cancel")
		return count
	}
	if p.selected >= 0 && p.selected < len(p.results) {
		add(out, &count, "Ctrl+N", "Ctrl+P", "Navigate")
		switch p.results[p.selected].kind {
		case .Command:
			add(out, &count, "Enter", "", "Run command")
			add(out, &count, "Ctrl+Enter", "", "Edit shortcut")
		case .Setting:
			add(out, &count, "Enter", "", "Go to setting")
			if s := result_setting(p, p.selected); s != nil && s.control != .None {
				add(out, &count, "Ctrl+Enter", "", "Change")
				if s.control != .Text {add(out, &count, "Alt+←/→", "", "Adjust")}
			}
		case .Tab:
			add(out, &count, "Enter", "", "Switch tab")
		case .Workspace:
			add(out, &count, "Enter", "", "Switch workspace")
		}
	}
	add(out, &count, "Esc", "", "Close")
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
) -> glyphs.Result {
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
draw_mode_menu :: proc(
	p: ^Palette,
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	l: Palette_Layout,
	scale: f32,
) -> glyphs.Result {
	if l.menu.width <= 0 || l.menu.height <= 0 {return .Ok}
	if render.push_layer(list, l.menu) != .None {return .Ok}
	draw_rect(list, {rect = l.menu, color = theme.pane, radius = RADIUS_OVERLAY * scale})
	draw_rect(list, {
		rect   = l.menu,
		color  = theme.border,
		radius = RADIUS_OVERLAY * scale,
		stroke = scale,
	})
	inset := PALETTE_MENU_INSET * scale
	row_height := (l.menu.height - 2 * inset) / f32(len(PALETTE_MENU_ORDER))
	mode_text := text^
	for mode, i in PALETTE_MENU_ORDER {
		row := render.Rect {
			l.menu.x + inset,
			l.menu.y + inset + f32(i) * row_height,
			l.menu.width - 2 * inset,
			row_height,
		}
		if p.mode == mode {
			draw_rect(list, {rect = row, color = theme.selection, radius = RADIUS_CONTROL * scale})
		} else if p.menu_hover == i {
			draw_rect(list, {rect = row, color = theme.hover, radius = RADIUS_CONTROL * scale})
		}
		info := PALETTE_MODES[mode]
		baseline := row.y + (row.height - mode_text.line_height) / 2 + mode_text.ascent
		if result := draw_text(&mode_text, list, info.word, row.x + CONTROL_INSET * scale, baseline,
			p.mode == mode ? theme.text : theme.muted); result != .Ok {return result}
		if info.prefix != "" {
			prefix_text := text_styled(text, .Detail)
			width := text_width(&prefix_text, info.prefix)
			if result := draw_text(&prefix_text, list, info.prefix,
				row.x + row.width - width - CONTROL_INSET * scale, baseline, theme.faint); result != .Ok {
				return result
			}
		}
	}
	return .Ok
}

palette_draw :: proc(
	p: ^Palette,
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	width, height, scale: f32,
	opacity: f32 = 1, rise: f32 = 0,
	pointer: [2]f32 = {},
) -> glyphs.Result {
	l := palette_layout(p, width, height, scale)
	panel := l.panel
	if render.push_layer(list, {0, 0, width, height}) != .None {
		return .Ok
	}
	layer_start, rect_start, glyph_start := len(list.layers), len(list.rects), len(list.glyphs)
	bounded_rise := clamp(rise, 0, max(0, height - scale - panel.y - panel.height))
	defer fade_draw(list, layer_start, rect_start, glyph_start, opacity, bounded_rise)
	draw_rect(list, {rect = {0, 0, width, height}, color = theme.scrim})
	frame := dialog_panel(panel, scale)
	if panel_draw(list, frame, theme) != .None {return .Ok}
	draw_rect(list, {
		rect  = {panel.x, l.input.y + l.input.height, panel.width, scale},
		color = theme.border,
	})
	if render.push_layer(list, l.input) != .None { return .Ok }
	padding := PALETTE_TEXT_INSET * scale
	if l.chip.width > 0 {
		chip := l.chip
		draw_rect(list, {rect = chip, color = theme.pane, radius = RADIUS_CONTROL * scale})
		draw_rect(list, {
			rect   = chip,
			color  = theme.border,
			radius = RADIUS_CONTROL * scale,
			stroke = scale,
		})
		chip_text := text_styled(text, .Detail)
		baseline := chip.y + (chip.height - chip_text.line_height) / 2 + chip_text.ascent
		chip_inset := CONTROL_INSET * scale
		if result := draw_text(&chip_text, list, PALETTE_MODES[p.mode].word, chip.x + chip_inset, baseline,
			theme.text, max(0, chip.width - 2 * chip_inset - (ICON_INDICATOR + SPACE_1) * scale));
		   result != .Ok {return result}
		chevron := render.Rect {
			chip.x + chip.width - (CONTROL_INSET + ICON_INDICATOR) * scale,
			chip.y,
			ICON_INDICATOR * scale,
			chip.height,
		}
		icon_draw(list, .Chevron_Down, chevron, theme.muted, ICON_INDICATOR, scale)
	}
	box := palette_query_box(p, l, text, scale)
	query_text := text_styled(text, .Display)
	if box.rect.width > 1 {
		baseline := l.input.y + (l.input.height - query_text.line_height) / 2 + query_text.ascent
		if result := field_box_draw(box, list, theme, baseline, true,
			PALETTE_MODES[p.mode].placeholder); result != .Ok { return result }
	}
	title_text := text^
	if l.rows > 0 && l.list.width > 0 {
		if render.push_layer(list, l.list) != .None { return .Ok }
		if len(p.results) == 0 {
			row_baseline := l.list.y + (l.row_height - title_text.line_height) / 2 + title_text.ascent
			if result := draw_text(&title_text, list, "No results", l.list.x + padding, row_baseline,
				theme.muted); result != .Ok {return result}
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
				if contains(row, pointer.x, pointer.y) {
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
				if p.edit.kind == .Shortcut && p.binding_result == index && p.binding.popup == .None {
					side = parts.positions.x
				}
				if result := palette_binding_draw(p, item.command, index, row, list, text, theme, l, pointer);
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
			icon_draw(list, PALETTE_KIND_ICONS[item.kind], kind_icon, theme.muted, ICON_BUTTON, scale)
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
	if l.bar_visible {scrollbar_draw(list, theme, l.bar, scrollbar_state(p.scroll_hover, p.scroll_drag))}
	if result := draw_footer(p, list, text, theme, l, scale); result != .Ok {return result}
	if p.edit.kind == .Shortcut {
		return popup_draw(&p.binding, palette_binding_layout(p, l), list, text, theme, pointer)
	}
	if result := draw_popup(p, list, text, theme, l); result != .Ok {return result}
	return draw_mode_menu(p, list, text, theme, l, scale)
}
