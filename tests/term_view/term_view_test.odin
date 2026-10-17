package term_view_test

import "core:math"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"
import "aio:font"
import "aio:glyphs"
import "aio:render"
import "aio:term"
import "aio:term_view"

COLUMNS :: 20
ROWS :: 4
SIZE_PX :: 16

@(test)
metrics_and_grid_size :: proc(t: ^testing.T) {
	fonts, err := font.system_create()
	if !testing.expect_value(t, err, font.Error.None) {
		return
	}
	defer font.system_destroy(fonts)
	family, family_error := font.family_load(fonts, "Cascadia Mono")
	if !testing.expect_value(t, family_error, font.Error.None) {
		return
	}
	m := term_view.compute_metrics(fonts, family, SIZE_PX, 1)
	testing.expect(t, m.cell_width >= 8 && m.cell_width <= 11)
	testing.expect(t, m.cell_height >= 17 && m.cell_height <= 23)
	testing.expect(t, m.baseline > 0 && m.baseline < m.cell_height)
	testing.expect(t, m.underline_thickness >= 1 && m.underline_offset > 0)
	testing.expect_value(t, m.cell_width, f32(int(m.cell_width)))
	tall := term_view.compute_metrics(fonts, family, SIZE_PX, 1.5)
	testing.expect(t, tall.cell_height > m.cell_height && tall.baseline > m.baseline)
	columns, rows := term_view.grid_size(m, 2 * 8 + 10 * m.cell_width + 3, 2 * 8 + 5 * m.cell_height, 8)
	testing.expect_value(t, columns, 10)
	testing.expect_value(t, rows, 5)
	columns, rows = term_view.grid_size(m, 4, 4, 8)
	testing.expect_value(t, columns, 1)
	testing.expect_value(t, rows, 1)
}

Fixture :: struct {
	fonts: ^font.System,
	family: font.Family,
	device: ^render.Device,
	surface: ^render.Surface,
	cache: glyphs.Cache,
	list: render.Draw_List,
	view: term_view.View,
	session: ^term.Session,
	metrics: term_view.Metrics,
}

palette :: proc() -> (p: [16]term.Color) {
	p[1] = {200, 0, 0}
	p[4] = {0, 0, 200}
	return
}

fixture_create :: proc(t: ^testing.T, command: string, family := "Consolas") -> (f: Fixture, ok: bool) {
	testing.set_fail_timeout(t, 60 * time.Second)
	font_error: font.Error
	f.fonts, font_error = font.system_create()
	if !testing.expect_value(t, font_error, font.Error.None) {
		return
	}
	f.family, font_error = font.family_load(f.fonts, family)
	render_error: render.Error
	f.device, render_error = render.device_create()
	if font_error != .None || render_error != .None {
		testing.fail(t)
		return
	}
	f.metrics = term_view.compute_metrics(f.fonts, f.family, SIZE_PX, 1)
	width, height := i32(f.metrics.cell_width * COLUMNS), i32(f.metrics.cell_height * ROWS)
	f.surface, render_error = render.surface_create_offscreen(f.device, width, height)
	if !testing.expect_value(t, render_error, render.Error.None) || !term_view.create(&f.view) {
		return
	}
	glyphs.init(&f.cache, f.fonts, f.device)
	render.set_text_gamma(f.device, {1, 0})
	f.list = render.draw_list_init()
	config := term.Config{
		command_line = command,
		working_directory = "C:\\Windows\\System32",
		geometry = {
			columns = COLUMNS,
			rows = ROWS,
			cell_width = u32(f.metrics.cell_width),
			cell_height = u32(f.metrics.cell_height),
			surface_width = u32(width),
			surface_height = u32(height),
		},
		scrollback_lines = 100,
		colors = {foreground = {255, 255, 255}, background = {0, 0, 0}, cursor = {0, 255, 0}, palette = palette()},
	}
	session_error: term.Error
	f.session, session_error = term.create(config, {})
	return f, testing.expect_value(t, session_error, term.Error.None)
}

fixture_destroy :: proc(f: ^Fixture) {
	if f.session != nil {
		term.destroy(f.session)
	}
	render.draw_list_destroy(&f.list)
	glyphs.destroy(&f.cache)
	term_view.destroy(&f.view)
	if f.surface != nil {
		render.surface_destroy(f.surface)
	}
	if f.device != nil {
		render.device_destroy(f.device)
	}
	if f.fonts != nil {
		font.system_destroy(f.fonts)
	}
}

render_frame :: proc(t: ^testing.T, f: ^Fixture, style: term_view.Style) -> (term_view.Frame, []u8) {
	frame: term_view.Frame
	for _ in 0 ..< 2 {
		render.draw_list_reset(&f.list)
		testing.expect_value(t, render.push_layer(&f.list, {0, 0, 4096, 4096}), render.Error.None)
		result: glyphs.Result
		frame, result = term_view.build(&f.view, f.session, f.fonts, &f.cache, &f.list, {0, 0}, f.metrics, style)
		if result == .Ok {
			break
		}
	}
	rendered := render.frame_render(f.device, f.surface, &f.list, frame.background)
	testing.expect_value(t, rendered, render.Error.None)
	pixels, err := render.surface_read_pixels(f.device, f.surface, context.temp_allocator)
	testing.expect_value(t, err, render.Error.None)
	return frame, pixels
}

await_text :: proc(t: ^testing.T, s: ^term.Session, text: string) -> bool {
	start := time.tick_now()
	for time.tick_since(start) < 20 * time.Second {
		term.select_all(s)
		screen, _ := term.selection_text(s, context.temp_allocator)
		term.clear_selection(s)
		if strings.contains(screen, text) {
			return true
		}
		time.sleep(10 * time.Millisecond)
	}
	testing.expectf(t, false, "timed out waiting for %q", text)
	return false
}

cell_pixel :: proc(f: ^Fixture, pixels: []u8, column, row: int, dx, dy: f32) -> [4]u8 {
	width := int(f.metrics.cell_width * COLUMNS)
	x := int(f32(column) * f.metrics.cell_width + dx)
	y := int(f32(row) * f.metrics.cell_height + dy)
	i := (y * width + x) * 4
	return {pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3]}
}

cell_has_ink :: proc(f: ^Fixture, pixels: []u8, column, row: int) -> bool {
	for dy in 0 ..< int(f.metrics.cell_height) {
		for dx in 0 ..< int(f.metrics.cell_width) {
			p := cell_pixel(f, pixels, column, row, f32(dx), f32(dy))
			if p[0] > 128 && p[1] > 128 && p[2] > 128 {
				return true
			}
		}
	}
	return false
}

@(test)
decorations_are_crisp_over_backgrounds :: proc(t: ^testing.T) {
	script :: "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe -NoProfile -Command \"" +
		"$e = [char]27; [Console]::Write($e + '[41;4m ' + $e + '[24;9m ' + $e + '[29;21m ' + " +
		"$e + '[0mREADY'); [Console]::Out.Flush(); Start-Sleep -Seconds 30\""
	f, ok := fixture_create(t, script)
	defer fixture_destroy(&f)
	if !ok || !await_text(t, f.session, "READY") {
		return
	}
	_, pixels := render_frame(t, &f, {family = f.family})
	m := f.metrics
	Line :: struct { top, height: int }
	underline := Line{int(m.baseline + m.underline_offset), int(m.underline_thickness)}
	strike := Line{int(m.baseline - m.strikethrough_offset), int(m.strikethrough_thickness)}
	double := [2]Line{
		{underline.top - underline.height, underline.height},
		{underline.top + underline.height, underline.height},
	}
	cells := [3][]Line{{underline}, {strike}, double[:]}
	background, ink := [4]u8{0, 0, 200, 255}, [4]u8{255, 255, 255, 255}
	for lines, column in cells {
		blended := 0
		for y in 0 ..< int(m.cell_height) {
			inside := false
			for line in lines {
				inside ||= y >= line.top && y < line.top + line.height
			}
			for x in 0 ..< int(m.cell_width) {
				if cell_pixel(&f, pixels, column, 0, f32(x), f32(y)) != (inside ? ink : background) {
					blended += 1
				}
			}
		}
		testing.expectf(t, blended == 0, "cell %d: %d pixels are neither the line nor the background", column, blended)
	}
}

@(test)
renders_colors_text_and_cursor :: proc(t: ^testing.T) {
	script :: "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe -NoProfile -Command \"" +
		"$e = [char]27; [Console]::Write($e + '[41mRR' + $e + '[0mAB' + $e + '[44m ' + $e + '[0m'); " +
		"[Console]::Out.Flush(); Start-Sleep -Seconds 30\""
	f, ok := fixture_create(t, script)
	defer fixture_destroy(&f)
	if !ok || !await_text(t, f.session, "RRAB") {
		return
	}
	style := term_view.Style{
		family = f.family,
		selection_background = {0.2, 0.2, 0.2, 1},
		cursor_text = {0, 0, 0, 1},
		focused = true,
		cursor_phase_visible = true,
	}
	frame, pixels := render_frame(t, &f, style)
	testing.expect_value(t, frame.background, render.Color{0, 0, 0, 1})
	red := cell_pixel(&f, pixels, 0, 0, 1, 1)
	testing.expect_value(t, red, [4]u8{0, 0, 200, 255})
	blue := cell_pixel(&f, pixels, 4, 0, 1, 1)
	testing.expect_value(t, blue, [4]u8{200, 0, 0, 255})
	testing.expect(t, cell_has_ink(&f, pixels, 2, 0))
	testing.expect(t, cell_has_ink(&f, pixels, 3, 0))
	testing.expect(t, !cell_has_ink(&f, pixels, 10, 2))
	cursor := cell_pixel(&f, pixels, 5, 0, 1, f.metrics.cell_height / 2)
	testing.expect_value(t, cursor, [4]u8{0, 255, 0, 255})
	style.focused = false
	_, unfocused := render_frame(t, &f, style)
	center := cell_pixel(&f, unfocused, 5, 0, f.metrics.cell_width / 2, f.metrics.cell_height / 2)
	edge := cell_pixel(&f, unfocused, 5, 0, 0, f.metrics.cell_height / 2)
	testing.expect_value(t, center, [4]u8{0, 0, 0, 255})
	testing.expect_value(t, edge, [4]u8{0, 255, 0, 255})
	term.select_all(f.session)
	style.focused = true
	_, selected := render_frame(t, &f, style)
	testing.expect_value(t, cell_pixel(&f, selected, 2, 0, 0, 0), [4]u8{51, 51, 51, 255})
}

text_command :: proc(text: string) -> string {
	return strings.concatenate({
		"C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe -NoProfile -Command \"",
		"[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false); $e = [char]27; " +
		"[Console]::Write($e + '[2J' + $e + '[H' + ", text,
		"); [Console]::Out.Flush(); Start-Sleep -Seconds 30\"",
	}, context.temp_allocator)
}

unshaped_entry :: proc(t: ^testing.T, f: ^Fixture, r: rune, style: font.Style = .Regular) -> glyphs.Entry {
	g, found := font.glyph_lookup(f.fonts, f.family, style, r)
	testing.expect(t, found)
	entry, result := glyphs.glyph(&f.cache, g, SIZE_PX)
	testing.expect_value(t, result, glyphs.Result.Ok)
	return entry
}

@(test)
ligatures_and_cursor_boundary :: proc(t: ^testing.T) {
	f, ok := fixture_create(t, text_command("'a->b != c ->' + $e + '[1;12H'"), "Cascadia Code")
	defer fixture_destroy(&f)
	if !ok || !await_text(t, f.session, "a->b != c ->") { return }
	render_frame(t, &f, {family = f.family})
	baseline := make([dynamic]render.Glyph_Instance, context.temp_allocator)
	for r in "a->b != c ->" {
		entry := unshaped_entry(t, &f, r)
		if entry.size.x > 0 {
			_, err := append(&baseline, render.Glyph_Instance{atlas = entry.atlas})
			testing.expect(t, err == nil)
		}
	}
	different := len(baseline) != len(f.list.glyphs)
	for g, i in f.list.glyphs {
		if i < len(baseline) && g.atlas != baseline[i].atlas { different = true }
	}
	testing.expect(t, different)
	n := len(f.list.glyphs)
	if !testing.expect(t, n >= 2) { return }
	testing.expect_value(t, f.list.glyphs[n - 2].atlas, unshaped_entry(t, &f, '-').atlas)
	testing.expect_value(t, f.list.glyphs[n - 1].atlas, unshaped_entry(t, &f, '>').atlas)
	before := slice.clone(f.list.glyphs[:], context.temp_allocator)
	render_frame(t, &f, {family = f.family, focused = true, cursor_phase_visible = true})
	for g, i in f.list.glyphs {
		testing.expect_value(t, g.atlas, before[i].atlas)
		testing.expect_value(t, g.rect, before[i].rect)
	}
}

@(test)
style_run_faces :: proc(t: ^testing.T) {
	f, ok := fixture_create(t, text_command("'A' + $e + '[1mB' + $e + '[22;3mC' + $e + '[1mD' + $e + '[0m'"))
	defer fixture_destroy(&f)
	if !ok || !await_text(t, f.session, "ABCD") { return }
	render_frame(t, &f, {family = f.family})
	if !testing.expect_value(t, len(f.list.glyphs), 4) { return }
	styles := [4]font.Style{.Regular, .Bold, .Italic, .Bold_Italic}
	for r, i in "ABCD" {
		entry := unshaped_entry(t, &f, r, styles[i])
		testing.expect_value(t, f.list.glyphs[i].atlas, entry.atlas)
		testing.expect_value(t, f.list.glyphs[i].rect.x,
		                     math.round(f32(i) * f.metrics.cell_width + entry.offset.x))
	}
}

@(test)
consolas_grid_and_combining_cluster :: proc(t: ^testing.T) {
	command := text_command("'AB' + [char]0x6f22 + [char]::ConvertFromUtf32(0x1f600) + 'e' + [char]0x301")
	f, ok := fixture_create(t, command)
	defer fixture_destroy(&f)
	if !ok || !await_text(t, f.session, "AB") { return }
	_, actual := render_frame(t, &f, {family = f.family})
	render.draw_list_reset(&f.list)
	testing.expect_value(t, render.push_layer(&f.list, {0, 0, 4096, 4096}), render.Error.None)
	runes := [?]rune{'A', 'B', 0x6f22, 0x1f600}
	columns := [?]int{0, 1, 2, 4}
	for r, i in runes {
		entry := unshaped_entry(t, &f, r)
		if entry.size.x == 0 { continue }
		testing.expect_value(t, render.push_glyph(&f.list, {
			rect = {
				math.round(f32(columns[i]) * f.metrics.cell_width + entry.offset.x),
				math.round(f.metrics.baseline + entry.offset.y), entry.size.x, entry.size.y,
			},
			atlas = entry.atlas, color = {1, 1, 1, 1},
		}), render.Error.None)
	}
	combined := make([dynamic]font.Shaped_Glyph, context.temp_allocator)
	marks := [?]rune{'e', 0x301}
	testing.expect_value(t, font.shape(f.fonts, f.family, .Regular, marks[:], SIZE_PX, &combined), font.Error.None)
	advance: f32
	for g in combined {
		testing.expect_value(t, g.cluster, 0)
		entry, result := glyphs.glyph(&f.cache, g.glyph, SIZE_PX)
		testing.expect_value(t, result, glyphs.Result.Ok)
		testing.expect_value(t, render.push_glyph(&f.list, {
			rect = {
				math.round(6 * f.metrics.cell_width + advance + g.offset.x + entry.offset.x),
				math.round(f.metrics.baseline - g.offset.y + entry.offset.y), entry.size.x, entry.size.y,
			},
			atlas = entry.atlas, color = {1, 1, 1, 1},
		}), render.Error.None)
		advance += g.advance
	}
	testing.expect_value(t, render.frame_render(f.device, f.surface, &f.list, {0, 0, 0, 1}), render.Error.None)
	expected, err := render.surface_read_pixels(f.device, f.surface, context.temp_allocator)
	testing.expect_value(t, err, render.Error.None)
	testing.expect(t, slice.equal(actual, expected))
}

@(test)
paint_changes_preserve_ligatures :: proc(t: ^testing.T) {
	f, ok := fixture_create(t, text_command("'-> ' + $e + '[31m-' + $e + '[4;44m>' + $e + '[0m'"),
	                        "Cascadia Code")
	defer fixture_destroy(&f)
	if !ok || !await_text(t, f.session, "-> ->") { return }
	render_frame(t, &f, {family = f.family})
	n := len(f.list.glyphs)
	if !testing.expect(t, n > 0 && n % 2 == 0) { return }
	for i in 0..<n / 2 {
		a, b := f.list.glyphs[i], f.list.glyphs[i + n / 2]
		testing.expect_value(t, a.atlas, b.atlas)
		testing.expect_value(t, b.rect.x - a.rect.x, 3 * f.metrics.cell_width)
		testing.expect_value(t, a.rect.y, b.rect.y)
		testing.expect(t, a.color != b.color)
	}
	runes, columns, shaped := cap(f.view.runes), cap(f.view.columns), cap(f.view.shaped)
	render_frame(t, &f, {family = f.family})
	testing.expect_value(t, cap(f.view.runes), runes)
	testing.expect_value(t, cap(f.view.columns), columns)
	testing.expect_value(t, cap(f.view.shaped), shaped)
}
