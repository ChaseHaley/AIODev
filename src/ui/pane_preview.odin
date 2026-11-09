package ui

import "aio:render"

// A window drawn small as a pane header button would leave it, for that button's tooltip. Rectangles are in
// the window's own pixels; pane_preview_draw scales them down.
Pane_Preview :: struct {
	// The window's client size and the height its title bar keeps.
	size:    [2]f32,
	title:   f32,
	// Where the tiled panes go. Below the title bar, the rest is the tab rail and the Activity panel.
	content: render.Rect,
	// Every shown pane, bottom first.
	panes:   []render.Rect,
	// Where the button's pane ends up among `panes`, or -1 when it leaves this window.
	pane:    int,
	// The size of the pane a window of its own would take; zero when the pane stays in this window.
	away:    [2]f32,
}

// The miniature's largest size, in DIPs.
PANE_PREVIEW_WIDTH :: f32(176)
@(private = "file")
PANE_PREVIEW_HEIGHT :: f32(112)

// How much a window of its own is drawn smaller than the window it leaves, and how far past its corner.
@(private = "file")
PANE_PREVIEW_AWAY_SHARE :: f32(0.45)
@(private = "file")
PANE_PREVIEW_AWAY_OFFSET :: f32(SPACE_2)

@(private = "file")
pane_preview_factor :: proc(p: Pane_Preview, scale: f32) -> f32 {
	if p.size.x <= 0 || p.size.y <= 0 {return 0}
	return min(PANE_PREVIEW_WIDTH * scale / p.size.x, PANE_PREVIEW_HEIGHT * scale / p.size.y)
}

// The miniature's size on screen, including a window of its own hanging past the corner.
pane_preview_size :: proc(p: Pane_Preview, scale: f32) -> [2]f32 {
	k := pane_preview_factor(p, scale)
	size := p.size * k
	if p.away.x > 0 {size += PANE_PREVIEW_AWAY_OFFSET * scale}
	return size
}

// Draws `p` with its top-left at `origin`: the title bar, tab rail and panels in the border colour, so
// what a view hides or keeps stands out, the content area in the window colour, the panes as cards and the
// button's pane in the accent.
pane_preview_draw :: proc(
	list: ^render.Draw_List,
	theme: Theme,
	origin: [2]f32,
	p: Pane_Preview,
	scale: f32,
) -> render.Error {
	k := pane_preview_factor(p, scale)
	if k <= 0 {return .None}
	place := proc(origin: [2]f32, r: render.Rect, k: f32) -> render.Rect {
		return {origin.x + r.x * k, origin.y + r.y * k, r.width * k, r.height * k}
	}
	radius := RADIUS_CONTROL * scale
	frame := render.Rect{origin.x, origin.y, p.size.x * k, p.size.y * k}
	if err := render.push_rect(list, {rect = frame, color = theme.border, radius = radius}); err != .None {
		return err
	}
	content := place(origin, p.content, k)
	if err := render.push_rect(list, {rect = content, color = theme.window}); err != .None {return err}
	for pane, i in p.panes {
		if i == p.pane {continue}
		if err := pane_preview_card(list, theme, place(origin, pane, k), false, scale); err != .None {return err}
	}
	if p.pane >= 0 && p.pane < len(p.panes) {
		chosen := place(origin, p.panes[p.pane], k)
		if err := pane_preview_card(list, theme, chosen, true, scale); err != .None {return err}
	}
	if p.away.x <= 0 || p.away.y <= 0 {return .None}
	// A window of its own: a smaller window over the corner, holding only the pane.
	title := p.title * k
	share := PANE_PREVIEW_AWAY_SHARE * min(frame.width / p.away.x, frame.height / p.away.y)
	size := [2]f32{p.away.x * share, p.away.y * share + title}
	away := render.Rect {
		frame.x + frame.width + PANE_PREVIEW_AWAY_OFFSET * scale - size.x,
		frame.y + frame.height + PANE_PREVIEW_AWAY_OFFSET * scale - size.y,
		size.x,
		size.y,
	}
	if err := render.push_rect(list, {rect = away, color = theme.border, radius = radius}); err != .None {
		return err
	}
	inset := scale
	pane := render.Rect{away.x + inset, away.y + title, away.width - 2 * inset, away.height - title - inset}
	if err := pane_preview_card(list, theme, pane, true, scale); err != .None {return err}
	return render.push_rect(list, {rect = away, color = theme.accent, radius = radius, stroke = scale})
}

@(private = "file")
pane_preview_card :: proc(
	list: ^render.Draw_List,
	theme: Theme,
	r: render.Rect,
	chosen: bool,
	scale: f32,
) -> render.Error {
	fill, edge := theme.pane, theme.faint
	if chosen {
		fill = theme.accent
		fill.a *= 0.35
		edge = theme.accent
	}
	radius := min(RADIUS_CONTROL * scale, r.width / 2, r.height / 2)
	if err := render.push_rect(list, {rect = r, color = fill, radius = radius}); err != .None {return err}
	return render.push_rect(list, {rect = r, color = edge, radius = radius, stroke = scale})
}
