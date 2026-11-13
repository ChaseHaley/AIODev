package main

import "aio:render"
import "aio:settings"
import "aio:ui"
import "core:math"
import "core:strings"

// Deleting a workspace without closing a window plays the deletion in the overview (WORK-444). In a window
// that showed it, the switch to its replacement becomes the deletion: the window zooms out onto its card,
// whose label is struck through and ring turns the error colour, then the card, its outline, ring and
// label crumble to dust from the bottom left to the top right, the dust rising over the cards above.
// Meanwhile the cards below slide up into the gap, and the window zooms into the workspace now in its
// place. In the window the deletion was asked from, when it shows another workspace, the window zooms out,
// looks at the deleted card while it crumbles and the cards below close up, and zooms back into its own.
// Only drawing moves: the workspace is gone at once. The Switch Workspace motion settings pace it, in
// proportion to a switch to a neighbour.
Overview_Deletion :: struct {
	phase:      Overview_Deletion_Phase,
	// The deleted workspace, by id, its card in the column and what its label showed; the strings are owned.
	workspace:  u32,
	card:       int,
	label:      Overview_Label,
	// Where the dust and the slide run, as shares of the flight's progress.
	dust_from:  f32,
	dust_to:    f32,
	slide_from: f32,
	slide_to:   f32,
	// The slide's easing, the same as the switch's travel.
	slide_curve: settings.Motion_Curve,
	// The dust's texture, once the first frame of dust has drawn the card into it, and where it lies
	// relative to the card's corner. A failed capture fades the card instead.
	key:        u64,
	capture:    render.Rect,
	failed:     bool,
}

Overview_Deletion_Phase :: enum {
	None,
	Playing,
}

// What a card's label shows: the workspace's icon, its name, and how many tabs and panes it holds.
Overview_Label :: struct {
	icon:         Workspace_Icon,
	name:         string,
	tabs, panes:  int,
}

// The legs of a deletion, in the units of the switch legs: the dust's length, where in it the slide
// starts, and the slide's length.
@(private = "file")
OVERVIEW_DUST :: f32(700) / 470
@(private = "file")
OVERVIEW_SLIDE_AT :: f32(0.72)
@(private = "file")
OVERVIEW_SLIDE :: f32(180) / 470
// How far the fastest grain rises, in DIPs.
@(private = "file")
OVERVIEW_DUST_RISE :: f32(260)

overview_label_of :: proc(workspace: ^Workspace) -> Overview_Label {
	panes := 0
	for tab in workspace.tabs {panes += tab_pane_count(tab)}
	return {workspace.icon, workspace.name, len(workspace.tabs), panes}
}

// `workspace` is being deleted, still listed. Each window whose switch away from it is just starting plays
// that switch as its deletion; `actor`, the window the deletion was asked from, plays it over its own
// workspace when it shows another.
workspace_overview_deleted :: proc(app: ^App, workspace: ^Workspace, actor: ^Window) {
	actor_played := false
	for w in app.windows {
		o := &w.overview
		_, flying := workspace_overview_camera(w)
		if !flying || o.left != workspace.id || o.deletion.phase != .None {continue}
		from, to := overview_index(o, workspace.id), overview_index(o, o.shown)
		if from < 0 || to < 0 {continue}
		camera, _ := workspace_overview_camera(w)
		overview_deletion_start(app, w, workspace, camera, from, to)
		actor_played ||= w == actor
	}
	if actor == nil || actor_played || actor.workspace == nil || actor.workspace == workspace {return}
	if actor.phase == .Preparing || window_minimized(actor) || !app.animations {return}
	o := &actor.overview
	camera, flying := workspace_overview_camera(actor)
	carried := overview_column_rebuild(app, o, flying ? camera.card : -1)
	from, to := overview_index(o, workspace.id), overview_index(o, actor.workspace.id)
	if from < 0 || to < 0 {return}
	if flying && carried >= 0 {camera.card = carried} else {camera = {1, f32(to)}}
	overview_deletion_start(app, actor, workspace, camera, from, to)
}

// Plans and starts w's deletion flight of `workspace`, card `from`, landing on card `to`.
@(private = "file")
overview_deletion_start :: proc(
	app: ^App,
	w: ^Window,
	workspace: ^Workspace,
	camera: Overview_Camera,
	from, to: int,
) {
	o := &w.overview
	overview_deletion_end(o)
	label := overview_label_of(workspace)
	name, name_err := strings.clone(label.name)
	emoji, emoji_err := strings.clone(label.icon.emoji)
	if name_err != nil || emoji_err != nil {delete(name); delete(emoji); return}
	label.name, label.icon.emoji = name, emoji
	o.deletion = {workspace = workspace.id, label = label}
	motion := settings.motion_resolve(&app.settings, .Workspace)
	if settings.motion_duration(&app.settings, motion) <= 0 {overview_deletion_end(o); return}
	total := overview_deletion_plan(app, o, camera, from, to, motion.curve)
	overview_flight_start(app, o, total)
	w.dirty = true
}

@(private)
overview_deletion_end :: proc(o: ^Workspace_Overview) {
	delete(o.deletion.label.name)
	delete(o.deletion.label.icon.emoji)
	o.deletion = {}
}

// Where the dust and the slide stand now, each from 0 to 1; false when no deletion is playing.
workspace_overview_deletion :: proc(w: ^Window) -> (dust, slide: f32, playing: bool) {
	d := &w.overview.deletion
	if d.phase != .Playing || !workspace_overview_animating(w) {return 0, 0, false}
	t := w.overview.progress.value
	return overview_share(t, d.dust_from, d.dust_to), overview_share(t, d.slide_from, d.slide_to), true
}

@(private = "file")
overview_share :: proc(t, from, to: f32) -> f32 {
	return to > from ? clamp((t - from) / (to - from), 0, 1) : (t >= to ? 1 : 0)
}

// Plans the deletion of the card `from` as a flight to card `to` from `camera`: zoom out, travel to look at
// the deleted card (between it and the camera's card when they are neighbours, so both show), hold while
// it crumbles, then, as the cards below slide up into its place, travel to where card `to` ends up, hold
// until the dust has gone and zoom in. Returns the legs' total in switch units.
@(private = "file")
overview_deletion_plan :: proc(
	app: ^App,
	o: ^Workspace_Overview,
	camera: Overview_Camera,
	from, to: int,
	curve: settings.Motion_Curve,
) -> f32 {
	smooth, _ := settings.motion_curve_find(&app.settings, "smooth")
	d := &o.deletion
	d.phase, d.card, d.slide_curve = .Playing, from, smooth
	out := Overview_Camera{OVERVIEW_SCALE, camera.card}
	held := out
	gap := f32(from) - camera.card
	held.card = abs(gap) > 1.001 ? f32(from) : camera.card + gap / 2
	slot := f32(to > from ? to - 1 : to)
	landed := Overview_Camera{OVERVIEW_SCALE, slot}
	zoom_out := OVERVIEW_ZOOM_OUT * max((camera.scale - OVERVIEW_SCALE) / (1 - OVERVIEW_SCALE), 0)
	distance := abs(held.card - out.card)
	travel := distance > 0.001 ? OVERVIEW_TRAVEL + OVERVIEW_TRAVEL_STEP * min(distance, 3) : 0
	o.leg_count = 0
	overview_leg_add(o, zoom_out, camera, out, smooth)
	overview_leg_add(o, travel, out, held, smooth)
	overview_leg_add(o, OVERVIEW_DUST * OVERVIEW_SLIDE_AT, held, held, smooth)
	overview_leg_add(o, OVERVIEW_SLIDE, held, landed, smooth)
	overview_leg_add(o, OVERVIEW_DUST * (1 - OVERVIEW_SLIDE_AT) - OVERVIEW_SLIDE, landed, landed, smooth)
	overview_leg_add(o, OVERVIEW_ZOOM_IN, landed, {1, slot}, curve)
	before := zoom_out + travel
	total := before + OVERVIEW_DUST + OVERVIEW_ZOOM_IN
	d.dust_from = before / total
	d.dust_to = (before + OVERVIEW_DUST) / total
	d.slide_from = (before + OVERVIEW_DUST * OVERVIEW_SLIDE_AT) / total
	d.slide_to = d.slide_from + OVERVIEW_SLIDE / total
	return total
}

// Where card `index` lies in the column now: its index, less the share of the gap a deletion has closed
// for the cards below the deleted one.
@(private)
overview_slot :: proc(w: ^Window, index: int) -> f32 {
	d := &w.overview.deletion
	if d.phase != .Playing || index <= d.card {return f32(index)}
	_, slide, playing := workspace_overview_deletion(w)
	if !playing {return f32(index)}
	return f32(index) - settings.motion_curve_ease(d.slide_curve, slide)
}

// Whether the deleted card draws as dust now rather than as a card.
@(private)
overview_deletion_crumbling :: proc(w: ^Window, index: int) -> bool {
	d := &w.overview.deletion
	if d.phase != .Playing || index != d.card {return false}
	dust, _, playing := workspace_overview_deletion(w)
	return playing && dust > 0
}

// The deleted card's marks at `r`: its outline, the ring in the error colour and its struck-through label.
@(private)
overview_deletion_marks_draw :: proc(app: ^App, w: ^Window, r: render.Rect) -> render.Build_Status {
	s := w.scale
	_ = render.push_rect(&w.list, {rect = r, color = app.theme.border, stroke = max(1, s)})
	ring := render.Rect{r.x - 5 * s, r.y - 5 * s, r.width + 10 * s, r.height + 10 * s}
	radius := ui.RADIUS_OVERLAY * s
	_ = render.push_rect(&w.list, {rect = ring, color = app.theme.error, radius = radius, stroke = 2 * s})
	label_height := w.ui_text.line_height
	area := render.Rect{r.x, r.y - 8 * s - label_height, r.width, label_height}
	return overview_label_draw(app, w, w.overview.deletion.label, area, .Deleted)
}

// The deleted card crumbling at `r`, its place in the column now: from the first frame of dust, its card
// and marks drawn once into a texture that then draws as dust. When that texture cannot be made, the card
// and marks fade out instead.
@(private)
overview_deletion_dust_draw :: proc(app: ^App, w: ^Window, r: render.Rect) -> render.Build_Status {
	o := &w.overview
	d := &o.deletion
	dust, _, _ := workspace_overview_deletion(w)
	if d.key == 0 && !d.failed {
		if status := overview_deletion_capture(app, w, r); status != .Ok {return status}
	}
	if d.key != 0 {
		// Ash a little warmer and dimmer than muted text, so the dust reads as ash, not as light.
		ash := app.theme.muted
		ash.r, ash.g, ash.b = ash.r * 0.86, ash.g * 0.82, ash.b * 0.74
		rect := render.Rect{r.x + d.capture.x, r.y + d.capture.y, d.capture.width, d.capture.height}
		_ = render.push_layer(&w.list, {0, 0, f32(w.width), f32(w.height)})
		_ = render.push_image(
			&w.list,
			{
				rect = rect,
				uv = {0, 0, 1, 1},
				key = d.key,
				dust = {
					progress = dust,
					seed = math.mod(f32(d.workspace) * 0.618034, 1),
					rise = OVERVIEW_DUST_RISE * w.scale,
					grain = max(1, w.scale),
					ash = ash,
				},
			},
		)
		return .Ok
	}
	mark := render.draw_mark(&w.list)
	if status := overview_deletion_card_draw(app, w, r); status != .Ok {return status}
	ui.fade_draw(&w.list, mark, {opacity = 1 - dust})
	return .Ok
}

// The deleted card at `r` with its marks, as the dust starts from.
@(private = "file")
overview_deletion_card_draw :: proc(app: ^App, w: ^Window, r: render.Rect) -> render.Build_Status {
	window := render.Rect{0, 0, f32(w.width), f32(w.height)}
	if overview_card_content_draw(app, w, w.overview.deletion.workspace, r, OVERVIEW_SCALE) != .None {
		return .Ok
	}
	if render.push_layer(&w.list, window) != .None {return .Ok}
	return overview_deletion_marks_draw(app, w, r)
}

// Draws the deleted card and its marks at `r` into a texture of their own, whole pixels around them, for
// the dust. Nothing it draws stays in the frame.
@(private = "file")
overview_deletion_capture :: proc(app: ^App, w: ^Window, r: render.Rect) -> render.Build_Status {
	d := &w.overview.deletion
	s := w.scale
	pad := 8 * s
	top := 10 * s + w.ui_text.line_height
	origin := [2]f32{math.floor(r.x - pad), math.floor(r.y - top)}
	width := int(math.ceil(r.x + r.width + pad - origin.x))
	height := int(math.ceil(r.y + r.height + pad - origin.y))
	mark := render.draw_mark(&w.list)
	if status := overview_deletion_card_draw(app, w, r); status != .Ok {
		render.draw_list_truncate(&w.list, mark)
		return status
	}
	capture := render.draw_list_init(context.temp_allocator)
	err := render.draw_list_copy(&capture, &w.list, mark, render.draw_mark(&w.list))
	render.draw_list_truncate(&w.list, mark)
	if err == .None {
		render.draw_translate(&capture, {}, -origin, {0, 0, f32(width), f32(height)})
		key := render.IMAGE_KEY_RENDERED | u64(d.workspace) << 20 | (u64(w.id) & 0xfffff)
		if app.device != nil {err = render.image_render(app.device, key, width, height, &capture)}
		if app.device == nil {err = .Invalid_Argument}
		if err == .None {
			d.key = key
			d.capture = {origin.x - r.x, origin.y - r.y, f32(width), f32(height)}
			return .Ok
		}
	}
	d.failed = true
	return .Ok
}
