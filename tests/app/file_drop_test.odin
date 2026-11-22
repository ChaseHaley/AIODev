package app_test

import "aio:layout"
import "cosmos:platform"
import "aio:ui"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import app "../../src"

// What a file dragged in from Explorer shows and opens: the pane header drag's drop outline at the place the
// pointer picks, and there a Markdown file in a Markdown pane, a folder in a shell, any other file in Neovim
// in a new terminal pane.

@(private = "file")
Drop_Fixture :: struct {
	palette: Palette_Fixture,
	root:    string,
	// PATH before the test changed it, restored by drop_fixture_destroy.
	path:    string,
}

@(private = "file", require_results)
drop_fixture_create :: proc(t: ^testing.T, f: ^Drop_Fixture, name: string) -> bool {
	if !palette_fixture_create(t, &f.palette, name, false) {return false}
	root, err := os.make_directory_temp("", "aio-file-drop-*", context.allocator)
	if !testing.expect_value(t, err, nil) {return false}
	f.root = root
	f.path = os.get_env("PATH", context.allocator)
	return true
}

@(private = "file")
drop_fixture_destroy :: proc(t: ^testing.T, f: ^Drop_Fixture) {
	if f.path != "" {
		testing.expect_value(t, os.set_env("PATH", f.path), nil)
		delete(f.path)
	}
	palette_fixture_destroy(t, &f.palette)
	if f.root != "" {
		testing.expect_value(t, os.remove_all(f.root), nil)
		delete(f.root)
	}
}

// Puts a program named nvim ahead of the real one on PATH: the idle shell, a live child that needs no
// interpreter. An empty directory instead leaves no nvim to find.
@(private = "file", require_results)
drop_path_with_nvim :: proc(t: ^testing.T, f: ^Drop_Fixture, present: bool) -> bool {
	bin := fmt.tprintf(`%s\bin`, f.root)
	if !testing.expect_value(t, os.make_directory(bin), nil) {return false}
	if present {
		directory, dir_error := os.get_executable_directory(context.temp_allocator)
		if !testing.expect_value(t, dir_error, nil) {return false}
		shell, read_error := os.read_entire_file(fmt.tprintf("%s/idle-shell.exe", directory), context.allocator)
		if !testing.expect_value(t, read_error, nil) {return false}
		defer delete(shell)
		if !testing.expect_value(t, os.write_entire_file(fmt.tprintf(`%s\nvim.exe`, bin), shell), nil) {return false}
	}
	return testing.expect_value(t, os.set_env("PATH", bin), nil)
}

@(private = "file", require_results)
drop_file :: proc(t: ^testing.T, f: ^Drop_Fixture, name: string) -> (string, bool) {
	path := fmt.tprintf(`%s\%s`, f.root, name)
	return path, testing.expect_value(t, os.write_entire_file(path, transmute([]u8)string("# x\n")), nil)
}

@(private = "file")
drop :: proc(s: ^app.App, w: ^app.Window, at: [2]f32, paths: ..string) {
	joined := strings.join(paths, "\n", context.temp_allocator)
	app.handle_event(s, platform.Files_Drop_Event{w.id, i32(at.x), i32(at.y), joined})
}

@(private = "file")
drag :: proc(s: ^app.App, w: ^app.Window, phase: platform.Files_Drag_Phase, at: [2]f32 = {}) {
	app.handle_event(s, platform.Files_Drag_Event{w.id, phase, i32(at.x), i32(at.y)})
}

@(private = "file")
Side :: enum {
	Left,
	Right,
	Up,
	Down,
}

// A point in `rect` nearest its `side`, away from the window's edge bands and the corners.
@(private = "file")
zone :: proc(rect: layout.Rect, side: Side) -> [2]f32 {
	x, y := rect.x + rect.width / 2, rect.y + rect.height / 2
	switch side {
	case .Left:
		x = rect.x + rect.width * 0.2
	case .Right:
		x = rect.x + rect.width * 0.8
	case .Up:
		y = rect.y + rect.height * 0.2
	case .Down:
		y = rect.y + rect.height * 0.8
	}
	return {x, y}
}

// The window's tiled panes left to right, then top to bottom.
@(private = "file")
panes_in_order :: proc(w: ^app.Window) -> []layout.Pane_Rect {
	panes := slice.clone(w.panes[:], context.temp_allocator)
	slice.sort_by(panes, proc(a, b: layout.Pane_Rect) -> bool {
		return a.rect.x != b.rect.x ? a.rect.x < b.rect.x : a.rect.y < b.rect.y
	})
	return panes
}

@(private = "file")
kinds_in_order :: proc(w: ^app.Window) -> []layout.Content_Kind {
	panes := panes_in_order(w)
	kinds := make([]layout.Content_Kind, len(panes), context.temp_allocator)
	for pane, i in panes {kinds[i] = pane.content.kind}
	return kinds
}

@(private = "file")
rect_of :: proc(w: ^app.Window, content: layout.Content) -> layout.Rect {
	for pane in w.panes {if pane.content == content {return pane.rect}}
	return {}
}

@(private = "file")
close_to :: proc(a, b: f32) -> bool {
	return abs(a - b) < 1.5
}

@(private = "file")
last_notice :: proc(s: ^app.App) -> string {
	return len(s.notices.items) == 0 ? "" : s.notices.items[len(s.notices.items) - 1].text
}

// Two terminals side by side, as the pane drop tests start; the left one is returned first.
@(private = "file", require_results)
drop_two_panes :: proc(t: ^testing.T, f: ^Drop_Fixture) -> (left, right: layout.Pane_Rect, ok: bool) {
	s, w := &f.palette.state, f.palette.state.windows[0]
	app.pane_split(s, w, .Right)
	if !testing.expect_value(t, len(w.panes), 2) {return}
	panes := panes_in_order(w)
	return panes[0], panes[1], true
}

@(test)
dropped_markdown_opens_where_the_drop_outline_shows :: proc(t: ^testing.T) {
	f: Drop_Fixture
	defer drop_fixture_destroy(t, &f)
	if !drop_fixture_create(t, &f, "file-drop-sides") {return}
	s, w := &f.palette.state, f.palette.state.windows[0]
	left, right, ready := drop_two_panes(t, &f)
	if !ready {return}
	doc, made := drop_file(t, &f, "doc.md")
	if !made {return}
	above, made_above := drop_file(t, &f, "above.md")
	if !made_above {return}

	// The right zone of the left pane puts it between the two terminals.
	drop(s, w, zone(left.rect, .Right), doc)
	if !testing.expect_value(t, len(s.markdown_panes), 1) {return}
	testing.expect_value(t, s.markdown_panes[0].title, "doc.md")
	kinds := kinds_in_order(w)
	if !testing.expect_value(t, len(kinds), 3) {return}
	testing.expect_value(t, kinds[0], layout.Content_Kind.Terminal)
	testing.expect_value(t, kinds[1], layout.Content_Kind.Markdown)
	testing.expect_value(t, kinds[2], layout.Content_Kind.Terminal)

	// The top zone of the right pane puts it above that pane, in the same column.
	right_now := rect_of(w, right.content)
	drop(s, w, zone(right_now, .Up), above)
	if !testing.expect_value(t, len(s.markdown_panes), 2) {return}
	shown := rect_of(w, {.Markdown, s.markdown_panes[1].id})
	after := rect_of(w, right.content)
	testing.expect(t, close_to(shown.x, after.x) && close_to(shown.width, after.width), "same column")
	testing.expect(t, shown.y < after.y, "above the pane it was dropped on")
}

@(test)
a_drag_over_a_pane_shows_the_header_drag_outline_and_leaving_clears_it :: proc(t: ^testing.T) {
	f: Drop_Fixture
	defer drop_fixture_destroy(t, &f)
	if !drop_fixture_create(t, &f, "file-drop-outline") {return}
	s, w := &f.palette.state, f.palette.state.windows[0]
	left, _, ready := drop_two_panes(t, &f)
	if !ready {return}
	sessions := len(s.sessions)

	drag(s, w, .Enter, zone(left.rect, .Left))
	files, dragging := &w.file_drag.(app.File_Drag)
	if !testing.expect(t, dragging, "the drag shows") {return}
	shown, placed := files.carry.destination.(app.Pane_Drop)
	if !testing.expect(t, placed) {return}
	testing.expect_value(t, shown.place, app.Pane_Place.Beside)
	testing.expect_value(t, shown.direction, layout.Direction.Left)
	testing.expect_value(t, shown.target, left.node)
	testing.expect_value(t, shown.fit, app.Drop_Fit.Fits)
	// The outline is the half of the pane the new one would take, as a header drag's is.
	testing.expect(t, close_to(files.carry.ghost[0].target, left.rect.x), "starts at the pane's left edge")
	testing.expect(t, abs(files.carry.ghost[2].target - left.rect.width / 2) < 5, "takes half its width, less the gap")
	testing.expect(t, close_to(files.carry.ghost[3].target, left.rect.height), "takes its height")

	// Moving to the bottom zone moves the outline there.
	drag(s, w, .Over, zone(left.rect, .Down))
	shown = w.file_drag.(app.File_Drag).carry.destination.(app.Pane_Drop)
	testing.expect_value(t, shown.direction, layout.Direction.Down)

	// Leaving puts everything back: no pane, session or tab was made.
	drag(s, w, .Leave)
	_, dragging = w.file_drag.(app.File_Drag)
	testing.expect(t, !dragging, "the drag is gone")
	testing.expect_value(t, len(w.panes), 2)
	testing.expect_value(t, len(s.sessions), sessions)
	testing.expect_value(t, len(s.markdown_panes), 0)
}

@(test)
a_drop_on_a_window_edge_docks_along_that_edge :: proc(t: ^testing.T) {
	f: Drop_Fixture
	defer drop_fixture_destroy(t, &f)
	if !drop_fixture_create(t, &f, "file-drop-edge") {return}
	s, w := &f.palette.state, f.palette.state.windows[0]
	left, right, ready := drop_two_panes(t, &f)
	if !ready {return}
	doc, made := drop_file(t, &f, "doc.md")
	if !made {return}
	// The band along the content area's left edge, midway down.
	point := [2]f32{left.rect.x + 2, left.rect.y + left.rect.height / 2}
	drag(s, w, .Enter, point)
	shown, placed := w.file_drag.(app.File_Drag).carry.destination.(app.Pane_Drop)
	if !testing.expect(t, placed) {return}
	testing.expect_value(t, shown.place, app.Pane_Place.Edge)
	testing.expect_value(t, shown.direction, layout.Direction.Left)
	drop(s, w, point, doc)
	_, dragging := w.file_drag.(app.File_Drag)
	testing.expect(t, !dragging, "the drop ends the drag")
	if !testing.expect_value(t, len(s.markdown_panes), 1) {return}
	// The viewer is the whole left edge, as tall as the two terminals together would be.
	viewer := rect_of(w, {.Markdown, s.markdown_panes[0].id})
	testing.expect(t, viewer.x < rect_of(w, left.content).x, "left of both terminals")
	testing.expect(t, close_to(viewer.height, rect_of(w, right.content).height), "full height")
}

@(test)
a_drop_on_chrome_opens_beside_the_focused_pane :: proc(t: ^testing.T) {
	f: Drop_Fixture
	defer drop_fixture_destroy(t, &f)
	if !drop_fixture_create(t, &f, "file-drop-chrome") {return}
	s, w := &f.palette.state, f.palette.state.windows[0]
	_, _, ready := drop_two_panes(t, &f)
	if !ready {return}
	doc, made := drop_file(t, &f, "doc.md")
	if !made {return}
	// The new pane is focused and rightmost; the point is above every pane, on no tab.
	drag(s, w, .Enter, {2, 2})
	shown, placed := w.file_drag.(app.File_Drag).carry.destination.(app.Pane_Drop)
	if !testing.expect(t, placed) {return}
	testing.expect_value(t, shown.direction, layout.Direction.Right)
	testing.expect_value(t, shown.fit, app.Drop_Fit.Fits)
	drop(s, w, {2, 2}, doc)
	kinds := kinds_in_order(w)
	if !testing.expect_value(t, len(kinds), 3) {return}
	testing.expect_value(t, kinds[2], layout.Content_Kind.Markdown)
}

@(test)
several_files_open_beside_the_one_before_in_the_order_dropped :: proc(t: ^testing.T) {
	f: Drop_Fixture
	defer drop_fixture_destroy(t, &f)
	if !drop_fixture_create(t, &f, "file-drop-chain") {return}
	s, w := &f.palette.state, f.palette.state.windows[0]
	pane := w.panes[0]
	first, made := drop_file(t, &f, "a.md")
	if !made {return}
	second, made_second := drop_file(t, &f, "b.md")
	if !made_second {return}
	// On the left zone the first lands left of the pane and the next to its right, so they read a, b.
	drop(s, w, zone(pane.rect, .Left), first, second)
	if !testing.expect_value(t, len(s.markdown_panes), 2) {return}
	titles := make([dynamic]string, context.temp_allocator)
	for shown in panes_in_order(w) {
		if shown.content.kind != .Markdown {continue}
		for markdown in s.markdown_panes {if markdown.id == shown.content.id {append(&titles, markdown.title)}}
	}
	testing.expect_value(t, strings.join(titles[:], ","), "a.md,b.md")
	testing.expect_value(t, kinds_in_order(w)[2], layout.Content_Kind.Terminal)
}

@(test)
files_dropped_above_a_pane_read_downward :: proc(t: ^testing.T) {
	f: Drop_Fixture
	defer drop_fixture_destroy(t, &f)
	if !drop_fixture_create(t, &f, "file-drop-column") {return}
	s, w := &f.palette.state, f.palette.state.windows[0]
	left, _, ready := drop_two_panes(t, &f)
	if !ready {return}
	first, made := drop_file(t, &f, "a.md")
	if !made {return}
	second, made_second := drop_file(t, &f, "b.md")
	if !made_second {return}
	drop(s, w, zone(left.rect, .Up), first, second)
	if !testing.expect_value(t, len(s.markdown_panes), 2) {return}
	top := rect_of(w, {.Markdown, s.markdown_panes[0].id})
	middle := rect_of(w, {.Markdown, s.markdown_panes[1].id})
	bottom := rect_of(w, left.content)
	testing.expect(t, top.y < middle.y && middle.y < bottom.y, "a above b above the pane")
}

@(test)
a_drop_on_the_new_tab_zone_opens_a_new_tab :: proc(t: ^testing.T) {
	f: Drop_Fixture
	defer drop_fixture_destroy(t, &f)
	if !drop_fixture_create(t, &f, "file-drop-new-tab") {return}
	s, w := &f.palette.state, f.palette.state.windows[0]
	doc, made := drop_file(t, &f, "doc.md")
	if !made {return}
	region := ui.tab_drop_region(app.window_tab_bar(s, w), f32(w.width), w.scale)
	point := [2]f32{region.x + region.width / 2, region.y + region.height / 2}
	drag(s, w, .Enter, point)
	shown, placed := w.file_drag.(app.File_Drag).carry.destination.(app.Pane_Drop)
	if !testing.expect(t, placed) {return}
	testing.expect_value(t, shown.place, app.Pane_Place.New_Tab)
	tabs := len(w.workspace.tabs)
	drop(s, w, point, doc)
	testing.expect_value(t, len(w.workspace.tabs), tabs + 1)
	testing.expect_value(t, w.workspace.selected, tabs)
	testing.expect_value(t, len(s.markdown_panes), 1)
}

@(test)
resting_over_a_tab_shows_it_and_leaving_shows_the_first_again :: proc(t: ^testing.T) {
	f: Drop_Fixture
	defer drop_fixture_destroy(t, &f)
	if !drop_fixture_create(t, &f, "file-drop-tab-rest") {return}
	s, w := &f.palette.state, f.palette.state.windows[0]
	if _, created := app.tab_create(s, w.workspace); !testing.expect(t, created) {return}
	app.tab_select(s, w, 0)
	other := app.window_tab_rect(s, w, 1)
	point := [2]f32{other.x + other.width / 2, other.y + other.height / 2}
	drag(s, w, .Enter, point)
	shown, placed := w.file_drag.(app.File_Drag).carry.destination.(app.Pane_Drop)
	if !testing.expect(t, placed) {return}
	testing.expect(t, shown.tab == w.workspace.tabs[1], "the outline is for the tab under the pointer")
	testing.expect_value(t, w.workspace.selected, 0)
	// A rest of long enough shows the tab.
	time.sleep(400 * time.Millisecond)
	app.files_drag_tick(s, w, app.clock_now(&s.clock))
	testing.expect_value(t, w.workspace.selected, 1)
	// Leaving puts the first tab back, and a repeated leave changes nothing.
	drag(s, w, .Leave)
	testing.expect_value(t, w.workspace.selected, 0)
	drag(s, w, .Leave)
	testing.expect_value(t, w.workspace.selected, 0)
}

@(test)
dropped_files_open_in_neovim_in_their_folder :: proc(t: ^testing.T) {
	sync.mutex_lock(&Link_Test_Lock)
	defer sync.mutex_unlock(&Link_Test_Lock)
	f: Drop_Fixture
	defer drop_fixture_destroy(t, &f)
	if !drop_fixture_create(t, &f, "file-drop-nvim") {return}
	if !drop_path_with_nvim(t, &f, true) {return}
	s, w := &f.palette.state, f.palette.state.windows[0]
	notes, made := drop_file(t, &f, "notes.txt")
	if !made {return}
	before := len(s.sessions)
	notices := len(s.notices.items)
	pane := w.panes[0]
	drop(s, w, zone(pane.rect, .Right), notes)
	if !testing.expect_value(t, len(s.sessions), before + 1) {return}
	opened := &s.sessions[len(s.sessions) - 1]
	// The program is named by the path found for it, then the file, as a link program's line is.
	command := opened.header.command
	testing.expect(t, strings.has_prefix(command, `"`), command)
	testing.expect(t, strings.has_suffix(command, fmt.tprintf(`\bin\nvim.exe" %s`, notes)), command)
	testing.expect(t, strings.equal_fold(opened.header.launch_directory, f.root), opened.header.launch_directory)
	kinds := kinds_in_order(w)
	if !testing.expect_value(t, len(kinds), 2) {return}
	testing.expect_value(t, len(s.notices.items), notices)
}

@(test)
dropped_files_without_neovim_report_it_once_and_markdown_still_opens :: proc(t: ^testing.T) {
	sync.mutex_lock(&Link_Test_Lock)
	defer sync.mutex_unlock(&Link_Test_Lock)
	f: Drop_Fixture
	defer drop_fixture_destroy(t, &f)
	if !drop_fixture_create(t, &f, "file-drop-no-nvim") {return}
	if !drop_path_with_nvim(t, &f, false) {return}
	s, w := &f.palette.state, f.palette.state.windows[0]
	first, made := drop_file(t, &f, "one.txt")
	if !made {return}
	second, made_second := drop_file(t, &f, "two.log")
	if !made_second {return}
	doc, made_doc := drop_file(t, &f, "doc.md")
	if !made_doc {return}
	before := len(s.sessions)
	notices := len(s.notices.items)
	drop(s, w, zone(w.panes[0].rect, .Right), first, second, doc)
	testing.expect_value(t, len(s.sessions), before)
	testing.expect_value(t, len(s.markdown_panes), 1)
	testing.expect_value(t, len(s.notices.items), notices + 1)
	testing.expect_value(
		t,
		last_notice(s),
		"nvim is not on PATH, so only Markdown files and folders open from a drop.",
	)
}

@(test)
a_dropped_folder_opens_a_shell_in_it :: proc(t: ^testing.T) {
	f: Drop_Fixture
	defer drop_fixture_destroy(t, &f)
	if !drop_fixture_create(t, &f, "file-drop-folder") {return}
	s, w := &f.palette.state, f.palette.state.windows[0]
	before := len(s.sessions)
	drop(s, w, zone(w.panes[0].rect, .Right), f.root)
	if !testing.expect_value(t, len(s.sessions), before + 1) {return}
	opened := &s.sessions[len(s.sessions) - 1]
	testing.expect(t, strings.equal_fold(opened.header.launch_directory, f.root), opened.header.launch_directory)
}

@(test)
a_drop_opens_at_most_eight_files_and_says_so :: proc(t: ^testing.T) {
	f: Drop_Fixture
	defer drop_fixture_destroy(t, &f)
	if !drop_fixture_create(t, &f, "file-drop-limit") {return}
	s, w := &f.palette.state, f.palette.state.windows[0]
	paths := make([]string, 10, context.temp_allocator)
	for i in 0 ..< len(paths) {
		made: bool
		if paths[i], made = drop_file(t, &f, fmt.tprintf("doc%d.md", i)); !made {return}
	}
	drop(s, w, zone(w.panes[0].rect, .Right), ..paths)
	testing.expect_value(t, s.settings.pane.drop_limit, 8)
	testing.expect_value(t, len(s.markdown_panes), 8)
	testing.expect_value(t, last_notice(s), "Opened the first 8 of 10 dropped files.")
}

@(test)
a_dropped_path_that_is_not_there_is_reported :: proc(t: ^testing.T) {
	f: Drop_Fixture
	defer drop_fixture_destroy(t, &f)
	if !drop_fixture_create(t, &f, "file-drop-missing") {return}
	s, w := &f.palette.state, f.palette.state.windows[0]
	before := len(s.sessions)
	notices := len(s.notices.items)
	drop(s, w, zone(w.panes[0].rect, .Right), fmt.tprintf(`%s\gone.txt`, f.root), `\\server\share\remote.md`)
	testing.expect_value(t, len(s.sessions), before)
	testing.expect_value(t, len(s.markdown_panes), 0)
	testing.expect_value(t, len(s.notices.items), notices + 1)
	testing.expect_value(t, last_notice(s), "That local file is not available.")
}

@(test)
the_drop_limit_is_a_setting :: proc(t: ^testing.T) {
	f: Drop_Fixture
	defer drop_fixture_destroy(t, &f)
	if !drop_fixture_create(t, &f, "file-drop-limit-setting") {return}
	s, w := &f.palette.state, f.palette.state.windows[0]
	if !drop_settings(t, &f, "pane.drop_limit = 3\n") {return}
	testing.expect_value(t, s.settings.pane.drop_limit, 3)
	paths := make([]string, 5, context.temp_allocator)
	for i in 0 ..< len(paths) {
		made: bool
		if paths[i], made = drop_file(t, &f, fmt.tprintf("doc%d.md", i)); !made {return}
	}
	drop(s, w, zone(w.panes[0].rect, .Right), ..paths)
	testing.expect_value(t, len(s.markdown_panes), 3)
	testing.expect_value(t, last_notice(s), "Opened the first 3 of 5 dropped files.")
}

@(test)
a_dropped_file_opens_with_the_first_link_program_offered_for_files :: proc(t: ^testing.T) {
	sync.mutex_lock(&Link_Test_Lock)
	defer sync.mutex_unlock(&Link_Test_Lock)
	f: Drop_Fixture
	defer drop_fixture_destroy(t, &f)
	if !drop_fixture_create(t, &f, "file-drop-program") {return}
	// No nvim on PATH: the program is used and Neovim is never looked for.
	if !drop_path_with_nvim(t, &f, false) {return}
	// Settings' order puts a folders-only program first, which a file is not offered, then two for files.
	programs := "\nopener.dirs.name = Folder Tool\nopener.dirs.command = cmd.exe /d /k rem\n" +
		"opener.dirs.offers = folders\nopener.echo.name = Echo\nopener.echo.command = cmd.exe /d /k rem %1\n" +
		"opener.echo.placement = window\nopener.other.name = Other\nopener.other.command = cmd.exe /d /k rem %1\n" +
		"opener.order = dirs, echo, other\n"
	if !drop_settings(t, &f, programs) {return}
	s, w := &f.palette.state, f.palette.state.windows[0]
	notes, made := drop_file(t, &f, "notes.txt")
	if !made {return}
	notices := len(s.notices.items)

	// Echo runs as a window of its own: started in the file's folder, and no pane or session is made.
	program_stub_files = {}
	s.opener.program = program_stub_files_record
	defer {
		s.opener.program = nil
		delete(program_stub_files.command_line)
		delete(program_stub_files.directory)
		program_stub_files = {}
	}
	sessions := len(s.sessions)
	drop(s, w, zone(w.panes[0].rect, .Right), notes)
	testing.expect_value(t, program_stub_files.calls, 1)
	testing.expect(t, strings.has_suffix(program_stub_files.command_line, fmt.tprintf(`\cmd.exe" /d /k rem %s`, notes)))
	testing.expect(t, strings.equal_fold(program_stub_files.directory, f.root), program_stub_files.directory)
	testing.expect_value(t, len(s.sessions), sessions)
	testing.expect_value(t, len(s.notices.items), notices)

	// With Echo no longer offered for files, the next program that is runs in a pane at the drop target.
	if !drop_settings(t, &f, "opener.echo.offers = folders\n") {return}
	drop(s, w, zone(w.panes[0].rect, .Left), notes)
	if !testing.expect_value(t, len(s.sessions), sessions + 1) {return}
	opened := &s.sessions[len(s.sessions) - 1]
	testing.expect(t, strings.has_suffix(opened.header.command, fmt.tprintf(`\cmd.exe" /d /k rem %s`, notes)))
	testing.expect(t, strings.equal_fold(opened.header.launch_directory, f.root), opened.header.launch_directory)
	// The pane went to the left of the one it was dropped on, as the outline says.
	testing.expect_value(t, kinds_in_order(w)[0], layout.Content_Kind.Terminal)
	testing.expect_value(t, len(w.panes), 2)
	testing.expect_value(t, len(s.notices.items), notices)
}

@(private = "file")
Program_Stub :: struct {
	calls:                   int,
	command_line, directory: string,
}

@(private = "file")
program_stub_files: Program_Stub

@(private = "file")
program_stub_files_record :: proc(command_line, directory: string) -> bool {
	delete(program_stub_files.command_line)
	delete(program_stub_files.directory)
	program_stub_files.calls += 1
	program_stub_files.command_line = strings.clone(command_line)
	program_stub_files.directory = strings.clone(directory)
	return true
}

// Appends settings lines to the fixture's file and reloads it.
@(private = "file", require_results)
drop_settings :: proc(t: ^testing.T, f: ^Drop_Fixture, extra: string) -> bool {
	existing, read_error := os.read_entire_file(f.palette.path, context.allocator)
	if !testing.expect_value(t, read_error, nil) {return false}
	defer delete(existing)
	text := strings.concatenate({string(existing), "\n", extra}, context.temp_allocator)
	if !testing.expect_value(t, os.write_entire_file(f.palette.path, transmute([]u8)text), nil) {return false}
	app.reload_settings(&f.palette.state, false)
	return true
}
