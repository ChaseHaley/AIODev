package main

import "aio:layout"
import "aio:render"
import "aio:settings"
import "aio:ui"
import "core:math"

// When a split or a close changes a tab's panes, they ease from where they were drawn to their new
// rectangles together, each within its container, the tiling or its floating group; nothing here depends
// on which. A new pane opens out of the side of the pane it divides, and a closed pane keeps showing its
// last frame while it collapses under the neighbour taking its place. Only drawing moves: grids, hit
// targets and input take the new layout at once (a closed pane's session ends at once too), and each
// pane's content keeps its new size, anchored to the moving frame's corner and clipped to it. The motion
// settings of what armed the change set its duration and curve, and for a split or a close whether the
// pane opens or collapses at the side or pops, fades or slides in or out in place.
Pane_Motion :: struct {
	moving: ui.Layout_Motion,
	// The tab layout the window last placed; placing another one, a tab switch, never moves.
	tree:   ^layout.Layout,
	// The next placement of this tab layout moves: a split or close changed it, and `cause` says which
	// motion settings it takes.
	armed:  ^layout.Layout,
	cause:  settings.Motion_Context,
	// The tiled pane drawn above the others while the motion runs, as a zoomed pane shrinking back over the
	// panes it uncovers, and the one the next armed placement raises.
	raised, raise_next: Maybe(u64),
	// The bars between tiled panes as drawn; see pane_bars.
	bars:   [dynamic]layout.Edge,
	// Where each pane, float frame and chrome region drew in the window's last frame, so one that goes
	// away can keep showing it, and where a frame or region starts moving from.
	drawn:  [dynamic]Pane_Drawn,
	// Closed panes collapsing away, each drawn from a copy of its last frame.
	ghosts: [dynamic]Pane_Ghost,
	// What the last placement showed, which the next compares with to see whether a single-pane view shows
	// another pane; see pane_slide_toward.
	stage:  Pane_Stage,
	// The panes draw above the chrome while they move: a pane growing over the window or shrinking off it,
	// or panes sliding across it, with the chrome staying where it is beneath them.
	over_chrome: bool,
	// The area panes slide within while a single-pane view shows another pane; what they draw is kept
	// inside it. Nil for any other motion.
	slide:  Maybe(render.Rect),
	// How far the window's client area moved on the screen, as it went full screen or back, since the last
	// placement, which starts its motion from where everything was on the screen.
	shift:  [2]f32,
}

// What a placement showed: the tab, by ids that outlive a closed tab or workspace and by the index each
// had then, and in a single-pane view, the tiled pane it showed, by its motion key.
Pane_Stage :: struct {
	workspace, tab:             u32,
	workspace_index, tab_index: int,
	solo:                       bool,
	pane:                       u64,
}

@(private = "file")
Pane_Drawn :: struct {
	key, container: u64,
	from, to:       render.Draw_Mark,
	rect:           layout.Rect,
}

@(private = "file")
Pane_Ghost :: struct {
	// What went away, and the pane it collapses beneath; one sent away by a hint, such as a float into its
	// capsule, has none and draws on its own (see pane_ghosts_draw_alone).
	key:       u64,
	successor: Maybe(u64),
	container: u64,
	// Where the copied drawing was drawn, and the glyph atlas it refers to.
	rect:      layout.Rect,
	list:      render.Draw_List,
	atlas:     u64,
}

// Motion keys: a pane's content (below these bits), a float's frame by its Float.id, and a chrome region:
// the docked tab rail, the Activity panel and the title bar.
PANE_MOTION_FRAME :: u64(1) << 62
PANE_MOTION_CHROME :: u64(2) << 62
PANE_MOTION_RAIL :: PANE_MOTION_CHROME | 1
PANE_MOTION_PANEL :: PANE_MOTION_CHROME | 2
PANE_MOTION_TITLE :: PANE_MOTION_CHROME | 3

// A chrome region drawing from the motion: its background at `shown`, and its content laid out at `rect`,
// the layout's rectangle, then moved with `shown`'s corner and clipped to it, as a pane's content is.
Pane_Region_Draw :: struct {
	key:           u64,
	rect, shown:   render.Rect,
	from, content: render.Draw_Mark,
}

// What the window showed before a relayout: the panes, float frames and chrome as drawn, and the float
// capsules by Float.id, which a restored float grows out of.
Pane_Motion_Shown :: struct {
	places:   []ui.Layout_Place,
	capsules: []ui.Layout_Hint,
}

// The next relayout of w's visible tab eases its panes to their new places with `motion`'s settings;
// `raised` draws above the other tiled panes while they move.
pane_motion_arm :: proc(w: ^Window, motion: settings.Motion_Context, raised: Maybe(layout.Content) = nil) {
	w.pane_motion.armed = window_tree(w)
	w.pane_motion.cause = motion
	w.pane_motion.raise_next = nil
	if content, ok := raised.?; ok {w.pane_motion.raise_next = pane_motion_key(content)}
}

// Whether `pane` draws above the other tiled panes this frame; see Pane_Motion.raised.
pane_motion_raised :: proc(w: ^Window, pane: layout.Pane_Rect) -> bool {
	raised, ok := w.pane_motion.raised.?
	return ok && pane_motion_animating(w) && raised == pane_motion_key(pane.content)
}

pane_motion_destroy :: proc(w: ^Window) {
	ui.layout_motion_destroy(&w.pane_motion.moving)
	pane_ghosts_clear(&w.pane_motion)
	delete(w.pane_motion.bars)
	delete(w.pane_motion.drawn)
	delete(w.pane_motion.ghosts)
}

pane_motion_animating :: proc(w: ^Window) -> bool {
	return ui.layout_motion_active(&w.pane_motion.moving)
}

// Whether the panes draw above the chrome this frame; see Pane_Motion.over_chrome.
pane_motion_over_chrome :: proc(w: ^Window) -> bool {
	return w.pane_motion.over_chrome && pane_motion_animating(w)
}

// Keeps what the panes drew since `mark` inside the area they slide within, while they slide.
pane_motion_slide_clip :: proc(w: ^Window, mark: render.Draw_Mark) {
	stage, sliding := w.pane_motion.slide.?
	if sliding && pane_motion_animating(w) {render.draw_translate(&w.list, mark, {}, stage)}
}

// The window's client area moved on the screen by `-by`; see Pane_Motion.shift.
pane_motion_shift :: proc(w: ^Window, by: [2]f32) {
	w.pane_motion.shift += by
}

// A change the window cannot show now, as while it is minimized, neither moves nor slides when it is
// shown later.
pane_motion_lapse :: proc(w: ^Window) {
	w.pane_motion.armed, w.pane_motion.stage, w.pane_motion.shift = nil, {}, {}
}

pane_motion_animate :: proc(app: ^App, w: ^Window, frame: ui.Frame_Time) -> bool {
	changed := ui.layout_motion_update(&w.pane_motion.moving, frame)
	if changed {pane_bars_refresh(app, w)}
	if !pane_motion_animating(w) {pane_ghosts_clear(&w.pane_motion)}
	return changed
}

// Where a pane draws this frame; its layout rectangle when nothing moves.
pane_motion_rect :: proc(w: ^Window, pane: layout.Pane_Rect) -> layout.Rect {
	r := pane.rect
	key := pane_motion_key(pane.content)
	shown := ui.layout_motion_rect(&w.pane_motion.moving, key, {r.x, r.y, r.width, r.height})
	return {shown.x, shown.y, shown.width, shown.height}
}

// Where a float's frame draws this frame, by its Float.id; `frame` when it is not moving.
pane_motion_frame :: proc(w: ^Window, id: u64, frame: layout.Rect) -> layout.Rect {
	r := frame
	shown := ui.layout_motion_rect(&w.pane_motion.moving, PANE_MOTION_FRAME | id, {r.x, r.y, r.width, r.height})
	return {shown.x, shown.y, shown.width, shown.height}
}

// Starts drawing chrome region `key`, which the layout puts at `rect`: draw its background at `shown`,
// then call pane_motion_region_content before its content and pane_motion_region_end after it.
pane_motion_region_begin :: proc(w: ^Window, key: u64, rect: render.Rect) -> Pane_Region_Draw {
	shown := ui.layout_motion_rect(&w.pane_motion.moving, key, rect)
	mark := render.draw_mark(&w.list)
	return {key, rect, shown, mark, mark}
}

pane_motion_region_content :: proc(w: ^Window, region: ^Pane_Region_Draw) {
	region.content = render.draw_mark(&w.list)
}

pane_motion_region_end :: proc(w: ^Window, region: ^Pane_Region_Draw) {
	r, s := region.rect, region.shown
	if s != r {
		offset := [2]f32{math.round(s.x - r.x), math.round(s.y - r.y)}
		render.draw_translate(&w.list, region.content, offset, s)
	}
	pane_motion_region_drawn(w, region.key, {s.x, s.y, s.width, s.height}, region.from)
}

// What the window shows now, collected before a relayout replaces w.panes; float frames come first, so a
// float's frame copy draws beneath its panes' copies.
@(require_results)
pane_motion_shown :: proc(w: ^Window) -> Pane_Motion_Shown {
	places := make([dynamic]ui.Layout_Place, 0, len(w.panes) + 4, context.temp_allocator)
	// Float frames, chrome, and copies still on their way out, from where the last frame drew them.
	outer: for drawn in w.pane_motion.drawn {
		if drawn.key & (PANE_MOTION_FRAME | PANE_MOTION_CHROME) == 0 {
			for pane in w.panes {if pane_motion_key(pane.content) == drawn.key {continue outer}}
		}
		r := drawn.rect
		append(&places, ui.Layout_Place{drawn.key, {r.x, r.y, r.width, r.height}, drawn.container})
	}
	pane_places_add(w, &places, true)
	return {places[:], pane_motion_capsules(w)}
}

// The float capsules the window shows, by Float.id.
@(private = "file")
pane_motion_capsules :: proc(w: ^Window) -> []ui.Layout_Hint {
	capsules := make([dynamic]ui.Layout_Hint, 0, len(w.float_capsules), context.temp_allocator)
	if tree := window_tree(w); tree != nil {
		for capsule in w.float_capsules {
			if floating, ok := layout.float_of(tree, capsule.root); ok {
				append(&capsules, ui.Layout_Hint{floating.id, capsule.rect})
			}
		}
	}
	return capsules[:]
}

// After a relayout placed w.panes: a single-pane view showing another pane, tab or workspace slides to it,
// an armed change of the same tab starts the motion from `shown`, any other change of that tab carries a
// running motion to the new rectangles, and another tab stops it.
pane_motion_placed :: proc(app: ^App, w: ^Window, shown: Pane_Motion_Shown) {
	m := &w.pane_motion
	tree := window_tree(w)
	armed := m.armed != nil && m.armed == tree && m.tree == tree
	raise := m.raise_next
	m.armed, m.raise_next = nil, nil
	before := m.stage
	m.stage = pane_stage(app, w)
	// The temporary places are this placement's own, so they move with the screen in place.
	places := shown.places
	for &place in places {place.rect.x, place.rect.y = place.rect.x + m.shift.x, place.rect.y + m.shift.y}
	m.shift = {}
	defer m.tree = tree
	if toward, slides := pane_slide_toward(app, w, before, m.stage).?; slides && !armed {
		pane_slide_begin(app, w, places, toward)
		return
	}
	if m.tree != tree {
		ui.layout_motion_stop(&m.moving)
		pane_ghosts_clear(m)
		return
	}
	defer pane_bars_refresh(app, w)
	targets := pane_motion_targets(app, w)
	if !armed {
		ui.layout_motion_retarget(&m.moving, targets)
		return
	}
	pane_ghosts_clear(m)
	m.raised, m.slide = raise, nil
	// A view grows the focused pane over everything else, or shrinks it back off it, so nothing else moves:
	// what it covers stays drawn where it was until covered, and what it uncovers is already in place.
	m.over_chrome = m.cause == .View
	hints := pane_motion_hints(app, w, shown, targets)
	if m.over_chrome {hints = pane_hints_in_place(places, targets)}
	motion := settings.motion_resolve(&app.settings, m.cause)
	duration := settings.motion_duration(&app.settings, motion)
	// Only a split brings a pane in, and only a close takes one away, in the ways their settings choose.
	enter, leave: settings.Motion_Effect
	if m.cause == .Split {enter = motion.effect}
	if m.cause == .Close {leave = motion.effect}
	ui.layout_motion_begin(
		&m.moving,
		shown.places,
		targets,
		duration,
		motion.curve,
		app.animations && motion.on && duration > 0,
		hints,
		enter,
		leave,
	)
	pane_ghosts_capture_leaving(app, w, shown.places)
}

// Copies the last frame of everything leaving the motion that just began, while it goes.
@(private = "file")
pane_ghosts_capture_leaving :: proc(app: ^App, w: ^Window, places: []ui.Layout_Place) {
	if !pane_motion_animating(w) {return}
	for place in places {
		successor, leaving := ui.layout_motion_leaving(&w.pane_motion.moving, place.key)
		if leaving {pane_ghost_capture(app, w, place.key, successor)}
	}
}

// Holds whatever comes or goes where it is: leaving, at the rectangle it was drawn at, and entering, at the
// one the layout gives it.
@(private = "file")
pane_hints_in_place :: proc(places, targets: []ui.Layout_Place) -> []ui.Layout_Hint {
	hints := make([dynamic]ui.Layout_Hint, 0, len(places) + len(targets), context.temp_allocator)
	for place in places {
		if !pane_place_find(targets, place.key) {append(&hints, ui.Layout_Hint{place.key, place.rect})}
	}
	for target in targets {
		if !pane_place_find(places, target.key) {append(&hints, ui.Layout_Hint{target.key, target.rect})}
	}
	return hints[:]
}

// What the window shows now; see Pane_Stage.
@(private = "file")
pane_stage :: proc(app: ^App, w: ^Window) -> Pane_Stage {
	tab := selected_tab(w.workspace)
	if tab == nil {return {}}
	stage := Pane_Stage {
		workspace       = w.workspace.id,
		tab             = tab.id,
		workspace_index = -1,
		tab_index       = w.workspace.selected,
	}
	for workspace, i in app.workspaces {if workspace == w.workspace {stage.workspace_index = i}}
	if tiled := window_tiled_rects(w); pane_view_solo(w) && len(tiled) > 0 {
		stage.solo, stage.pane = true, pane_motion_key(tiled[0].content)
	}
	return stage
}

// When a single-pane view showed, or now shows, a different pane than before, the side the pane now shown
// comes in from. Another workspace comes from below when it is further down the workspace list, and from
// above when it is further up; another tab, from further along the tabs: the right of the strip, or below
// in the rail. Another pane of the same tab comes from the side it lies on in the split view.
@(private = "file")
pane_slide_toward :: proc(app: ^App, w: ^Window, before, now: Pane_Stage) -> Maybe([2]f32) {
	if before.workspace == 0 || now.workspace == 0 || !(before.solo || now.solo) {return nil}
	// A workspace or tab that is gone counts from where it was, which its successor takes.
	side :: proc(from, to: int) -> f32 {return to >= from ? 1 : -1}
	if before.workspace != now.workspace {
		from := before.workspace_index
		for workspace, i in app.workspaces {if workspace.id == before.workspace {from = i}}
		return [2]f32{0, side(from, now.workspace_index)}
	}
	if before.tab != now.tab {
		from := tab_index_by_id(w.workspace, before.tab)
		if from < 0 {from = before.tab_index}
		along := side(from, now.tab_index)
		return w.tabs_horizontal ? [2]f32{along, 0} : [2]f32{0, along}
	}
	if !before.solo || !now.solo || before.pane == now.pane {return nil}
	split := make([dynamic]layout.Pane_Rect, context.temp_allocator)
	layout.compute(window_tree(w), window_content_area_in(app, w, .None), window_gap(app, w), &split)
	old, new: Maybe(layout.Rect)
	for pane in split {
		key := pane_motion_key(pane.content)
		if key == before.pane {old = pane.rect}
		if key == now.pane {new = pane.rect}
	}
	a, had := old.?
	b, has := new.?
	if !had || !has {return nil}
	d := [2]f32{b.x + b.width / 2 - (a.x + a.width / 2), b.y + b.height / 2 - (a.y + a.height / 2)}
	if d == {} {return nil}
	if abs(d.x) >= abs(d.y) {return [2]f32{math.sign(d.x), 0}}
	return [2]f32{0, math.sign(d.y)}
}

// What the window showed slides out across the stage, the area panes take before and after, while what it
// shows now slides in from the side `toward` points to, with the Switch Pane motion settings. The
// chrome stays where it is beneath them, and what comes or goes of it does so in place.
@(private = "file")
pane_slide_begin :: proc(app: ^App, w: ^Window, places: []ui.Layout_Place, toward: [2]f32) {
	m := &w.pane_motion
	pane_ghosts_clear(m)
	defer pane_bars_refresh(app, w)
	targets := pane_motion_targets(app, w)
	// A slide still running already spans what the window showed; its panes, part way out, do not.
	before, shown := m.slide.?
	if !shown || !pane_motion_animating(w) {before, shown = pane_stage_rect(places).?}
	after, placed := pane_stage_rect(targets).?
	if !shown || !placed {
		ui.layout_motion_stop(&m.moving)
		return
	}
	left, top := min(before.x, after.x), min(before.y, after.y)
	right := max(before.x + before.width, after.x + after.width)
	bottom := max(before.y + before.height, after.y + after.height)
	stage := render.Rect{left, top, right - left, bottom - top}
	m.raised, m.over_chrome, m.slide = nil, true, stage
	gap := window_gap(app, w)
	offset := toward * ([2]f32{stage.width, stage.height} + gap)
	hints := make([dynamic]ui.Layout_Hint, 0, len(places) + len(targets), context.temp_allocator)
	for place in places {
		if pane_place_find(targets, place.key) {continue}
		r := place.rect
		if place.key & PANE_MOTION_CHROME == 0 {r.x, r.y = r.x - offset.x, r.y - offset.y}
		append(&hints, ui.Layout_Hint{place.key, r})
	}
	for target in targets {
		if pane_place_find(places, target.key) {continue}
		r := target.rect
		if target.key & PANE_MOTION_CHROME == 0 {r.x, r.y = r.x + offset.x, r.y + offset.y}
		append(&hints, ui.Layout_Hint{target.key, r})
	}
	motion := settings.motion_resolve(&app.settings, .Switch)
	duration := settings.motion_duration(&app.settings, motion)
	enabled := app.animations && motion.on && duration > 0
	ui.layout_motion_begin(&m.moving, places, targets, duration, motion.curve, enabled, hints[:])
	pane_ghosts_capture_leaving(app, w, places)
}

// The smallest rectangle holding every pane and float frame in `places`; nil when there is none.
@(private = "file")
pane_stage_rect :: proc(places: []ui.Layout_Place) -> Maybe(render.Rect) {
	lo, hi := [2]f32{math.INF_F32, math.INF_F32}, [2]f32{math.NEG_INF_F32, math.NEG_INF_F32}
	for place in places {
		if place.key & PANE_MOTION_CHROME != 0 {continue}
		r := place.rect
		lo = {min(lo.x, r.x), min(lo.y, r.y)}
		hi = {max(hi.x, r.x + r.width), max(hi.y, r.y + r.height)}
	}
	if hi.x <= lo.x || hi.y <= lo.y {return nil}
	return render.Rect{lo.x, lo.y, hi.x - lo.x, hi.y - lo.y}
}

// A float that went into its capsule shrinks into it, frame and panes together, and one that came back
// out grows from where its capsule was. Chrome that appears or goes away slides from or into the window
// edge it lies against.
@(private = "file")
pane_motion_hints :: proc(
	app: ^App,
	w: ^Window,
	shown: Pane_Motion_Shown,
	targets: []ui.Layout_Place,
) -> []ui.Layout_Hint {
	hints := make([dynamic]ui.Layout_Hint, 0, 8, context.temp_allocator)
	for key in ([?]u64{PANE_MOTION_RAIL, PANE_MOTION_PANEL}) {
		before, after := pane_place_get(shown.places, key), pane_place_get(targets, key)
		if r, gone := before.?; gone && after == nil {append(&hints, pane_region_edge(w, key, r))}
		if r, came := after.?; came && before == nil {append(&hints, pane_region_edge(w, key, r))}
	}
	now := pane_motion_capsules(w)
	// The frame and panes of float `id` in `places` that `others` does not have head for `capsule`.
	add :: proc(
		hints: ^[dynamic]ui.Layout_Hint,
		places, others: []ui.Layout_Place,
		id: u64,
		capsule: render.Rect,
	) {
		for place in places {
			if place.key != PANE_MOTION_FRAME | id && place.container != id {continue}
			if pane_place_find(others, place.key) {continue}
			append(hints, ui.Layout_Hint{place.key, capsule})
		}
	}
	for target in targets {
		if target.key & PANE_MOTION_FRAME == 0 || pane_place_find(shown.places, target.key) {continue}
		id := target.key &~ PANE_MOTION_FRAME
		for capsule in shown.capsules {
			if capsule.key == id {add(&hints, targets, shown.places, id, capsule.rect)}
		}
	}
	for place in shown.places {
		if place.key & PANE_MOTION_FRAME == 0 || pane_place_find(targets, place.key) {continue}
		id := place.key &~ PANE_MOTION_FRAME
		for capsule in now {
			if capsule.key == id {add(&hints, shown.places, targets, id, capsule.rect)}
		}
	}
	return hints[:]
}

// The zero-width rectangle on the window edge chrome region `key` at `r` slides from or into: the left
// edge for the rail and a left panel, the right edge for a right panel, and the rail's bottom for a panel
// under the tabs.
@(private = "file")
pane_region_edge :: proc(w: ^Window, key: u64, r: render.Rect) -> ui.Layout_Hint {
	edge := render.Rect{r.x, r.y, 0, r.height}
	if key == PANE_MOTION_PANEL {
		rail := rail_area(w)
		if abs(r.x - rail.x) < 1 && abs(r.width - rail.width) < 1 && r.y > rail.y + 1 {
			edge = {r.x, r.y + r.height, r.width, 0}
		} else if r.x + r.width / 2 > f32(w.width) / 2 {
			edge.x = r.x + r.width
		}
	}
	return {key, edge}
}

@(private = "file")
pane_place_get :: proc(places: []ui.Layout_Place, key: u64) -> Maybe(render.Rect) {
	for place in places {
		if place.key == key {return place.rect}
	}
	return nil
}

@(private = "file")
pane_place_find :: proc(places: []ui.Layout_Place, key: u64) -> bool {
	for place in places {
		if place.key == key {return true}
	}
	return false
}

// Notes where build_frame drew a pane, from `from` to the list's end.
pane_motion_drawn :: proc(w: ^Window, pane: layout.Pane_Rect, from: render.Draw_Mark) {
	key, to := pane_motion_key(pane.content), render.draw_mark(&w.list)
	// Without room to note it, a closed pane collapses as background instead.
	_, _ = append(&w.pane_motion.drawn, Pane_Drawn{key, pane.group, from, to, pane_motion_rect(w, pane)})
}

// Presents what build_frame drew for `pane` since `from` as its split's effect has it now.
pane_motion_present :: proc(w: ^Window, pane: layout.Pane_Rect, from: render.Draw_Mark) {
	r := pane_motion_rect(w, pane)
	pane_look_apply(w, pane_motion_key(pane.content), {r.x, r.y, r.width, r.height}, from)
}

// Notes where build_frame drew a float frame or chrome region under `key`, at `rect`, from `from` to the
// list's end. Each is its own container: it never takes an edge from another.
pane_motion_region_drawn :: proc(w: ^Window, key: u64, rect: layout.Rect, from: render.Draw_Mark) {
	to := render.draw_mark(&w.list)
	_, _ = append(&w.pane_motion.drawn, Pane_Drawn{key, key, from, to, rect})
}

// A new frame starts recording where the panes draw. An arm no relayout took, as when focus restored
// nothing, lapses here, so it never moves a later, unrelated change.
pane_motion_drawn_reset :: proc(w: ^Window) {
	clear(&w.pane_motion.drawn)
	w.pane_motion.armed, w.pane_motion.raise_next = nil, nil
}

// Draws the last frame of each closed pane collapsing beneath `pane`, just before `pane` draws, so it sits
// in the same container and stacking position: moved with its collapsing rectangle and clipped to it, or
// in place, presented by its close effect.
pane_ghosts_draw :: proc(app: ^App, w: ^Window, pane: layout.Pane_Rect) {
	if len(w.pane_motion.ghosts) == 0 {return}
	key := pane_motion_key(pane.content)
	for &ghost in w.pane_motion.ghosts {
		if successor, ok := ghost.successor.?; ok && successor == key {pane_ghost_draw(app, w, &ghost)}
	}
}

// Draws what went away on its own, such as a float shrinking into its capsule or a pane sliding away: the
// chrome regions when `chrome`, the panes otherwise, each where the live one would draw.
pane_ghosts_draw_alone :: proc(app: ^App, w: ^Window, chrome: bool) {
	ghosts := w.pane_motion.ghosts[:]
	alone :: proc(g: Pane_Ghost, kind: u64) -> bool {
		return g.successor == nil && g.key & (PANE_MOTION_FRAME | PANE_MOTION_CHROME) == kind
	}
	if chrome {
		for &ghost in ghosts {if alone(ghost, PANE_MOTION_CHROME) {pane_ghost_draw(app, w, &ghost)}}
		return
	}
	// Tiled panes beneath every float, then float by float, each frame beneath its own panes, then panes
	// whose frame stayed.
	for &pane in ghosts {if alone(pane, 0) && pane.container == 0 {pane_ghost_draw(app, w, &pane)}}
	for &frame in ghosts {
		if !alone(frame, PANE_MOTION_FRAME) {continue}
		pane_ghost_draw(app, w, &frame)
		for &pane in ghosts {
			if alone(pane, 0) && pane.container == frame.key &~ PANE_MOTION_FRAME {pane_ghost_draw(app, w, &pane)}
		}
	}
	framed :: proc(ghosts: []Pane_Ghost, container: u64) -> bool {
		for g in ghosts {if g.successor == nil && g.key == PANE_MOTION_FRAME | container {return true}}
		return false
	}
	for &pane in ghosts {
		if !alone(pane, 0) || pane.container == 0 || framed(ghosts, pane.container) {continue}
		pane_ghost_draw(app, w, &pane)
	}
}

// Draws a copy where its motion has it now, and notes it as drawn there, so a change that brings it back
// before it has gone continues from there.
@(private = "file")
pane_ghost_draw :: proc(app: ^App, w: ^Window, ghost: ^Pane_Ghost) {
	shown := ui.layout_motion_rect(&w.pane_motion.moving, ghost.key, {})
	if shown.width < 1 || shown.height < 1 || ghost.atlas != render.atlas_generation(app.device) {return}
	mark := render.draw_mark(&w.list)
	if render.append_list(&w.list, &ghost.list) != .None {return}
	offset := [2]f32{math.round(shown.x - ghost.rect.x), math.round(shown.y - ghost.rect.y)}
	render.draw_translate(&w.list, mark, offset, shown)
	pane_look_apply(w, ghost.key, shown, mark)
	to := render.draw_mark(&w.list)
	r := layout.Rect{shown.x, shown.y, shown.width, shown.height}
	_, _ = append(&w.pane_motion.drawn, Pane_Drawn{ghost.key, ghost.container, mark, to, r})
}

// The size a popping pane starts from, or ends at, as a share of its own.
@(private = "file")
PANE_POP_SCALE :: f32(0.85)

// Presents what was drawn since `mark` for the entering or leaving item `key` at `rect`, as its motion has
// it now: Pop scales it about the centre of `rect` and fades it, Fade fades it, and Slide moves it across
// the edge it opens from or collapses onto, clipped to `rect`. An item moving by its rectangle stays as
// drawn.
@(private = "file")
pane_look_apply :: proc(w: ^Window, key: u64, rect: render.Rect, mark: render.Draw_Mark) {
	look := ui.layout_motion_look(&w.pane_motion.moving, key)
	opacity := clamp(look.amount, 0, 1)
	switch look.effect {
	case .Edge:
	case .Pop:
		centre := [2]f32{rect.x + rect.width / 2, rect.y + rect.height / 2}
		render.draw_scale(&w.list, mark, centre, PANE_POP_SCALE + (1 - PANE_POP_SCALE) * look.amount)
		ui.fade_draw(&w.list, mark, {opacity = opacity})
	case .Fade:
		ui.fade_draw(&w.list, mark, {opacity = opacity})
	case .Slide:
		// A whole extent beyond the edge's side when hidden; an item that shares no edge stays put. Whole
		// pixels keep its text sharp.
		edge, away := look.from, 1 - look.amount
		offset: [2]f32
		if edge.width == 0 {
			side := edge.x < rect.x + rect.width / 2 ? f32(-1) : f32(1)
			offset.x = math.round(side * away * rect.width)
		} else if edge.height == 0 {
			side := edge.y < rect.y + rect.height / 2 ? f32(-1) : f32(1)
			offset.y = math.round(side * away * rect.height)
		}
		render.draw_translate(&w.list, mark, offset, rect)
	}
}

// Copies what the last frame drew for the pane under `key` before its drawing is lost.
@(private = "file")
pane_ghost_capture :: proc(app: ^App, w: ^Window, key: u64, successor: Maybe(u64)) {
	m := &w.pane_motion
	for drawn in m.drawn {
		if drawn.key != key {continue}
		ghost := Pane_Ghost {
			key       = key,
			successor = successor,
			container = drawn.container,
			rect      = drawn.rect,
			list      = render.draw_list_init(),
			atlas     = render.atlas_generation(app.device),
		}
		if render.draw_list_copy(&ghost.list, &w.list, drawn.from, drawn.to) != .None {
			render.draw_list_destroy(&ghost.list)
			return
		}
		if _, err := append(&m.ghosts, ghost); err != nil {render.draw_list_destroy(&ghost.list)}
		return
	}
}

@(private = "file")
pane_ghosts_clear :: proc(m: ^Pane_Motion) {
	for &ghost in m.ghosts {render.draw_list_destroy(&ghost.list)}
	clear(&m.ghosts)
}

// Where the layout now puts every pane, every shown float's frame and the chrome regions.
@(private = "file")
pane_motion_targets :: proc(app: ^App, w: ^Window) -> []ui.Layout_Place {
	places := make([dynamic]ui.Layout_Place, 0, len(w.panes) + 5, context.temp_allocator)
	if w.pane_fill != .Screen {
		bar := render.Rect{0, 0, f32(w.width), window_title_height(w)}
		append(&places, ui.Layout_Place{PANE_MOTION_TITLE, bar, PANE_MOTION_TITLE})
	}
	if rail, ok := rail_current_layout(w); ok && rail_docked(w) {
		append(&places, ui.Layout_Place{PANE_MOTION_RAIL, rail.area, PANE_MOTION_RAIL})
	}
	if panel := status_panel_rect(app, w); panel.width > 0 && panel.height > 0 {
		append(&places, ui.Layout_Place{PANE_MOTION_PANEL, panel, PANE_MOTION_PANEL})
	}
	pane_places_add(w, &places, false)
	tree := window_tree(w)
	area := floating_area(w)
	for pane in w.panes {
		if !pane.floating || pane_place_find(places[:], PANE_MOTION_FRAME | pane.group) {continue}
		frame, found := layout.float_rect(tree, layout.float_root(tree, pane.node), area)
		if !found {continue}
		key := PANE_MOTION_FRAME | pane.group
		append(&places, ui.Layout_Place{key, {frame.x, frame.y, frame.width, frame.height}, key})
	}
	return places[:]
}

@(private = "file")
pane_places_add :: proc(w: ^Window, places: ^[dynamic]ui.Layout_Place, drawn: bool) {
	for pane in w.panes {
		r := drawn ? pane_motion_rect(w, pane) : pane.rect
		append(places, ui.Layout_Place{pane_motion_key(pane.content), {r.x, r.y, r.width, r.height}, pane.group})
	}
}

@(private = "file")
pane_motion_key :: proc(content: layout.Content) -> u64 {
	return u64(content.kind) << 32 | u64(content.id)
}

// What a pane draws while its frame moves away from its layout rectangle: the frame, header and
// outline at `shown`, and the content laid out at the layout rectangle, then moved with the frame's
// corner and clipped to the frame.
Pane_Frame :: struct {
	shown:  layout.Rect,
	offset: [2]f32,
	moving: bool,
}

pane_frame :: proc(w: ^Window, pane: layout.Pane_Rect) -> Pane_Frame {
	shown := pane_motion_rect(w, pane)
	if shown == pane.rect {return {shown = shown}}
	// Whole pixels, so text drawn at the layout rectangle stays sharp.
	offset := [2]f32{math.round(shown.x - pane.rect.x), math.round(shown.y - pane.rect.y)}
	return {shown, offset, true}
}

// Moves the content drawn since `mark` with the frame and keeps it inside the frame.
pane_frame_content :: proc(w: ^Window, f: Pane_Frame, mark: render.Draw_Mark) {
	if !f.moving {return}
	render.draw_translate(&w.list, mark, f.offset, {f.shown.x, f.shown.y, f.shown.width, f.shown.height})
}

// The bars between tiled panes as drawn: the layout's dividers, or while panes move, the strips between
// drawn panes whose facing sides are one gap apart, so a gapless layout keeps one shared border between
// neighbours throughout. Panes that are not neighbours yet draw their own full outlines.
pane_bars :: proc(w: ^Window) -> []layout.Edge {
	return w.pane_motion.bars[:]
}

// Rebuilds pane_bars after the dividers or the drawn panes changed; the buffer is kept, so drawing
// allocates nothing.
pane_bars_refresh :: proc(app: ^App, w: ^Window) {
	bars := &w.pane_motion.bars
	clear(bars)
	if !pane_motion_animating(w) {
		for d in w.dividers {append(bars, layout.Edge{d.axis, d.rect})}
		return
	}
	gap := window_gap(app, w)
	for a in w.panes {
		if a.floating {continue}
		ra := pane_motion_rect(w, a)
		for b in w.panes {
			if b.floating {continue}
			rb := pane_motion_rect(w, b)
			if abs(rb.x - (ra.x + ra.width) - gap) < 0.5 {
				top, bottom := max(ra.y, rb.y), min(ra.y + ra.height, rb.y + rb.height)
				if bottom > top {pane_bar_add(bars, {.Horizontal, {ra.x + ra.width, top, gap, bottom - top}})}
			}
			if abs(rb.y - (ra.y + ra.height) - gap) < 0.5 {
				left, right := max(ra.x, rb.x), min(ra.x + ra.width, rb.x + rb.width)
				if right > left {pane_bar_add(bars, {.Vertical, {left, ra.y + ra.height, right - left, gap}})}
			}
		}
	}
}

// Joins a strip to a collinear one it meets or crosses, so a bar beside several panes stays whole.
@(private = "file")
pane_bar_add :: proc(bars: ^[dynamic]layout.Edge, bar: layout.Edge) {
	for &other in bars {
		if other.axis != bar.axis {continue}
		a, b := other.rect, bar.rect
		if bar.axis == .Horizontal {
			if a.x != b.x || b.y > a.y + a.height + a.width || a.y > b.y + b.height + b.width {continue}
			top, bottom := min(a.y, b.y), max(a.y + a.height, b.y + b.height)
			other.rect.y, other.rect.height = top, bottom - top
		} else {
			if a.y != b.y || b.x > a.x + a.width + a.height || a.x > b.x + b.width + b.height {continue}
			left, right := min(a.x, b.x), max(a.x + a.width, b.x + b.width)
			other.rect.x, other.rect.width = left, right - left
		}
		return
	}
	append(bars, bar)
}
