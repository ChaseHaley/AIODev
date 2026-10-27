package ui

import "aio:commands"
import "aio:fuzzy"
import "aio:glyphs"
import "aio:platform"
import "aio:render"
import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

@(private) PALETTE_MAX_ROWS :: 8
@(private) PALETTE_WIDTH :: 560
@(private) PALETTE_INPUT_HEIGHT :: 64
@(private) PALETTE_ROW_HEIGHT :: 42
@(private) PALETTE_HEADER_HEIGHT :: 22
@(private) PALETTE_FOOTER_HEIGHT :: 22
@(private) PALETTE_PADDING :: 8
@(private) PALETTE_RADIUS :: 10
@(private) PALETTE_TEXT_INSET :: 14
@(private) PALETTE_SETTING_SUFFIX :: " SETTING"
@(private) PALETTE_CHIP_HEIGHT :: 24
@(private) PALETTE_CHIP_TOP :: 28
@(private) PALETTE_CHIP_GAP :: 8
@(private) PALETTE_MENU_WIDTH :: 176
@(private) PALETTE_MENU_ROW :: 26
@(private) PALETTE_MENU_INSET :: 4
@(private) PALETTE_GLYPH_WIDTH :: 20
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
	Open_Tab,
	Open_Workspace,
}

// The kind a result belongs to. Every row states it, because a tab and a workspace can share a name.
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
	.All = {
		"All",
		"",
		"Search all, or t: w: s: c: · Tab cycles",
	},
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

// The fixed order for equal-ranked sections: the palette's original domains first.
@(private) PALETTE_SECTION_ORDER := [Palette_Kind]int {
	.Command = 0,
	.Setting = 1,
	.Tab = 2,
	.Workspace = 3,
}

@(private) PALETTE_SECTION_WORDS := [Palette_Kind]string {
	.Command = "COMMANDS",
	.Setting = "SETTINGS",
	.Tab = "TABS",
	.Workspace = "WORKSPACES",
}

@(private) PALETTE_KIND_WORDS := [Palette_Kind]string {
	.Command = "COMMAND",
	.Setting = "SETTING",
	.Tab = "TAB",
	.Workspace = "WORKSPACE",
}

// Identity never relies on colour: every row carries this shape plus its type word.
@(private) PALETTE_KIND_GLYPHS := [Palette_Kind]string {
	.Command = "»",
	.Setting = "⚙",
	.Tab = "▭",
	.Workspace = "▦",
}

@(private) PALETTE_CHIP_WIDTHS := [Palette_Mode]f32 {
	.All = 0,
	.Tabs = 88,
	.Workspaces = 132,
	.Settings = 114,
	.Commands = 122,
}

@(private) PALETTE_FOOTER_MODES := [?]Palette_Mode {
	.Tabs,
	.Workspaces,
	.Settings,
	.Commands,
}

// A setting the palette can open in the settings editor. The strings are static schema text.
Palette_Setting :: struct {
	key, title, group: string,
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
	// The setting key of the last Open_Setting outcome.
	chosen:    string,
	chosen_id: u64,
	scratch:   ^fuzzy.Scratch,
}

Palette_Layout :: struct {
	panel, input, list, footer, chip, menu: render.Rect,
	hints:                                  [len(PALETTE_FOOTER_MODES)]render.Rect,
	row_height, header_height:              f32,
	rows, headers:                          int,
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
	p.settings = settings
	p.visible_rows = PALETTE_MAX_ROWS
	p.menu_hover = -1
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
	free(p.scratch, p.query.bytes.allocator)
	delete(p.query.bytes)
	delete(p.results)
	delete(p.ordered)
	delete(p.positions)
	delete(p.haystack)
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
	p.chosen, p.chosen_id = "", 0
	refresh(p, registry)
}

palette_close :: proc(p: ^Palette) {
	presence_close(&p.presence)
	p.query.dragging = false
	p.mode_menu = false
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

// The faint context after the type word: a command category, a settings group, or a tab's workspace.
palette_result_context :: proc(p: ^Palette, r: Palette_Result) -> string {
	switch r.kind {
	case .Command:
		return r.command != nil ? command_category(r.command.name) : ""
	case .Setting:
		return r.setting >= 0 && r.setting < len(p.settings) ? p.settings[r.setting].group : ""
	case .Tab:
		return source_item(p.tabs, r.source).owner
	case .Workspace:
		return ""
	}
	return ""
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

// A section header belongs above the first result of a kind, and above index zero.
palette_section_header :: proc(p: ^Palette, index: int) -> bool {
	if p.mode != .All || index < 0 || index >= len(p.results) {return false}
	return index == 0 || p.results[index].kind != p.results[index - 1].kind
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
Section :: struct {
	kind: Palette_Kind,
	start, end, best: int,
}

@(private)
section_better :: proc(a, b: Section) -> bool {
	if a.best != b.best {return a.best < b.best}
	return PALETTE_SECTION_ORDER[a.kind] < PALETTE_SECTION_ORDER[b.kind]
}

@(private)
append_section :: proc(
	p: ^Palette,
	sections: ^[4]Section,
	count: ^int,
	kind: Palette_Kind,
	start: int,
) {
	end := len(p.ordered)
	if end == start {return}
	best := PALETTE_NO_RANK
	for result in p.ordered[start:end] {best = min(best, result.rank)}
	sections[count^] = {kind = kind, start = start, end = end, best = best}
	count^ += 1
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

// Rebuilds the visible result list for the active mode. An empty query lists each domain in
// natural order; otherwise label matches rank first, then secondary fields, and each section is
// sorted by match class and score with insertion order breaking ties.
@(private)
refresh :: proc(p: ^Palette, registry: ^commands.Registry) {
	query := palette_query(p)
	clear(&p.results)
	clear(&p.ordered)
	if !utf8.valid_string(query) {query = ""}
	empty := strings.trim_space(query) == ""
	width := empty ? 0 : utf8.rune_count(query)
	tabs := (p.mode == .All || p.mode == .Tabs) ? count_of(p.tabs) : 0
	workspaces := (p.mode == .All || p.mode == .Workspaces) ? count_of(p.workspaces) : 0
	enabled_commands := 0
	if p.mode == .All || p.mode == .Commands {
		for command in registry.items {if !command.disabled {enabled_commands += 1}}
	}
	setting_count := (p.mode == .All || p.mode == .Settings) ? len(p.settings) : 0
	candidates := tabs + workspaces + setting_count + enabled_commands
	if !empty && width > 0 {resize(&p.positions, candidates * width)}
	sections: [4]Section
	section_count := 0
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
		append_section(p, &sections, &section_count, .Tab, start)
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
		append_section(p, &sections, &section_count, .Workspace, start)
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
		append_section(p, &sections, &section_count, .Setting, start)
	}
	if p.mode == .All || p.mode == .Commands {
		start := len(p.ordered)
		for &command in registry.items {
			if command.disabled {continue}
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
		append_section(p, &sections, &section_count, .Command, start)
	}
	for section in sections[:section_count] {
		if !empty {
			slice.stable_sort_by(p.ordered[section.start:section.end], less_result)
		}
	}
	// Order sections by their best match class, then by the palette's original domain order.
	for i in 0 ..< section_count {
		best := i
		for j in i + 1 ..< section_count {
			if section_better(sections[j], sections[best]) {best = j}
		}
		if best != i {sections[i], sections[best] = sections[best], sections[i]}
	}
	if len(p.ordered) > 0 {
		_ = reserve(&p.results, len(p.ordered))
		for section in sections[:section_count] {
			append(&p.results, ..p.ordered[section.start:section.end])
		}
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

palette_selection :: proc(p: ^Palette) -> string {return field_selected_text(&p.query)}

palette_cut :: proc(p: ^Palette, registry: ^commands.Registry) -> Outcome {
	if palette_selection(p) == "" {return .None}
	return palette_text(p, registry, "")
}

@(private)
chip_rect :: proc(p: ^Palette, l: Palette_Layout, scale: f32) -> render.Rect {
	if p.mode == .All || l.input.width <= 0 {return {}}
	inset := PALETTE_TEXT_INSET * scale
	width := min(PALETTE_CHIP_WIDTHS[p.mode] * scale, max(0, l.input.width - 2 * inset))
	y := l.input.y + PALETTE_CHIP_TOP * scale
	height := min(PALETTE_CHIP_HEIGHT * scale, max(0, l.input.y + l.input.height - y))
	return {l.input.x + inset, y, width, height}
}

@(private)
row_header :: proc(p: ^Palette, index: int) -> bool {
	return p.mode == .All && palette_section_header(p, index)
}

@(private)
visible_extent :: proc(
	p: ^Palette,
	row_height, header_height, budget: f32,
) -> (
	rows, headers: int,
	used: f32,
) {
	for index := p.scroll; index < len(p.results) && rows < p.visible_rows; index += 1 {
		height := row_height
		if row_header(p, index) {height += header_height}
		if used + height > budget {break}
		used += height
		rows += 1
		if row_header(p, index) {headers += 1}
	}
	return
}

// Keeps the selection inside the measured pixel window, which shrinks when headers take rows.
@(private)
layout_keep_visible :: proc(p: ^Palette, row_height, header_height, budget: f32) {
	if len(p.results) == 0 {
		p.selected, p.scroll = 0, 0
		return
	}
	p.selected = clamp(p.selected, 0, len(p.results) - 1)
	p.scroll = clamp(p.scroll, 0, len(p.results) - 1)
	if p.selected < p.scroll {p.scroll = p.selected}
	rows, _, _ := visible_extent(p, row_height, header_height, budget)
	if rows == 0 || p.selected < p.scroll + rows {return}
	// Pull the window back so the selection ends at its bottom edge.
	start := p.selected
	used: f32
	for index := p.selected; index >= 0; index -= 1 {
		height := row_height
		if row_header(p, index) {height += header_height}
		if used + height > budget {break}
		used += height
		start = index
	}
	p.scroll = start
}

palette_layout :: proc(p: ^Palette, viewport_width, viewport_height, viewport_scale: f32) -> Palette_Layout {
	width, height := max(0, viewport_width), max(0, viewport_height)
	scale := viewport_scale > 0 ? viewport_scale : 1
	border := min(scale, width / 2, height / 2)
	panel_width := min(PALETTE_WIDTH * scale, width - 2 * min(16 * scale, width / 4))
	row_height := PALETTE_ROW_HEIGHT * scale
	header_height := PALETTE_HEADER_HEIGHT * scale
	padding := PALETTE_PADDING * scale
	footer_height := PALETTE_FOOTER_HEIGHT * scale
	input_height := PALETTE_INPUT_HEIGHT * scale
	full_height :=
		input_height +
		1 +
		2 * padding +
		PALETTE_MAX_ROWS * row_height +
		f32(len(Palette_Kind)) * header_height +
		footer_height
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
	// A last row matters more than the mouse hints on a very short client.
	if footer_height > 0 &&
	   remaining - 2 * padding - footer_height < row_height &&
	   remaining - 2 * padding >= row_height {
		footer_height = 0
	}
	// Section headers add height rather than replacing result rows, so all mode keeps the
	// eight-row cap; the panel's width and row metrics are unchanged.
	rows_space := max(0, remaining - 2 * padding - footer_height)
	p.visible_rows = clamp(int(rows_space / row_height), 0, PALETTE_MAX_ROWS)
	layout_keep_visible(p, row_height, header_height, rows_space)
	rows, headers, used := visible_extent(p, row_height, header_height, rows_space)
	if len(p.results) == 0 && p.visible_rows > 0 {
		rows, headers, used = 1, 0, row_height
	}
	list_padding := min(padding, panel_width / 2)
	panel := render.Rect {
		x      = (width - panel_width) / 2,
		y      = top,
		width  = panel_width,
		height = input_height + separator + padding + used + max(footer_height, padding),
	}
	list := render.Rect {
		panel.x + list_padding,
		panel.y + input_height + separator + padding,
		panel.width - 2 * list_padding,
		used,
	}
	footer := render.Rect {
		panel.x,
		list.y + list.height,
		panel.width,
		footer_height,
	}
	chip := chip_rect(p, {input = {panel.x, panel.y, panel.width, input_height}}, scale)
	l := Palette_Layout {
		panel         = panel,
		input         = {panel.x, panel.y, panel.width, input_height},
		list          = list,
		footer        = footer,
		chip          = chip,
		row_height    = row_height,
		header_height = header_height,
		rows          = rows,
		headers       = headers,
	}
	if footer.width > 0 && footer.height > 0 {
		segment := footer.width / len(PALETTE_FOOTER_MODES)
		for _, i in PALETTE_FOOTER_MODES {
			l.hints[i] = {footer.x + f32(i) * segment, footer.y, segment, footer.height}
		}
	}
	if p.mode_menu && chip.width > 0 {
		menu_width := min(PALETTE_MENU_WIDTH * scale, width - 2 * border)
		menu_height :=
			f32(len(PALETTE_MENU_ORDER) * PALETTE_MENU_ROW + 2 * PALETTE_MENU_INSET) * scale
		x := clamp(chip.x, border, max(border, width - menu_width - border))
		y := l.input.y + l.input.height + 4 * scale
		if y + menu_height > height - border {
			y = max(border, l.input.y - menu_height - 4 * scale)
		}
		y = clamp(y, border, max(border, height - menu_height - border))
		l.menu = {x, y, menu_width, menu_height}
	}
	return l
}

@(private)
row_at :: proc(p: ^Palette, l: Palette_Layout, x, y: f32) -> int {
	r := l.list
	if x < r.x || x >= r.x + r.width || y < r.y || y >= r.y + r.height {
		return -1
	}
	offset := y - r.y
	offset_y: f32
	rows := 0
	for index := p.scroll; index < len(p.results) && rows < l.rows; index += 1 {
		if row_header(p, index) {
			if offset >= offset_y && offset < offset_y + l.header_height {return -1}
			offset_y += l.header_height
		}
		if offset >= offset_y && offset < offset_y + l.row_height {return index}
		offset_y += l.row_height
		rows += 1
	}
	return -1
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

@(private)
hint_at :: proc(l: Palette_Layout, x, y: f32) -> (Palette_Mode, bool) {
	for hint, i in l.hints {
		if hint.width <= 0 || hint.height <= 0 {continue}
		if x >= hint.x && x < hint.x + hint.width && y >= hint.y && y < hint.y + hint.height {
			return PALETTE_FOOTER_MODES[i], true
		}
	}
	return .All, false
}

palette_mouse_move :: proc(p: ^Palette, l: Palette_Layout, x, y: f32) -> Outcome {
	if p.mode_menu {
		hover := menu_row_at(l, x, y)
		if hover == p.menu_hover {return .None}
		p.menu_hover = hover
		return .Changed
	}
	index := row_at(p, l, x, y)
	if index < 0 || index == p.selected {
		return .None
	}
	p.selected = index
	return .Changed
}

palette_mouse_press :: proc(
	p: ^Palette,
	registry: ^commands.Registry,
	l: Palette_Layout,
	x, y: f32,
) -> (
	Outcome,
	commands.Command_Id,
) {
	if p.mode_menu {
		if index := menu_row_at(l, x, y); index >= 0 {
			palette_set_mode(p, registry, PALETTE_MENU_ORDER[index])
		} else {
			p.mode_menu, p.menu_hover = false, -1
		}
		return .Changed, 0
	}
	if hint, found := hint_at(l, x, y); found {
		palette_set_mode(p, registry, hint)
		return .Changed, 0
	}
	if index := row_at(p, l, x, y); index >= 0 {
		return run(p, index)
	}
	r := l.panel
	if x < r.x || x >= r.x + r.width || y < r.y || y >= r.y + r.height {
		palette_close(p)
		return .Closed, 0
	}
	return .None, 0
}

// The query field's box: the input row's width, with the label sharing its height above.
palette_query_box :: proc(p: ^Palette, l: Palette_Layout, text: ^Text, scale: f32) -> Field_Box {
	box := Field_Box {
		field = &p.query,
		text = text,
		rect = l.input,
		inset = PALETTE_TEXT_INSET,
		caret_width = 1.5,
		radius = 0,
		style = .Input,
		scale = scale,
	}
	if p.mode != .All && l.chip.width > 0 {
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

// Places the caret, or with `extend` grows the selection, and starts a drag selection.
palette_input_press :: proc(
	p: ^Palette,
	l: Palette_Layout,
	text: ^Text,
	x, y, scale: f32,
	extend: bool,
) -> Outcome {
	if p.mode != .All && contains(l.chip, x, y) {
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
	if p.mode_menu {
		p.mode_menu, p.menu_hover = false, -1
		return .Changed
	}
	if p.visible_rows == 0 || len(p.results) == 0 { return .None }
	limit := max(0, len(p.results) - p.visible_rows)
	scroll := clamp(p.scroll - rows, 0, limit)
	if scroll == p.scroll {
		return .None
	}
	p.scroll = scroll
	p.selected = clamp(p.selected, p.scroll, min(len(p.results), p.scroll + p.visible_rows) - 1)
	return .Changed
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
	hint_text := text_styled(text, .Keycap)
	buffer: [64]u8
	for hint, i in l.hints {
		if hint.width <= 0 {continue}
		mode := PALETTE_FOOTER_MODES[i]
		info := PALETTE_MODES[mode]
		label := fmt.bprintf(buffer[:], "%s %s", info.prefix, info.word)
		baseline := hint.y + (hint.height - hint_text.line_height) / 2 + hint_text.ascent
		color := p.mode == mode ? theme.text : theme.faint
		if result := draw_text(&hint_text, list, label, hint.x + 10 * scale, baseline, color,
			max(0, hint.width - 20 * scale)); result != .Ok {return result}
	}
	return .Ok
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
	draw_rect(list, {rect = l.menu, color = theme.pane, radius = 7 * scale})
	draw_rect(list, {
		rect   = l.menu,
		color  = theme.border,
		radius = 7 * scale,
		stroke = scale,
	})
	inset := PALETTE_MENU_INSET * scale
	row_height := (l.menu.height - 2 * inset) / f32(len(PALETTE_MENU_ORDER))
	mode_text := text_styled(text, .Small)
	for mode, i in PALETTE_MENU_ORDER {
		row := render.Rect {
			l.menu.x + 3 * scale,
			l.menu.y + inset + f32(i) * row_height,
			l.menu.width - 6 * scale,
			row_height,
		}
		if p.mode == mode {
			draw_rect(list, {rect = row, color = theme.selection, radius = 4 * scale})
		} else if p.menu_hover == i {
			draw_rect(list, {rect = row, color = theme.hover, radius = 4 * scale})
		}
		info := PALETTE_MODES[mode]
		baseline := row.y + (row.height - mode_text.line_height) / 2 + mode_text.ascent
		if result := draw_text(&mode_text, list, info.word, row.x + 9 * scale, baseline,
			p.mode == mode ? theme.text : theme.muted); result != .Ok {return result}
		if info.prefix != "" {
			prefix_text := text_styled(text, .Keycap)
			width := text_width(&prefix_text, info.prefix)
			if result := draw_text(&prefix_text, list, info.prefix,
				row.x + row.width - width - 9 * scale, baseline, theme.faint); result != .Ok {
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
	frame := Panel {
		rect     = panel,
		radius   = PALETTE_RADIUS * scale,
		scale    = scale,
		shadow_y = 12,
		softness = 32,
		border   = .Expanded,
	}
	if panel_draw(list, frame, theme) != .None {return .Ok}
	draw_rect(list, {
		rect  = {panel.x, l.input.y + l.input.height, panel.width, scale},
		color = theme.border,
	})
	if render.push_layer(list, l.input) != .None { return .Ok }
	padding := PALETTE_TEXT_INSET * scale
	label_text := text_styled(text, .Label)
	if l.input.width > 2 * padding {
		label_x, label_y := l.input.x + padding, l.input.y + 19 * scale
		if result := draw_text(&label_text, list, "COMMAND PALETTE", label_x, label_y,
			theme.faint); result != .Ok { return result }
		if l.chip.width > 0 {
			chip := l.chip
			draw_rect(list, {rect = chip, color = theme.selection, radius = 5 * scale})
			draw_rect(list, {
				rect   = chip,
				color  = theme.border,
				radius = 5 * scale,
				stroke = scale,
			})
			chip_text := text_styled(text, .Small)
			baseline := chip.y + (chip.height - chip_text.line_height) / 2 + chip_text.ascent
			info := PALETTE_MODES[p.mode]
			prefix_width := text_width(&chip_text, info.prefix)
			if result := draw_text(&chip_text, list, info.prefix, chip.x + 7 * scale, baseline,
				theme.accent); result != .Ok {return result}
			word_x := chip.x + 12 * scale + prefix_width
			word_width := max(0, chip.x + chip.width - word_x - 16 * scale)
			if result := draw_text(&chip_text, list, info.word, word_x, baseline, theme.text,
				word_width); result != .Ok {return result}
			// A two-pixel chevron reads as a menu affordance without relying on a font glyph.
			center_x := chip.x + chip.width - 9 * scale
			center_y := chip.y + chip.height / 2 - 2 * scale
			for row in 0 ..< 3 {
				for direction in ([?]f32{-1, 1}) {
					draw_rect(list, {
						rect = {
							center_x + direction * f32(row) * scale - scale,
							center_y + f32(2 - row) * scale,
							2 * scale,
							2 * scale,
						},
						color  = theme.muted,
						radius = 0.8 * scale,
					})
				}
			}
		}
		box := palette_query_box(p, l, text, scale)
		input_text := text_styled(text, .Input)
		baseline := l.input.y + 43 * scale
		if l.chip.height > 0 {
			baseline = l.chip.y + (l.chip.height - input_text.line_height) / 2 + input_text.ascent
		}
		if box.rect.width > 1 {
			if result := field_box_draw(box, list, theme, baseline, true,
				PALETTE_MODES[p.mode].placeholder); result != .Ok { return result }
		}
	}
	if l.rows > 0 && l.list.width > 0 {
		if render.push_layer(list, l.list) != .None { return .Ok }
		if len(p.results) == 0 {
			row_baseline := l.list.y + (l.row_height - text.line_height) / 2 + text.ascent
			if result := draw_text(
				text,
				list,
				"No matching tabs, workspaces, settings or commands",
				l.list.x + padding,
				row_baseline,
				theme.muted,
			); result != .Ok {return result}
		}
	}
	if len(p.results) > 0 && l.rows > 0 && l.list.width > 0 {
		label_buffer: [commands.SHORTCUT_TEXT_CAP]u8
		type_buffer: [160]u8
		y := l.list.y
		rows := 0
		for index := p.scroll; index < len(p.results) && rows < l.rows; index += 1 {
			item := p.results[index]
			if row_header(p, index) {
				header := text_styled(text, .Label)
				baseline := y + (l.header_height - header.line_height) / 2 + header.ascent
				label := PALETTE_SECTION_WORDS[item.kind]
				if result := draw_text(&header, list, label, l.list.x + padding, baseline,
					theme.faint); result != .Ok {return result}
				line_x := l.list.x + padding + text_width(&header, label) + 8 * scale
				draw_rect(list, {
					rect  = {line_x, y + l.header_height / 2, max(0, l.list.x + l.list.width - line_x),
						scale},
					color = theme.border,
				})
				y += l.header_height
			}
			row := render.Rect {
				l.list.x,
				y,
				l.list.width,
				l.row_height,
			}
			if index == p.selected {
				draw_rect(list, {rect = row, color = theme.selection, radius = 6 * scale})
				if contains(row, pointer.x, pointer.y) {
					// The row carries the selection tint, not the paper fill, so no hairline.
					if result := hover_rim_draw(list, theme, row, 6 * scale, 1, scale, pointer, false);
					   result != .None {return .Ok}
				}
			}
			row_baseline := row.y + 31 * scale
			shortcut_label: string
			label_width: f32
			key_text: Text
			if item.command != nil {
				if shortcuts := commands.active_shortcuts(item.command); len(shortcuts) > 0 {
					shortcut_label = commands.shortcut_text(shortcuts[0], label_buffer[:])
					key_text = text_styled(text, .Keycap)
					label_width = text_width(&key_text, shortcut_label) + 12 * scale
				}
			}
			detail := palette_result_context(p, item)
			type_x := row.x + padding + PALETTE_GLYPH_WIDTH * scale
			type_width := max(
				0,
				row.width - 2 * padding - PALETTE_GLYPH_WIDTH * scale - label_width - 8 * scale,
			)
			type_label := PALETTE_KIND_WORDS[item.kind]
			if detail != "" {
				type_label = fmt.bprintf(
					type_buffer[:],
					"%s · %s",
					type_label,
					strings.to_upper(detail, context.temp_allocator),
				)
			}
			if result := draw_text(&label_text, list, type_label, type_x, row.y + 13 * scale,
				theme.faint, type_width); result != .Ok {return result}
			glyph_text := text_styled(text, .Small)
			if result := draw_text(&glyph_text, list, PALETTE_KIND_GLYPHS[item.kind],
				row.x + padding, row_baseline, theme.muted); result != .Ok {return result}
			if shortcut_label != "" {
				x := row.x + row.width - padding - label_width
				draw_rect(
					list,
					{
						rect = {
							x - 4 * scale,
							row.y + 7 * scale,
							label_width + 4 * scale,
							row.height - 14 * scale,
						},
						color  = theme.border,
						radius = 4 * scale,
						stroke = scale,
					},
				)
				if result := draw_text(
					&key_text,
					list,
					shortcut_label,
					x + 2 * scale,
					row_baseline,
					theme.muted,
				); result != .Ok {return result}
			}
			title_x := row.x + padding + PALETTE_GLYPH_WIDTH * scale
			title_width := row.width - 2 * padding - PALETTE_GLYPH_WIDTH * scale - label_width - 16 * scale
			result := draw_text(
				text,
				list,
				palette_result_title(p, item),
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
			y += l.row_height
			rows += 1
		}
	}
	if result := draw_footer(p, list, text, theme, l, scale); result != .Ok {return result}
	return draw_mode_menu(p, list, text, theme, l, scale)
}
