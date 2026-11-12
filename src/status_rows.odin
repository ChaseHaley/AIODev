package main

import "aio:render"
import "aio:settings"
import "aio:term"
import "aio:ui"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

// The rows the Activity panel and the status inbox share (WORK-406, WORK-412): reports in trees,
// grouped and ordered by status.group_by, named by status.row_name and described by status.row_terms.
// The two differ only in row heights and drawing.

// Label sizes in DIPs. A status label under a workspace label is shorter and has no gap above it.
@(private) STATUS_LABEL_HEIGHT :: f32(28)
@(private) STATUS_NESTED_LABEL_HEIGHT :: f32(24)
@(private) STATUS_GROUP_GAP :: f32(8)

// One report an overview may show and the pane it came from. The record's strings borrow from the
// session's snapshot, so items live for one frame or event at most.
Status_Item :: struct {
	session: u32,
	record:  term.Program_Status,
	pane:    Status_Pane,
}

// A report and how deep it sits under other reports shown from its pane.
Status_Report :: struct {
	item:  Status_Item,
	depth: int,
}

// One row of an overview as this frame or event lays it out: a report, or a label above reports.
// Drawing, hit testing and tooltips read the same rows, so they cannot disagree about where a row is.
// Rows borrow from the reports they were projected from.
Status_Row :: struct {
	item:      Status_Item,
	depth:     int,
	report:    bool,
	label:     string,
	// Labels count the report trees under them; zero shows no count.
	count:     int,
	attention: bool,
	// A status label under a workspace label.
	nested:    bool,
	y, height: f32,
}

// Report row heights in DIPs: a tree's first report, and reports under it.
Status_Row_Heights :: struct {
	root, child: f32,
}

// Ids in tree order: a report is followed by its descendants, whatever bytes their siblings hold.
status_id_less :: proc(a, b: term.Program_Status) -> bool {
	for i in 0 ..< min(len(a.id), len(b.id)) {
		if a.id[i] == b.id[i] {continue}
		if a.id[i] == '/' {return true}
		if b.id[i] == '/' {return false}
		return a.id[i] < b.id[i]
	}
	return len(a.id) < len(b.id)
}

@(private)
status_id_within :: proc(id, ancestor: string) -> bool {
	if ancestor == "" {return true}
	return len(id) > len(ancestor) && strings.has_prefix(id, ancestor) && id[len(ancestor)] == '/'
}

// Sorts one pane's shown records into tree order and appends them with their depth. Depth counts
// ancestors among these records, so a report whose parent is not shown is a root.
status_tree_append :: proc(
	reports: ^[dynamic]Status_Report,
	records: []term.Program_Status,
	session: u32,
	pane: Status_Pane,
) {
	slice.sort_by(records, status_id_less)
	ancestors := make([dynamic]string, 0, 8, context.temp_allocator)
	for record in records {
		for len(ancestors) > 0 && !status_id_within(record.id, ancestors[len(ancestors) - 1]) {
			pop(&ancestors)
		}
		item := Status_Item{session = session, record = record, pane = pane}
		append(reports, Status_Report{item, len(ancestors)})
		append(&ancestors, record.id)
	}
}

// Every shown report in the window's status scope, in trees, in workspace and pane order.
status_reports :: proc(app: ^App, w: ^Window) -> []Status_Report {
	reports := make([dynamic]Status_Report, context.temp_allocator)
	walk := status_scope_records(app, w)
	for shown, ok := status_scope_records_next(&walk); ok; shown, ok = status_scope_records_next(&walk) {
		status_tree_append(&reports, shown.records, shown.session, shown.pane)
	}
	return reports[:]
}

// Whether pane name `a` sorts before `b`: letters and digits compared without case, after any
// symbols a title starts with, such as the spinner Claude Code animates there.
status_pane_less :: proc(a, b: string) -> bool {
	key :: proc(s: string) -> string {
		for r, i in s {
			if unicode.is_letter(r) || unicode.is_digit(r) {return s[i:]}
		}
		return ""
	}
	x, y := key(a), key(b)
	for len(x) > 0 && len(y) > 0 {
		rx, nx := utf8.decode_rune_in_string(x)
		ry, ny := utf8.decode_rune_in_string(y)
		lx, ly := unicode.to_lower(rx), unicode.to_lower(ry)
		if lx != ly {return lx < ly}
		x, y = x[nx:], y[ny:]
	}
	return len(x) == 0 && len(y) > 0
}

// Lays reports out in groups. By status: Needs you, Working, Finished and Idle sections. By workspace:
// each workspace in the app's order, with those sections under it. A report keeps its children under
// it, and the tree takes the section of its most urgent report. Within a section trees sort by pane
// name, and keep pane order when names match. Labels count the trees under them.
status_rows_project :: proc(
	group: settings.Status_Group,
	reports: []Status_Report,
	heights: Status_Row_Heights,
	scale: f32,
) -> (
	rows: []Status_Row,
	total: f32,
) {
	if len(reports) == 0 {return}
	Tree :: struct {
		first, end: int,
		// Zero unless trees group by workspace, so the sort ignores workspaces otherwise.
		workspace:  int,
		section:    Status_Section,
		pane:       string,
	}
	trees := make([dynamic]Tree, 0, len(reports), context.temp_allocator)
	for first := 0; first < len(reports); {
		end := first + 1
		item := reports[first].item
		section := status_presentation(item.record).section
		for end < len(reports) && reports[end].depth > 0 {
			section = min(section, status_presentation(reports[end].item.record).section)
			end += 1
		}
		workspace := group == .Workspace ? item.pane.workspace_order : 0
		append(&trees, Tree{first, end, workspace, section, item.pane.title})
		first = end
	}
	slice.stable_sort_by(trees[:], proc(a, b: Tree) -> bool {
		if a.workspace != b.workspace {return a.workspace < b.workspace}
		if a.section != b.section {return a.section < b.section}
		return status_pane_less(a.pane, b.pane)
	})
	out := make([dynamic]Status_Row, 0, len(reports) + 16, context.temp_allocator)
	total = ui.SPACE_1 * scale
	label :: proc(out: ^[dynamic]Status_Row, row: Status_Row, total: ^f32, scale: f32) {
		row := row
		if len(out) > 0 && !row.nested {total^ += STATUS_GROUP_GAP * scale}
		row.y = total^
		row.height = (row.nested ? STATUS_NESTED_LABEL_HEIGHT : STATUS_LABEL_HEIGHT) * scale
		append(out, row)
		total^ += row.height
	}
	// Trees from `start` sharing tree `start`'s section, and its workspace when that groups them.
	run :: proc(trees: []Tree, start: int, by_workspace: bool) -> int {
		end := start + 1
		for end < len(trees) && trees[end].workspace == trees[start].workspace &&
		    (by_workspace || trees[end].section == trees[start].section) {
			end += 1
		}
		return end
	}
	for start := 0; start < len(trees); {
		end := len(trees)
		if group == .Workspace {
			end = run(trees[:], start, true)
			name := reports[trees[start].first].item.pane.workspace
			label(&out, {label = name, count = end - start}, &total, scale)
		}
		for inner := start; inner < end; {
			stop := run(trees[:end], inner, false)
			section := trees[inner].section
			heading := Status_Row {
				label     = status_section_names[section],
				count     = stop - inner,
				attention = section == .Needs_You,
				nested    = group == .Workspace,
			}
			label(&out, heading, &total, scale)
			for tree in trees[inner:stop] {
				for r in reports[tree.first:tree.end] {
					height := (r.depth > 0 ? heights.child : heights.root) * scale
					row := Status_Row{item = r.item, depth = r.depth, report = true, y = total, height = height}
					append(&out, row)
					total += height
				}
			}
			inner = stop
		}
		start = end
	}
	return out[:], total + ui.SPACE_1 * scale
}

// What a report's row is called. A subagent's report keeps its own title, else its program's name;
// every other report takes the term status.row_name picks, falling back to the report's own names and
// then the pane title when that term is empty.
status_report_name :: proc(s: ^settings.Status_Settings, item: Status_Item, depth: int) -> string {
	record := item.record
	if depth > 0 {
		if record.title != "" {return record.title}
		if record.app != "" {return record.app}
	}
	name: string
	switch s.row_name {
	case .Pane:
		name = item.pane.title
	case .Program:
		name = status_item_program(item)
	case .Tab:
		name = item.pane.tab
	case .Folder:
		name = item.pane.folder
	}
	if name != "" {return name}
	if record.title != "" {return record.title}
	if record.app != "" {return record.app}
	return item.pane.title
}

status_item_program :: proc(item: Status_Item) -> string {
	return item.record.app != "" ? item.record.app : item.pane.program
}

// What a row shows after its name: the terms status.row_terms picks, in Status_Row_Term order and
// joined by " · ". Empty terms, terms equal to the name and, while workspace labels already say it,
// the workspace are left out. The message falls back to the state's headline.
status_report_terms :: proc(s: ^settings.Status_Settings, item: Status_Item, name: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	buffer: [8]u8
	for term_kind in s.row_terms {
		text: string
		switch term_kind {
		case .Title:
			text = item.record.title
		case .Message:
			text = item.record.message
			if text == "" {text = status_headline(status_presentation(item.record).mark, buffer[:])}
		case .Pane:
			text = item.pane.title
		case .Program:
			text = status_item_program(item)
		case .Tab:
			text = item.pane.tab
		case .Workspace:
			if s.group_by != .Workspace {text = item.pane.workspace}
		case .Folder:
			text = item.pane.folder
		}
		if text == "" || text == name {continue}
		if strings.builder_len(b) > 0 {strings.write_string(&b, " · ")}
		strings.write_string(&b, text)
	}
	return strings.to_string(b)
}

// A label above reports: its text and, right-aligned, how many trees it holds. Labels over reports
// that need the user take the blocked colour; a status label under a workspace sits indented.
status_label_draw :: proc(app: ^App, w: ^Window, r: render.Rect, row: Status_Row) -> render.Build_Status {
	s := w.scale
	small := ui.text_styled(&w.ui_text, .Detail)
	ink := row.attention ? ui.status_color(app.theme, .Blocked) : app.theme.faint
	baseline := r.y + ui.SPACE_1 * s + (r.height - ui.SPACE_1 * s - small.line_height) / 2 + small.ascent
	indent := row.nested ? STATUS_PANEL_INDENT : 0
	x, right := r.x + (ui.CONTROL_INSET + indent) * s, r.x + r.width - ui.CONTROL_INSET * s
	if row.count > 0 {
		count := fmt.tprintf("%d", row.count)
		right -= ui.text_width(&small, count)
		if result := ui.draw_text(&small, &w.list, count, right, baseline, ink); result != .Ok {return result}
		right -= ui.SPACE_2 * s
	}
	return ui.draw_fading_text(&small, &w.list, row.label, x, baseline, ink, max(0, right - x))
}
