package main

import "cosmos:render"
import "aio:settings"
import "aio:ui"
import "core:fmt"
import "core:math"
import "core:time"

// Switching workspace in a window zooms the window out into a column of every workspace, in workspace list
// order, travels along the column to the one chosen and zooms back into it, so a workspace change never
// reads as a tab change. The chosen workspace draws live; the others draw the last frame this window showed
// of them, or an empty card. Only drawing moves: layout, input and sessions take the new workspace at once.
// The Switch Workspace motion settings pace it. Deleting a workspace plays its own flight; see
// workspace_overview_delete.odin.
Workspace_Overview :: struct {
	// Runs from 0 to 1 across the flight, which the legs share out.
	progress:  ui.Motion,
	legs:      [6]Overview_Leg,
	leg_count: int,
	// The workspace the window placed last, and the one the last switch left, by id.
	shown:     u32,
	left:      u32,
	// Where the last frame drew the window's own content, below its overlays, and for which workspace.
	drawn:     Overview_Drawn,
	// The last frame of each workspace this window showed, by workspace id, for its card.
	frames:    [dynamic]Overview_Frame,
	// The column's workspaces by id, listed as when the flight began. One deleted since, as the workspace
	// a delete leaves, keeps its card and place, so the flight still lands on the card it was headed for.
	column:    [dynamic]u32,
	deletion:  Overview_Deletion,
}

// Where the overview looks: the scale the column is drawn at, and the card it centres, by column index;
// between two cards while it travels.
Overview_Camera :: struct {
	scale, card: f32,
}

@(private)
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
@(private)
OVERVIEW_SCALE :: f32(0.3)
@(private = "file")
OVERVIEW_GAP :: f32(120)
// The legs of a switch to the next workspace, as shares of its duration: zooming out, travelling one card
// and zooming in. Travelling further adds OVERVIEW_TRAVEL_STEP a card, up to three cards.
@(private)
OVERVIEW_ZOOM_OUT :: f32(140) / 470
@(private)
OVERVIEW_TRAVEL :: f32(80) / 470
@(private)
OVERVIEW_TRAVEL_STEP :: f32(70) / 470
@(private)
OVERVIEW_ZOOM_IN :: f32(180) / 470

workspace_overview_destroy :: proc(w: ^Window) {
	for &frame in w.overview.frames {render.draw_list_destroy(&frame.list)}
	delete(w.overview.frames)
	delete(w.overview.column)
	overview_deletion_end(&w.overview)
	w.overview = {}
}

// A workspace change the window cannot show now, as while it is minimized, does not play later.
workspace_overview_lapse :: proc(w: ^Window) {
	w.overview.shown = 0
	overview_deletion_end(&w.overview)
}

workspace_overview_animating :: proc(w: ^Window) -> bool {
	return ui.motion_active(w.overview.progress)
}

workspace_overview_animate :: proc(app: ^App, w: ^Window, frame: ui.Frame_Time) -> bool {
	changed := ui.motion_update(&w.overview.progress, frame)
	if !workspace_overview_animating(w) {
		w.overview.leg_count = 0
		if w.overview.deletion.phase == .Playing {overview_deletion_end(&w.overview)}
	}
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

// The card the shown workspace draws live in, by column index; -1 when the column does not list it.
workspace_overview_shown_card :: proc(w: ^Window) -> int {
	return overview_index(&w.overview, w.overview.shown)
}

// After a relayout: a window that now shows another workspace keeps its last frame of the one it left and
// flies from wherever the overview looks to the workspace it shows.
workspace_overview_placed :: proc(app: ^App, w: ^Window) {
	o := &w.overview
	before := o.shown
	o.shown = w.workspace != nil ? w.workspace.id : 0
	if before == 0 || o.shown == 0 || before == o.shown {return}
	o.left = before
	overview_deletion_end(o)
	camera, flying := workspace_overview_camera(w)
	carried := overview_column_rebuild(app, o, flying ? camera.card : -1)
	overview_frames_prune(o)
	overview_frame_keep(app, w, before)
	from, to := overview_index(o, before), overview_index(o, o.shown)
	motion := settings.motion_resolve(&app.settings, .Workspace)
	duration := settings.motion_duration(&app.settings, motion)
	if flying && carried >= 0 {camera.card = carried} else {camera = {1, f32(from)}}
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
	total: f32
	for leg in o.legs[:o.leg_count] {total += leg.share}
	overview_flight_start(app, o, total)
}

// Starts the planned legs, whose shares total `total` switch units: they become shares of the whole
// flight, which lasts the Switch Workspace duration in proportion to a switch to a neighbour.
@(private)
overview_flight_start :: proc(app: ^App, o: ^Workspace_Overview, total: f32) {
	motion := settings.motion_resolve(&app.settings, .Workspace)
	duration := settings.motion_duration(&app.settings, motion)
	for &leg in o.legs[:o.leg_count] {leg.share /= total}
	neighbour := OVERVIEW_ZOOM_OUT + OVERVIEW_TRAVEL + OVERVIEW_TRAVEL_STEP + OVERVIEW_ZOOM_IN
	o.progress = {}
	whole := time.Duration(f64(duration) * f64(total / neighbour))
	ui.motion_target_curve(&o.progress, 1, whole, ui.EASING_CURVES[.Linear], true)
}

@(private)
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

// Lists the column afresh from the workspace list, counting only listed workspaces, and returns where card
// `card` of the old column lies in it: as far from the nearest old card still listed as it was; -1 when
// that card is gone.
@(private)
overview_column_rebuild :: proc(app: ^App, o: ^Workspace_Overview, card: f32) -> f32 {
	nearest := int(math.round(card))
	kept: u32
	if nearest >= 0 && nearest < len(o.column) {kept = o.column[nearest]}
	clear(&o.column)
	for workspace in app.workspaces {
		if !workspace_eligible(app, workspace) {continue}
		if _, err := append(&o.column, workspace.id); err != nil {clear(&o.column); return -1}
	}
	index := overview_index(o, kept)
	return index >= 0 ? f32(index) + card - f32(nearest) : -1
}

// The workspace's place in the column; -1 when it has none.
@(private)
overview_index :: proc(o: ^Workspace_Overview, id: u32) -> int {
	for listed, index in o.column {if listed == id {return index}}
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

// Forgets the frames of workspaces the column no longer lists.
@(private = "file")
overview_frames_prune :: proc(o: ^Workspace_Overview) {
	for i := len(o.frames) - 1; i >= 0; i -= 1 {
		if overview_index(o, o.frames[i].workspace) >= 0 {continue}
		render.draw_list_destroy(&o.frames[i].list)
		unordered_remove(&o.frames, i)
	}
}

// The rectangle the card at `slot`, a column index or a place between two, takes on screen under `camera`.
@(private = "file")
overview_card :: proc(w: ^Window, camera: Overview_Camera, slot: f32) -> render.Rect {
	width, height := f32(w.width), f32(w.height)
	pitch := height + OVERVIEW_GAP * w.scale
	s := camera.scale
	x := width / 2 - width / 2 * s
	y := height / 2 - (camera.card * pitch + height / 2) * s + slot * pitch * s
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
	for _, index in w.overview.column {
		if overview_deletion_crumbling(w, index) {continue}
		r := overview_card(w, camera, overview_slot(w, index))
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
	target := workspace_overview_shown_card(w)
	card := overview_card(w, camera, overview_slot(w, target))
	render.draw_scale(&w.list, content, {}, camera.scale)
	render.draw_translate(&w.list, content, {card.x, card.y}, card)
	for id, index in o.column {
		if index == target || overview_deletion_crumbling(w, index) {continue}
		r := overview_card(w, camera, overview_slot(w, index))
		if !overview_visible(w, r) {continue}
		if overview_card_content_draw(app, w, id, r, camera.scale) != .None {return .Ok}
	}
	return overview_marks_draw(app, w, camera, target)
}

// Draws the last frame this window kept of workspace `id`, or an empty card, shrunk by `scale` into `r`.
@(private)
overview_card_content_draw :: proc(
	app: ^App,
	w: ^Window,
	id: u32,
	r: render.Rect,
	scale: f32,
) -> render.Error {
	window := render.Rect{0, 0, f32(w.width), f32(w.height)}
	mark := render.draw_mark(&w.list)
	if err := render.push_layer(&w.list, window); err != .None {return err}
	_ = render.push_rect(&w.list, {rect = window, color = app.theme.window})
	atlas := render.atlas_generation(app.device)
	for &frame in w.overview.frames {
		if frame.workspace != id || frame.atlas != atlas {continue}
		if err := render.append_list(&w.list, &frame.list); err != .None {return err}
	}
	render.draw_scale(&w.list, mark, {}, scale)
	render.draw_translate(&w.list, mark, {r.x, r.y}, r)
	return .None
}

// Over the column: each card's outline and label, a ring in the chosen workspace's colour around its card,
// and a title bar naming it, all as strong as the column is zoomed out. A workspace deleted during the
// flight keeps only its outline, unless the flight is its deletion: then its card has a ring in the error
// colour and a struck-through label until it crumbles, and the dust rises over everything but the title
// bar, which reads Deleting until the cards below start to slide up.
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
	deletion := &w.overview.deletion
	mark := render.draw_mark(&w.list)
	if render.push_layer(&w.list, window) != .None {return .Ok}
	label_height := w.ui_text.line_height
	for id, index in w.overview.column {
		if overview_deletion_crumbling(w, index) {continue}
		r := overview_card(w, camera, overview_slot(w, index))
		if !overview_visible(w, r) {continue}
		if deletion.phase == .Playing && index == deletion.card {
			if result := overview_deletion_marks_draw(app, w, r); result != .Ok {return result}
			continue
		}
		_ = render.push_rect(&w.list, {rect = r, color = app.theme.border, stroke = max(1, s)})
		workspace := workspace_find(app, id)
		if workspace == nil {continue}
		chosen := index == target
		if chosen {
			ring := render.Rect{r.x - 5 * s, r.y - 5 * s, r.width + 10 * s, r.height + 10 * s}
			color := workspace_icon_tint(workspace.icon.tint, app.theme.accent)
			radius := ui.RADIUS_OVERLAY * s
			_ = render.push_rect(&w.list, {rect = ring, color = color, radius = radius, stroke = 2 * s})
		}
		area := render.Rect{r.x, r.y - 8 * s - label_height, r.width, label_height}
		style: Overview_Label_Style = chosen ? .Chosen : .Plain
		if result := overview_label_draw(app, w, overview_label_of(workspace), area, style); result != .Ok {
			return result
		}
	}
	ui.fade_draw(&w.list, mark, {opacity = out})
	if overview_deletion_crumbling(w, deletion.card) {
		r := overview_card(w, camera, overview_slot(w, deletion.card))
		if result := overview_deletion_dust_draw(app, w, r); result != .Ok {return result}
	}
	bar_mark := render.draw_mark(&w.list)
	bar := render.Rect{0, 0, window.width, ui.TITLE_BAR_HEIGHT * s}
	if render.push_layer(&w.list, bar) != .None {return .Ok}
	_ = render.push_rect(&w.list, {rect = bar, color = app.theme.tab_bar})
	_, slide, deleting := workspace_overview_deletion(w)
	deleting = deleting && slide <= 0
	prefix := deleting ? "Deleting" : "Switching to"
	baseline := bar.y + (bar.height - label_height) / 2 + w.ui_text.ascent
	x := 78 * s
	prefix_ink := deleting ? app.theme.error : app.theme.muted
	if result := ui.draw_text(&w.ui_text, &w.list, prefix, x, baseline, prefix_ink); result != .Ok {
		return result
	}
	x += ui.text_width(&w.ui_text, prefix) + ui.SPACE_2 * s
	named: Maybe(Overview_Label)
	if deleting {
		named = deletion.label
	} else if workspace := w.workspace; workspace != nil {
		named = overview_label_of(workspace)
	}
	if label, ok := named.?; ok {
		size := ui.ICON_BUTTON * s
		icon := render.Rect{x, bar.y + (bar.height - size) / 2, size, size}
		if result := workspace_icon_draw(w, label.icon, icon, app.theme.text); result != .Ok {return result}
		x += size + ui.SPACE_2 * s
		if result := ui.draw_text(&w.ui_text, &w.list, label.name, x, baseline, app.theme.text);
		   result != .Ok {return result}
	}
	ui.fade_draw(&w.list, bar_mark, {opacity = out})
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

Overview_Label_Style :: enum {
	Plain,
	// The card the flight lands on.
	Chosen,
	// The card of the workspace being deleted: its name struck through in the error colour.
	Deleted,
}

// One card's label: the workspace's icon and name, and how many tabs and panes it holds.
@(private)
overview_label_draw :: proc(
	app: ^App,
	w: ^Window,
	label: Overview_Label,
	area: render.Rect,
	style: Overview_Label_Style,
) -> render.Build_Status {
	s := w.scale
	size := ui.ICON_INDICATOR * s
	icon := render.Rect{area.x, area.y + (area.height - size) / 2, size, size}
	ink := style == .Plain ? app.theme.muted : app.theme.text
	if result := workspace_icon_draw(w, label.icon, icon, ink); result != .Ok {return result}
	right := area.x + area.width
	x := icon.x + size + ui.SPACE_2 * s
	baseline := area.y + w.ui_text.ascent
	name_ink := style == .Deleted ? app.theme.error : ink
	if result := ui.draw_fading_text(&w.ui_text, &w.list, label.name, x, baseline, name_ink, right - x);
	   result != .Ok {return result}
	name_width := ui.text_width(&w.ui_text, label.name)
	if style == .Deleted {
		strike := render.Rect{x, baseline - w.ui_text.ascent * 0.32, min(name_width, right - x), max(1, 1.5 * s)}
		_ = render.push_rect(&w.list, {rect = strike, color = app.theme.error})
	}
	// A workspace deleted because its last tab closed has nothing left to count.
	if label.tabs == 0 {return .Ok}
	x += name_width + ui.SPACE_2 * s
	buffer: [64]u8
	detail := fmt.bprintf(
		buffer[:],
		"%d %s · %d %s",
		label.tabs,
		label.tabs == 1 ? "tab" : "tabs",
		label.panes,
		label.panes == 1 ? "pane" : "panes",
	)
	return ui.draw_fading_text(&w.ui_text, &w.list, detail, x, baseline, app.theme.faint, right - x)
}
