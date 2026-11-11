package main

import "aio:render"
import "aio:settings"
import "aio:ui"
import "core:fmt"
import "core:math"
import "core:time"

// Switching workspace in a window zooms the window out into a column of every workspace, in workspace list
// order, travels along the column to the one chosen and zooms back into it, so a workspace change never
// reads as a tab change. The chosen workspace draws live; the others draw the last frame this window showed
// of them, or an empty card. Only drawing moves: layout, input and sessions take the new workspace at once.
// The Switch Workspace motion settings pace it.
Workspace_Overview :: struct {
	// Runs from 0 to 1 across the flight, which the legs share out.
	progress:  ui.Motion,
	legs:      [3]Overview_Leg,
	leg_count: int,
	// The workspace the window placed last, by id.
	shown:     u32,
	// Where the last frame drew the window's own content, below its overlays, and for which workspace.
	drawn:     Overview_Drawn,
	// The last frame of each workspace this window showed, by workspace id, for its card.
	frames:    [dynamic]Overview_Frame,
}

// Where the overview looks: the scale the column is drawn at, and the card it centres, by list index;
// between two cards while it travels.
Overview_Camera :: struct {
	scale, card: f32,
}

@(private = "file")
Overview_Leg :: struct {
	share:    f32,
	from, to: Overview_Camera,
	curve:    settings.Motion_Curve,
}

@(private = "file")
Overview_Drawn :: struct {
	workspace: u32,
	from, to:  render.Draw_Mark,
	// Drawn at full size, not as a card of a running overview.
	whole:     bool,
}

@(private = "file")
Overview_Frame :: struct {
	workspace: u32,
	list:      render.Draw_List,
	atlas:     u64,
}

// How small the cards get, and the room between them in DIPs.
@(private = "file")
OVERVIEW_SCALE :: f32(0.3)
@(private = "file")
OVERVIEW_GAP :: f32(120)
// The legs of a switch to the next workspace, as shares of its duration: zooming out, travelling one card
// and zooming in. Travelling further adds OVERVIEW_TRAVEL_STEP a card, up to three cards.
@(private = "file")
OVERVIEW_ZOOM_OUT :: f32(140) / 470
@(private = "file")
OVERVIEW_TRAVEL :: f32(80) / 470
@(private = "file")
OVERVIEW_TRAVEL_STEP :: f32(70) / 470
@(private = "file")
OVERVIEW_ZOOM_IN :: f32(180) / 470

workspace_overview_destroy :: proc(w: ^Window) {
	for &frame in w.overview.frames {render.draw_list_destroy(&frame.list)}
	delete(w.overview.frames)
	w.overview = {}
}

// A workspace change the window cannot show now, as while it is minimized, does not play later.
workspace_overview_lapse :: proc(w: ^Window) {
	w.overview.shown = 0
}

workspace_overview_animating :: proc(w: ^Window) -> bool {
	return ui.motion_active(w.overview.progress)
}

workspace_overview_animate :: proc(app: ^App, w: ^Window, frame: ui.Frame_Time) -> bool {
	changed := ui.motion_update(&w.overview.progress, frame)
	if !workspace_overview_animating(w) {w.overview.leg_count = 0}
	return changed
}

// Where the overview looks now; false when no switch is playing.
workspace_overview_camera :: proc(w: ^Window) -> (Overview_Camera, bool) {
	o := &w.overview
	if !workspace_overview_animating(w) || o.leg_count == 0 {return {}, false}
	t := o.progress.value
	for leg in o.legs[:o.leg_count] {
		if t <= leg.share {
			e := leg.share > 0 ? settings.motion_curve_ease(leg.curve, t / leg.share) : 1
			return {
					math.lerp(leg.from.scale, leg.to.scale, e),
					math.lerp(leg.from.card, leg.to.card, e),
				},
				true
		}
		t -= leg.share
	}
	return o.legs[o.leg_count - 1].to, true
}

// After a relayout: a window that now shows another workspace keeps its last frame of the one it left and
// flies from wherever the overview looks to the workspace it shows.
workspace_overview_placed :: proc(app: ^App, w: ^Window) {
	o := &w.overview
	before := o.shown
	o.shown = w.workspace != nil ? w.workspace.id : 0
	if before == 0 || o.shown == 0 || before == o.shown {return}
	overview_frames_prune(app, o)
	overview_frame_keep(app, w, before)
	from, to := overview_index(app, before), overview_index(app, o.shown)
	motion := settings.motion_resolve(&app.settings, .Workspace)
	duration := settings.motion_duration(&app.settings, motion)
	camera, flying := workspace_overview_camera(w)
	if !flying {camera = {1, f32(from)}}
	if !app.animations || duration <= 0 || from < 0 || to < 0 {
		o.progress, o.leg_count = {}, 0
		return
	}
	smooth, _ := settings.motion_curve_find(&app.settings, "smooth")
	// Zoom out from wherever it is, travel to the card, and zoom into it.
	out := (camera.scale - OVERVIEW_SCALE) / (1 - OVERVIEW_SCALE)
	distance := abs(f32(to) - camera.card)
	o.leg_count = 0
	overview_leg_add(o, OVERVIEW_ZOOM_OUT * max(out, 0), camera, {OVERVIEW_SCALE, camera.card}, smooth)
	if distance > 0.001 {
		travel := OVERVIEW_TRAVEL + OVERVIEW_TRAVEL_STEP * min(distance, 3)
		overview_leg_add(o, travel, {OVERVIEW_SCALE, camera.card}, {OVERVIEW_SCALE, f32(to)}, smooth)
	}
	overview_leg_add(o, OVERVIEW_ZOOM_IN, {OVERVIEW_SCALE, f32(to)}, {1, f32(to)}, motion.curve)
	// The legs' shares become shares of the whole flight, which lasts the duration in proportion.
	total: f32
	for leg in o.legs[:o.leg_count] {total += leg.share}
	for &leg in o.legs[:o.leg_count] {leg.share /= total}
	neighbour := OVERVIEW_ZOOM_OUT + OVERVIEW_TRAVEL + OVERVIEW_TRAVEL_STEP + OVERVIEW_ZOOM_IN
	o.progress = {}
	whole := time.Duration(f64(duration) * f64(total / neighbour))
	ui.motion_target_curve(&o.progress, 1, whole, ui.EASING_CURVES[.Linear], true)
}

@(private = "file")
overview_leg_add :: proc(
	o: ^Workspace_Overview,
	share: f32,
	from, to: Overview_Camera,
	curve: settings.Motion_Curve,
) {
	if share <= 0 {return}
	o.legs[o.leg_count] = {share, from, to, curve}
	o.leg_count += 1
}

// The workspace's place in the column: its place in the workspace list, counting only listed workspaces.
@(private = "file")
overview_index :: proc(app: ^App, id: u32) -> int {
	index := 0
	for workspace in app.workspaces {
		if !workspace_eligible(app, workspace) {continue}
		if workspace.id == id {return index}
		index += 1
	}
	return -1
}

// Keeps what the last frame drew at full size of workspace `id` as its card.
@(private = "file")
overview_frame_keep :: proc(app: ^App, w: ^Window, id: u32) {
	o := &w.overview
	d := o.drawn
	if d.workspace != id || !d.whole || d.to.layers <= d.from.layers {return}
	frame: ^Overview_Frame
	for &kept in o.frames {if kept.workspace == id {frame = &kept}}
	if frame == nil {
		kept := Overview_Frame{workspace = id, list = render.draw_list_init()}
		if _, err := append(&o.frames, kept); err != nil {return}
		frame = &o.frames[len(o.frames) - 1]
	}
	render.draw_list_reset(&frame.list)
	frame.atlas = 0
	if render.draw_list_copy(&frame.list, &w.list, d.from, d.to) != .None {return}
	frame.atlas = render.atlas_generation(app.device)
}

// Forgets the frames of workspaces that no longer exist.
@(private = "file")
overview_frames_prune :: proc(app: ^App, o: ^Workspace_Overview) {
	for i := len(o.frames) - 1; i >= 0; i -= 1 {
		if overview_index(app, o.frames[i].workspace) >= 0 {continue}
		render.draw_list_destroy(&o.frames[i].list)
		unordered_remove(&o.frames, i)
	}
}

// The rectangle card `index` takes on screen under `camera`.
@(private = "file")
overview_card :: proc(w: ^Window, camera: Overview_Camera, index: int) -> render.Rect {
	width, height := f32(w.width), f32(w.height)
	pitch := height + OVERVIEW_GAP * w.scale
	s := camera.scale
	x := width / 2 - width / 2 * s
	y := height / 2 - (camera.card * pitch + height / 2) * s + f32(index) * pitch * s
	return {x, y, width * s, height * s}
}

// How far the overview has zoomed out, from 0 at full size to 1 at the column.
@(private = "file")
overview_out :: proc(camera: Overview_Camera) -> f32 {
	return clamp((1 - camera.scale) / (1 - OVERVIEW_SCALE), 0, 1)
}

@(private = "file")
overview_visible :: proc(w: ^Window, r: render.Rect) -> bool {
	return r.y < f32(w.height) && r.y + r.height > 0
}

// Starts a frame: while a switch plays, the desk beneath the column and each card's shadow, then the
// chosen workspace's card background, which its content draws over. Returns where the content starts.
workspace_overview_frame_begin :: proc(app: ^App, w: ^Window) -> render.Draw_Mark {
	camera, flying := workspace_overview_camera(w)
	if !flying {return render.draw_mark(&w.list)}
	window := render.Rect{0, 0, f32(w.width), f32(w.height)}
	if render.push_layer(&w.list, window) != .None {return render.draw_mark(&w.list)}
	_ = render.push_rect(&w.list, {rect = window, color = app.theme.window})
	_ = render.push_rect(&w.list, {rect = window, color = app.theme.scrim})
	out := overview_out(camera)
	shadow := app.theme.shadow
	shadow.a *= out
	index := 0
	for workspace in app.workspaces {
		if !workspace_eligible(app, workspace) {continue}
		defer index += 1
		r := overview_card(w, camera, index)
		if !overview_visible(w, r) {continue}
		r.y += 10 * w.scale
		_ = render.push_rect(&w.list, {rect = r, color = shadow, softness = 24 * w.scale})
	}
	content := render.draw_mark(&w.list)
	if render.push_layer(&w.list, window) == .None {
		_ = render.push_rect(&w.list, {rect = window, color = app.theme.window})
	}
	return content
}

// Ends the window's own content, drawn since `content`. Notes where it lies, so a switch can keep it, and
// while a switch plays, shrinks it into the chosen workspace's card and draws the column around it.
workspace_overview_frame_end :: proc(
	app: ^App,
	w: ^Window,
	content: render.Draw_Mark,
) -> render.Build_Status {
	o := &w.overview
	camera, flying := workspace_overview_camera(w)
	o.drawn = {w.workspace != nil ? w.workspace.id : 0, content, render.draw_mark(&w.list), !flying}
	if !flying {return .Ok}
	target := overview_index(app, o.shown)
	card := overview_card(w, camera, target)
	render.draw_scale(&w.list, content, {}, camera.scale)
	render.draw_translate(&w.list, content, {card.x, card.y}, card)
	atlas := render.atlas_generation(app.device)
	window := render.Rect{0, 0, f32(w.width), f32(w.height)}
	index := 0
	for workspace in app.workspaces {
		if !workspace_eligible(app, workspace) {continue}
		defer index += 1
		if index == target {continue}
		r := overview_card(w, camera, index)
		if !overview_visible(w, r) {continue}
		mark := render.draw_mark(&w.list)
		if render.push_layer(&w.list, window) != .None {return .Ok}
		_ = render.push_rect(&w.list, {rect = window, color = app.theme.window})
		for &frame in o.frames {
			if frame.workspace != workspace.id || frame.atlas != atlas {continue}
			if render.append_list(&w.list, &frame.list) != .None {return .Ok}
		}
		render.draw_scale(&w.list, mark, {}, camera.scale)
		render.draw_translate(&w.list, mark, {r.x, r.y}, r)
	}
	return overview_marks_draw(app, w, camera, target)
}

// Over the column: each card's outline and label, a ring in the chosen workspace's colour around its card,
// and a title bar naming it, all as strong as the column is zoomed out.
@(private = "file")
overview_marks_draw :: proc(
	app: ^App,
	w: ^Window,
	camera: Overview_Camera,
	target: int,
) -> render.Build_Status {
	out := overview_out(camera)
	if out <= 0 {return .Ok}
	s := w.scale
	window := render.Rect{0, 0, f32(w.width), f32(w.height)}
	mark := render.draw_mark(&w.list)
	if render.push_layer(&w.list, window) != .None {return .Ok}
	label_height := w.ui_text.line_height
	index := 0
	for workspace in app.workspaces {
		if !workspace_eligible(app, workspace) {continue}
		defer index += 1
		r := overview_card(w, camera, index)
		if !overview_visible(w, r) {continue}
		chosen := index == target
		_ = render.push_rect(&w.list, {rect = r, color = app.theme.border, stroke = max(1, s)})
		if chosen {
			ring := render.Rect{r.x - 5 * s, r.y - 5 * s, r.width + 10 * s, r.height + 10 * s}
			color := workspace_icon_tint(workspace.icon.tint, app.theme.accent)
			radius := ui.RADIUS_OVERLAY * s
			_ = render.push_rect(&w.list, {rect = ring, color = color, radius = radius, stroke = 2 * s})
		}
		top := r.y - 8 * s - label_height
		if result := overview_label_draw(app, w, workspace, {r.x, top, r.width, label_height}, chosen);
		   result != .Ok {return result}
	}
	bar := render.Rect{0, 0, window.width, ui.TITLE_BAR_HEIGHT * s}
	if render.push_layer(&w.list, bar) != .None {return .Ok}
	_ = render.push_rect(&w.list, {rect = bar, color = app.theme.tab_bar})
	prefix := "Switching to"
	baseline := bar.y + (bar.height - label_height) / 2 + w.ui_text.ascent
	x := 78 * s
	if result := ui.draw_text(&w.ui_text, &w.list, prefix, x, baseline, app.theme.muted); result != .Ok {
		return result
	}
	x += ui.text_width(&w.ui_text, prefix) + ui.SPACE_2 * s
	if workspace := w.workspace; workspace != nil {
		size := ui.ICON_BUTTON * s
		icon := render.Rect{x, bar.y + (bar.height - size) / 2, size, size}
		if result := workspace_icon_draw(w, workspace.icon, icon, app.theme.text); result != .Ok {return result}
		x += size + ui.SPACE_2 * s
		if result := ui.draw_text(&w.ui_text, &w.list, workspace.name, x, baseline, app.theme.text);
		   result != .Ok {return result}
	}
	ui.fade_draw(&w.list, mark, {opacity = out})
	// The window's own caption buttons stay where they are, over the title bar that names the workspace.
	return ui.caption_draw(
		&w.list,
		&w.ui_text,
		app.theme,
		window.width,
		s,
		w.caption_hover,
		nil,
		w.maximized,
		w.pointer,
	)
}

// One card's label: the workspace's icon and name, and how many tabs and panes it holds.
@(private = "file")
overview_label_draw :: proc(
	app: ^App,
	w: ^Window,
	workspace: ^Workspace,
	area: render.Rect,
	chosen: bool,
) -> render.Build_Status {
	s := w.scale
	size := ui.ICON_INDICATOR * s
	icon := render.Rect{area.x, area.y + (area.height - size) / 2, size, size}
	ink := chosen ? app.theme.text : app.theme.muted
	if result := workspace_icon_draw(w, workspace.icon, icon, ink); result != .Ok {return result}
	right := area.x + area.width
	x := icon.x + size + ui.SPACE_2 * s
	baseline := area.y + w.ui_text.ascent
	if result := ui.draw_fading_text(&w.ui_text, &w.list, workspace.name, x, baseline, ink, right - x);
	   result != .Ok {return result}
	x += ui.text_width(&w.ui_text, workspace.name) + ui.SPACE_2 * s
	panes := 0
	for tab in workspace.tabs {panes += tab_pane_count(tab)}
	tabs := len(workspace.tabs)
	buffer: [64]u8
	detail := fmt.bprintf(
		buffer[:],
		"%d %s · %d %s",
		tabs,
		tabs == 1 ? "tab" : "tabs",
		panes,
		panes == 1 ? "pane" : "panes",
	)
	return ui.draw_fading_text(&w.ui_text, &w.list, detail, x, baseline, app.theme.faint, right - x)
}
