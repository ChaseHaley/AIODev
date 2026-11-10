package ui

import "aio:input"
import "aio:render"
import "aio:settings"
import "base:runtime"
import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"

// Which part of the Motion section a row is. A context row heads that context's field rows, which
// follow it directly in `rows`.
Motion_Part :: enum u8 {
	None,
	Preset,
	Save_Preset,
	Context,
	On,
	Duration,
	Curve,
	Effect,
	User_Preset,
}

// The rows that show and save one field of their context.
MOTION_FIELD_PARTS :: bit_set[Motion_Part]{.On, .Duration, .Curve, .Effect}

MOTION_PRESET_KEY :: "motion.preset"
// Not under motion.preset., where a saved preset named "save" would share the key.
MOTION_SAVE_PRESET_KEY :: "motion.save_preset"

// The Motion section's page state. Expansion survives a reload through Editor_View. The curve
// popover shows `motion_curve`; once a drag or New button changes it (`motion_curve_edited`), saving
// writes it as user curve `motion_curve_name`. A built-in is renamed to a free copy the moment a drag
// first changes it, since built-ins cannot be overwritten.
Motion_Editor_State :: struct {
	motion_expanded:     bit_set[settings.Motion_Context],
	// The file's own curves with owned names; the popover lists the built-ins before them.
	motion_curves:       [dynamic]settings.Motion_Named_Curve,
	motion_curve_name:   string,
	motion_curve:        settings.Motion_Curve,
	motion_curve_edited: bool,
	// What the next save of the open popover does with the shown curve instead of saving its points.
	motion_curve_action: Motion_Curve_Action,
}

Motion_Curve_Action :: enum u8 {
	None,
	// To the name typed in the popover's name field, which edits `choice_search`.
	Rename,
	Delete,
}

// The curve popover's pointer drags: a Bézier handle, or a spring's bounce slider.
Curve_Drag :: enum {
	None,
	First,
	Second,
	Bounce,
}

// What the pointer is over in the curve popover.
Curve_Target :: enum {
	None,
	Option,
	New_Bezier,
	New_Spring,
	Name,
	Delete,
	First,
	Second,
	Bounce,
}

// The curve popover: the curve list on the left; on the right the shown curve's name and Delete, then
// its plot with its controls. `graph` is the plot's 0..1 time span, inset from its frame so handles at
// either end stay whole. `bounce` exists only for a spring.
Curve_Parts :: struct {
	list, name, delete, plot, graph, bounce, new_bezier, new_spring: render.Rect,
}

// What saving a Motion row writes: one context's whole text, or a curve or preset change. Nil when
// the row has nothing to save. Strings are temporary or static.
Motion_Change :: union {
	Motion_Text,
	settings.Motion_Mutation,
}

Motion_Text :: struct {
	key, value: string,
}

// The plot's value range: room for curves that overshoot below 0 or above 1.
MOTION_PLOT_LOW :: f32(-0.5)
MOTION_PLOT_HIGH :: f32(1.5)

@(private = "file")
MOTION_POPOVER_WIDTH :: 440
@(private = "file")
MOTION_CURVE_LIST_WIDTH :: 184
@(private = "file")
MOTION_DELETE_WIDTH :: 72
@(private = "file")
MOTION_PLOT_STEPS :: 48
@(private = "file")
MOTION_SPARK_WIDTH :: 40
@(private = "file")
MOTION_SPARK_HEIGHT :: 16
@(private = "file")
MOTION_SPARK_STEPS :: 16
// A sparkline keeps a little room for overshoot inside its own small box.
@(private = "file")
MOTION_SPARK_LOW :: f32(-0.25)
@(private = "file")
MOTION_SPARK_HIGH :: f32(1.25)
@(private = "file")
MOTION_HANDLE_SIZE :: 12
// How far from a handle a press still grabs it.
@(private = "file")
MOTION_HANDLE_REACH :: 16
@(private = "file")
MOTION_BOUNCE_MAXIMUM :: f32(0.9)
// The slider covers everyday durations; the field takes up to the setting's own maximum.
@(private = "file")
MOTION_DURATION_SLIDER :: 2000
@(private = "file")
MOTION_DURATION_STEP :: 10
@(private = "file")
MOTION_NEW_BEZIER :: settings.Motion_Curve{p = {0.4, 0, 0.2, 1}}
@(private = "file")
MOTION_NEW_SPRING :: settings.Motion_Curve{spring = true, p = {0.3, 0, 0, 0}}

@(private = "file", rodata)
MOTION_CURVES := settings.MOTION_BUILTIN_CURVES
@(private = "file", rodata)
MOTION_PRESETS := settings.MOTION_BUILTIN_PRESETS
@(private = "file", rodata)
MOTION_KEYS := settings.MOTION_CONTEXT_KEY
@(private = "file", rodata)
MOTION_TITLES := settings.MOTION_CONTEXT_TITLE
@(private = "file", rodata)
MOTION_DESCRIPTIONS := settings.MOTION_CONTEXT_DESCRIPTION

@(private = "file", rodata)
MOTION_PART_FIELD := #partial [Motion_Part]settings.Motion_Field {
	.On       = .On,
	.Duration = .Duration,
	.Curve    = .Curve,
	.Effect   = .Effect,
}

@(private = "file", rodata)
MOTION_FIELD_KEY := [settings.Motion_Field]string {
	.On       = "on",
	.Duration = "duration",
	.Curve    = "curve",
	.Effect   = "effect",
}

@(private = "file", rodata)
MOTION_FIELD_DESCRIPTION := [settings.Motion_Field]string {
	.On       = "Off moves panes at once.",
	.Duration = "Milliseconds, before Animation Speed divides it.",
	.Curve    = "How the motion speeds up and settles.",
	.Effect   = "How the pane appears or leaves.",
}

motion_editor_destroy :: proc(m: ^Motion_Editor_State) {
	for curve in m.motion_curves {delete(curve.name)}
	delete(m.motion_curves)
	delete(m.motion_curve_name)
	m^ = {}
}

// What a built-in preset is called in the Preset list.
@(private = "file")
motion_preset_label :: proc(name: string) -> string {
	switch name {
	case "default":
		return "AIODev Default"
	case "snappy":
		return "Snappy"
	case "fluid":
		return "Fluid"
	case "bouncy":
		return "Bouncy"
	case "hyprland":
		return "Hyprland"
	case "calm":
		return "Calm"
	case "off":
		return "Off"
	}
	return name
}

// Panes sits at depth 0 and every context below it one step further in.
@(private = "file")
motion_depth :: proc(c: settings.Motion_Context) -> int {
	depth, at := 0, c
	for {
		parent, has_parent := settings.motion_context_parent(at)
		if !has_parent {return depth}
		depth, at = depth + 1, parent
	}
}

@(private = "file")
motion_spec_has :: proc(spec: settings.Motion_Spec, field: settings.Motion_Field) -> bool {
	switch field {
	case .On:
		return spec.on != nil
	case .Duration:
		return spec.duration != nil
	case .Curve:
		return spec.curve != ""
	case .Effect:
		return spec.effect != nil
	}
	return false
}

// The Motion section after its schema rows: the preset controls, one header per context with its
// field rows, and the user's presets.
@(require_results)
editor_motion_load :: proc(p: ^Editor, s: ^settings.Settings) -> runtime.Allocator_Error {
	group := settings.group_title(MOTION_KEYS[.Panes])
	for named in s.motion.curves {
		name := strings.clone(named.name) or_return
		if _, err := append(&p.motion_curves, settings.Motion_Named_Curve{name, named.curve}); err != nil {
			delete(name)
			return err
		}
	}
	// Custom is the empty choice: it names no preset, so choosing it changes nothing.
	count := 1 + len(MOTION_PRESETS) + len(s.motion.presets)
	choices := make([]string, count, context.temp_allocator) or_return
	labels := make([]string, count, context.temp_allocator) or_return
	labels[0] = "Custom"
	for preset, i in MOTION_PRESETS {
		choices[1 + i], labels[1 + i] = preset.name, motion_preset_label(preset.name)
	}
	for preset, i in s.motion.presets {
		at := 1 + len(MOTION_PRESETS) + i
		choices[at], labels[at] = preset.name, preset.name
	}
	editor_add(p, {
		key = MOTION_PRESET_KEY, title = "Preset", value = settings.motion_preset_matching(s),
		description = "Copies a preset's motion into every context; later edits leave the preset alone.",
		kind = .Choice, choices = choices, choice_labels = labels, motion_part = .Preset,
	}, group) or_return
	editor_add(p, {
		key = MOTION_SAVE_PRESET_KEY, title = "Save as Preset", kind = .Text, motion_part = .Save_Preset,
		description = "Name the current motion to keep it in the Preset list.",
	}, group) or_return
	for c in settings.Motion_Context {motion_context_rows(p, s, c, group) or_return}
	for preset in s.motion.presets {
		editor_add(p, {
			key = fmt.tprintf("%s%s", settings.MOTION_PRESET_PREFIX, preset.name), title = preset.name,
			description = "Your preset.", value = "Delete", kind = .Action, motion_part = .User_Preset,
		}, group) or_return
	}
	return nil
}

// A context's header and its field rows. Each field shows the value in effect; `motion_inherited`
// marks one the context leaves to its parent or the built-in fallback.
@(private = "file", require_results)
motion_context_rows :: proc(
	p: ^Editor, s: ^settings.Settings, c: settings.Motion_Context, group: string,
) -> runtime.Allocator_Error {
	key := MOTION_KEYS[c]
	r := settings.motion_resolve(s, c)
	names, labels := settings.motion_effect_names(c), settings.motion_effect_labels(c)
	effect_name, effect_label := "", ""
	if len(names) > 0 {effect_name, effect_label = names[int(r.effect)], labels[int(r.effect)]}
	default_value := ""
	if entry := settings.schema_find(key); entry != nil {default_value = entry.default_value}
	editor_add(p, {
		key = key, title = MOTION_TITLES[c], description = MOTION_DESCRIPTIONS[c],
		value = s.motion.contexts[c], default_value = default_value,
		detail = fmt.tprintf("animate duration curve effect %s %s", r.curve_name, effect_label),
		kind = .Motion_Context, motion_part = .Context, motion_context = c,
	}, group) or_return
	fields := [settings.Motion_Field]Editor_Row {
		.On = {title = "Animate", value = r.on ? "true" : "false", kind = .Toggle, motion_part = .On},
		.Duration = {
			title = "Duration", value = fmt.tprintf("%d", r.duration), kind = .Integer,
			minimum = 0, maximum = MOTION_DURATION_SLIDER, step = MOTION_DURATION_STEP, motion_part = .Duration,
		},
		.Curve = {
			title = "Curve", value = r.curve_name, detail = r.curve_name, kind = .Curve, motion_part = .Curve,
		},
		.Effect = {
			title = "Effect", value = effect_name, detail = effect_label, kind = .Choice,
			choices = names, choice_labels = labels, motion_part = .Effect,
		},
	}
	// Panes' own fields reset to the schema's value, so there they read as unchanged at the factory value,
	// like any other setting. A child's field resets by inheriting, which always changes it.
	defaults: [settings.Motion_Field]string
	if _, has_parent := settings.motion_context_parent(c); !has_parent {
		spec, _ := settings.motion_spec_parse(c, default_value)
		if on, ok := spec.on.?; ok {defaults[.On] = on ? "true" : "false"}
		if duration, ok := spec.duration.?; ok {defaults[.Duration] = fmt.tprintf("%d", duration)}
		defaults[.Curve] = spec.curve
	}
	for &row, field in fields {
		if field == .Effect && !settings.motion_context_has_effect(c) {continue}
		source := r.from[field]
		// A field naming a curve that does not exist resolves elsewhere, so `from` decides too.
		set := source == c && motion_spec_has(s.motion.specs[c], field)
		row.key = fmt.tprintf("%s.%s", key, MOTION_FIELD_KEY[field])
		row.default_value = defaults[field]
		row.motion_context, row.motion_inherited = c, !set
		row.description = MOTION_FIELD_DESCRIPTION[field]
		if !set {
			row.description = "Built-in default."
			if source != c && motion_spec_has(s.motion.specs[source], field) {
				row.description = fmt.tprintf("From %s.", MOTION_TITLES[source])
			}
		}
		editor_add(p, row, group) or_return
	}
	return nil
}

// A context header shows while every context above it is expanded; a field row also needs its own
// context expanded. Searching shows them all.
@(private)
motion_row_available :: proc(p: ^Editor, row: Editor_Row) -> bool {
	return filtering(p) || motion_shown_needs(row) <= p.motion_expanded
}

// The contexts that must be expanded for `row` to show.
@(private = "file")
motion_shown_needs :: proc(row: Editor_Row) -> (needs: bit_set[settings.Motion_Context]) {
	if row.motion_part in MOTION_FIELD_PARTS {needs += {row.motion_context}}
	at := row.motion_context
	for {
		parent, has_parent := settings.motion_context_parent(at)
		if !has_parent {return}
		needs += {parent}
		at = parent
	}
}

// Expands what `row` needs to show; true when that changed anything.
@(private)
motion_reveal :: proc(p: ^Editor, row: Editor_Row) -> bool {
	if row.motion_part not_in MOTION_FIELD_PARTS && row.motion_part != .Context {return false}
	needs := motion_shown_needs(row)
	if needs <= p.motion_expanded {return false}
	p.motion_expanded += needs
	return true
}

editor_motion_toggle :: proc(p: ^Editor, c: settings.Motion_Context) {
	p.motion_expanded ~= {c}
	editor_rebuild(p)
}

// The change saving the selected Motion row makes. A reset applies only to a field the context
// sets: a child then inherits it again, and the root returns to its schema default.
@(require_results)
editor_motion_change :: proc(p: ^Editor, reset: bool) -> (change: Motion_Change, problem: string) {
	row := editor_row(p)
	if row == nil {return}
	part := row.motion_part
	if reset && (part not_in MOTION_FIELD_PARTS || row.motion_inherited) {return}
	value := strings.clone(field_string(&p.value), context.temp_allocator)
	#partial switch part {
	case .Preset:
		if value == "" {
			field_set(&p.value, row.value)
			return
		}
		return settings.Motion_Mutation(settings.Motion_Preset_Apply{name = value, root = .Panes}), ""
	case .Save_Preset:
		if strings.trim_space(value) == "" {return}
		name := settings.motion_name_from(value)
		if name == "" {return nil, "Name the preset with letters or digits."}
		return settings.Motion_Mutation(settings.Motion_Preset_Save{name = name}), ""
	case .User_Preset:
		name := strings.clone(row.title, context.temp_allocator)
		return settings.Motion_Mutation(settings.Motion_Preset_Remove{name = name}), ""
	case .On, .Duration, .Curve, .Effect:
		c := row.motion_context
		if part == .Curve && p.motion_curve_action != .None {
			action := p.motion_curve_action
			p.motion_curve_action = .None
			from := strings.clone(p.motion_curve_name, context.temp_allocator)
			if action == .Delete {return settings.Motion_Mutation(settings.Motion_Curve_Remove{name = from}), ""}
			to := settings.motion_name_from(field_string(&p.choice_search))
			if to == "" {return nil, "Name the curve with letters or digits."}
			return settings.Motion_Mutation(settings.Motion_Curve_Rename{from = from, to = to}), ""
		}
		if part == .Curve && p.motion_curve_edited {
			name := strings.clone(p.motion_curve_name, context.temp_allocator)
			set := settings.Motion_Curve_Set{name = name, curve = p.motion_curve, assign = c}
			return settings.Motion_Mutation(set), ""
		}
		text: string
		text, problem = motion_context_text(p, row, value, reset)
		if problem != "" {return}
		return Motion_Text{MOTION_KEYS[c], text}, ""
	}
	return
}

// The context's whole text with one field changed, from its own text on the header row.
@(private = "file")
motion_context_text :: proc(
	p: ^Editor, row: ^Editor_Row, value: string, reset: bool,
) -> (text, problem: string) {
	c := row.motion_context
	own, schema_default := "", ""
	for candidate in p.rows {
		if candidate.motion_part == .Context && candidate.motion_context == c {
			own, schema_default = candidate.value, candidate.default_value
			break
		}
	}
	spec, _ := settings.motion_spec_parse(c, own)
	// Clearing a field leaves a child inheriting it; the root has nothing above it.
	fallback: settings.Motion_Spec
	if _, child := settings.motion_context_parent(c); !child {
		fallback, _ = settings.motion_spec_parse(c, schema_default)
	}
	#partial switch row.motion_part {
	case .On:
		if reset {spec.on = fallback.on} else {spec.on = value == "true"}
	case .Duration:
		if reset {
			spec.duration = fallback.duration
			break
		}
		ms, ok := strconv.parse_int(strings.trim_suffix(strings.trim_space(value), "ms"), 10)
		if !ok {return "", "Enter the duration as a whole number of milliseconds."}
		spec.duration = ms
	case .Curve:
		spec.curve = reset ? fallback.curve : value
	case .Effect:
		if reset {
			spec.effect = fallback.effect
			break
		}
		for name, i in settings.motion_effect_names(c) {
			if name == value {spec.effect = settings.Motion_Effect(i)}
		}
	}
	return settings.motion_spec_text(c, spec), ""
}

@(private)
motion_curve_count :: proc(p: ^Editor) -> int {
	return len(MOTION_CURVES) + len(p.motion_curves)
}

// The popover's curves in list order: the built-ins, then the file's own.
@(private)
motion_curve_at :: proc(p: ^Editor, index: int) -> settings.Motion_Named_Curve {
	if index < len(MOTION_CURVES) {return MOTION_CURVES[index]}
	return p.motion_curves[index - len(MOTION_CURVES)]
}

@(private = "file")
motion_curve_index :: proc(p: ^Editor, name: string) -> int {
	for i in 0 ..< motion_curve_count(p) {
		if motion_curve_at(p, i).name == name {return i}
	}
	return -1
}

// The points of the curve `name`; a name the page does not know draws as a straight line.
@(private = "file")
motion_curve_named :: proc(p: ^Editor, name: string) -> settings.Motion_Curve {
	if index := motion_curve_index(p, name); index >= 0 {return motion_curve_at(p, index).curve}
	return MOTION_CURVES[0].curve
}

// The first `<base>-<n>` from `first` up that names no curve yet. Temporary.
@(private = "file")
motion_curve_free :: proc(p: ^Editor, base: string, first: int) -> string {
	n := first
	for {
		name := fmt.tprintf("%s-%d", base, n)
		if motion_curve_index(p, name) < 0 {return name}
		n += 1
	}
}

@(private = "file")
motion_curve_hold :: proc(p: ^Editor, name: string, curve: settings.Motion_Curve) {
	owned := strings.clone(name)
	delete(p.motion_curve_name)
	p.motion_curve_name, p.motion_curve = owned, curve
}

// Opens the curve popover on the row's curve, highlighted in the list.
@(private)
motion_popover_open :: proc(p: ^Editor, row: ^Editor_Row) {
	editor_mode_set(p, Editor_Curve_Popup{})
	index := max(0, motion_curve_index(p, row.value))
	named := motion_curve_at(p, index)
	motion_curve_hold(p, named.name, named.curve)
	p.motion_curve_edited = false
	count := motion_curve_count(p)
	p.choice_list = {index = index, scroll = index}
	choice_list_keep_visible(&p.choice_list, count, min(count, CHOICE_LIST_ROWS))
}

// Reopens the popover on a rebuilt page. An edit not yet saved rides along only with the draft.
@(private)
motion_popover_carry :: proc(to, from: ^Editor, row: ^Editor_Row, draft: bool) {
	motion_popover_open(to, row)
	if !draft || !from.motion_curve_edited {return}
	motion_curve_hold(to, from.motion_curve_name, from.motion_curve)
	to.motion_curve_edited = true
}

// Makes the listed curve the context's curve; the popover stays open on it.
@(private)
motion_curve_choose :: proc(p: ^Editor, index: int) -> Editor_Outcome {
	if index < 0 || index >= motion_curve_count(p) {return .None}
	named := motion_curve_at(p, index)
	p.choice_list.index = index
	motion_curve_hold(p, named.name, named.curve)
	p.motion_curve_edited = false
	if named.name == field_string(&p.value) {return .Changed}
	field_set(&p.value, named.name)
	return .Save
}

// A new user curve for the context, starting from the shown curve when it is of the same kind.
@(private = "file")
motion_curve_new :: proc(p: ^Editor, spring: bool) -> Editor_Outcome {
	curve := p.motion_curve
	if curve.spring != spring {curve = spring ? MOTION_NEW_SPRING : MOTION_NEW_BEZIER}
	motion_curve_hold(p, motion_curve_free(p, spring ? "spring" : "curve", 1), curve)
	p.motion_curve_edited = true
	return .Save
}

@(private = "file")
motion_round :: proc(value: f32) -> f32 {
	return math.round(value * 100) / 100
}

@(private = "file")
motion_point :: proc(area: render.Rect, low, high, t, value: f32) -> [2]f32 {
	return {area.x + area.width * t, area.y + area.height * (high - value) / (high - low)}
}

// Where progress `value` at time `t` lands in the popover's plot.
motion_plot_point :: proc(plot: render.Rect, t, value: f32) -> [2]f32 {
	return motion_point(plot, MOTION_PLOT_LOW, MOTION_PLOT_HIGH, t, value)
}

// Moves the dragged handle or bounce to the pointer, rounded to hundredths. The first change to a
// built-in renames the shown curve to a free copy, which saving then creates.
@(private = "file")
motion_curve_pick :: proc(p: ^Editor, c: Curve_Parts, drag: Curve_Drag, x, y: f32) {
	next := p.motion_curve
	switch drag {
	case .None:
		return
	case .First, .Second:
		at := drag == .First ? 0 : 2
		span := MOTION_PLOT_HIGH - MOTION_PLOT_LOW
		value := MOTION_PLOT_HIGH - (y - c.graph.y) / max(1, c.graph.height) * span
		next.p[at] = motion_round(clamp((x - c.graph.x) / max(1, c.graph.width), 0, 1))
		next.p[at + 1] = motion_round(clamp(value, MOTION_PLOT_LOW, MOTION_PLOT_HIGH))
	case .Bounce:
		fraction := clamp((x - c.bounce.x) / max(1, c.bounce.width), 0, 1)
		next.p[0] = motion_round(fraction * MOTION_BOUNCE_MAXIMUM)
	}
	if next == p.motion_curve {return}
	if settings.motion_curve_builtin(p.motion_curve_name) {
		motion_curve_hold(p, motion_curve_free(p, p.motion_curve_name, 2), next)
	} else {
		p.motion_curve = next
	}
	p.motion_curve_edited = true
}

// Right-aligned under the Curve field, flipped above the row when the page has no room below.
@(private)
motion_popover_rect :: proc(parts: Row_Parts, page: render.Rect, scale: f32) -> render.Rect {
	s := scale
	width := MOTION_POPOVER_WIDTH * s
	height := (f32(CHOICE_LIST_ROWS) * CHOICE_HEIGHT + 2 * OVERLAY_PADDING) * s
	field := parts.field
	r := render.Rect{field.x + field.width - width, field.y + field.height + 6 * s, width, height}
	return dropdown_place(r, parts.row, page, s)
}

motion_curve_parts :: proc(popup: render.Rect, spring: bool, scale: f32) -> Curve_Parts {
	s := scale
	pad := OVERLAY_PADDING * s
	list_width := min(MOTION_CURVE_LIST_WIDTH * s, popup.width / 2)
	c := Curve_Parts {
		list = {popup.x + pad, popup.y + pad, list_width, popup.height - 2 * pad},
	}
	left := c.list.x + c.list.width + SPACE_3 * s
	width := max(0, popup.x + popup.width - SPACE_3 * s - left)
	button := HEIGHT_STANDARD * s
	half := max(0, (width - SPACE_2 * s) / 2)
	buttons := popup.y + popup.height - SPACE_3 * s - button
	c.new_bezier = {left, buttons, half, button}
	c.new_spring = {left + half + SPACE_2 * s, buttons, half, button}
	bottom := buttons - SPACE_3 * s
	if spring {
		c.bounce = {left, bottom - SLIDER_THUMB * s, width, SLIDER_THUMB * s}
		bottom = c.bounce.y - SPACE_3 * s
	}
	top := popup.y + SPACE_3 * s
	delete_width := MOTION_DELETE_WIDTH * s
	c.name = {left, top, max(0, width - delete_width - SPACE_2 * s), button}
	c.delete = {left + width - delete_width, top, delete_width, button}
	top += button + SPACE_2 * s
	c.plot = {left, top, width, max(0, bottom - top)}
	inset := SPACE_3 * s
	c.graph = {c.plot.x + inset, c.plot.y, max(0, c.plot.width - 2 * inset), c.plot.height}
	return c
}

// What a press at x, y in the popover reaches; `option` is the list index under an Option.
@(private)
motion_popup_hit :: proc(
	p: ^Editor, popup: render.Rect, x, y, scale: f32,
) -> (target: Curve_Target, option: int) {
	c := motion_curve_parts(popup, p.motion_curve.spring, scale)
	option = -1
	switch {
	case render.rect_contains(c.list, x, y):
		count := motion_curve_count(p)
		row_height := CHOICE_HEIGHT * scale
		option = choice_list_at(p.choice_list, c.list.y, row_height, y, count, min(count, CHOICE_LIST_ROWS))
		if option >= 0 {target = .Option}
		return
	case render.rect_contains(c.new_bezier, x, y):
		return .New_Bezier, option
	case render.rect_contains(c.new_spring, x, y):
		return .New_Spring, option
	case render.rect_contains(c.name, x, y), render.rect_contains(c.delete, x, y):
		// Only the file's own curves can be renamed or deleted.
		if settings.motion_curve_builtin(p.motion_curve_name) {return}
		target = render.rect_contains(c.name, x, y) ? .Name : .Delete
		return
	}
	if p.motion_curve.spring {
		slack := SPACE_2 * scale
		reach := render.Rect {
			c.bounce.x - slack, c.bounce.y - slack, c.bounce.width + 2 * slack, c.bounce.height + 2 * slack,
		}
		if render.rect_contains(reach, x, y) {target = .Bounce}
		return
	}
	first := motion_plot_point(c.graph, p.motion_curve.p[0], p.motion_curve.p[1])
	second := motion_plot_point(c.graph, p.motion_curve.p[2], p.motion_curve.p[3])
	to_first := (x - first.x) * (x - first.x) + (y - first.y) * (y - first.y)
	to_second := (x - second.x) * (x - second.x) + (y - second.y) * (y - second.y)
	reach := MOTION_HANDLE_REACH * scale
	if min(to_first, to_second) > reach * reach {return}
	target = .First
	if to_second < to_first {target = .Second}
	return
}

@(private)
editor_motion_popup_press :: proc(p: ^Editor, popup: render.Rect, x, y, scale: f32) -> Editor_Outcome {
	target, option := motion_popup_hit(p, popup, x, y, scale)
	// A press anywhere but the name field ends naming without renaming.
	if curve, open := p.mode.(Editor_Curve_Popup); open && curve.naming && target != .Name {
		editor_mode_set(p, Editor_Curve_Popup{})
	}
	drag: Curve_Drag
	switch target {
	case .None:
		return .None
	case .Option:
		return motion_curve_choose(p, option)
	case .New_Bezier, .New_Spring:
		return motion_curve_new(p, target == .New_Spring)
	case .Name:
		motion_curve_naming(p)
		return .Changed
	case .Delete:
		p.motion_curve_action = .Delete
		return .Save
	case .First:
		drag = .First
	case .Second:
		drag = .Second
	case .Bounce:
		drag = .Bounce
	}
	editor_mode_set(p, Editor_Curve_Popup{drag = drag})
	motion_curve_pick(p, motion_curve_parts(popup, p.motion_curve.spring, scale), drag, x, y)
	return .Changed
}

// Starts editing the shown user curve's name in the popover, all of it selected.
@(private = "file")
motion_curve_naming :: proc(p: ^Editor) {
	if settings.motion_curve_builtin(p.motion_curve_name) {return}
	field_set(&p.choice_search, p.motion_curve_name)
	field_select_all(&p.choice_search)
	editor_mode_set(p, Editor_Curve_Popup{naming = true})
}

@(private)
editor_motion_popup_drag :: proc(p: ^Editor, popup: render.Rect, drag: Curve_Drag, x, y, scale: f32) -> bool {
	if drag == .None {return false}
	before := p.motion_curve
	motion_curve_pick(p, motion_curve_parts(popup, p.motion_curve.spring, scale), drag, x, y)
	return p.motion_curve != before
}

// Highlights the listed curve under the pointer.
@(private)
editor_motion_popup_hover :: proc(p: ^Editor, popup: render.Rect, x, y, scale: f32) -> bool {
	target, option := motion_popup_hit(p, popup, x, y, scale)
	if target != .Option || option == p.choice_list.index {return false}
	p.choice_list.index = option
	return true
}

@(private)
editor_motion_wheel :: proc(p: ^Editor, rows: int) {
	count := motion_curve_count(p)
	_ = choice_list_scroll_to(&p.choice_list, p.choice_list.scroll - rows, count, min(count, CHOICE_LIST_ROWS))
}

// Headers expand with Enter or Right and collapse with Left; the open popover takes its list keys.
editor_motion_key :: proc(p: ^Editor, row: ^Editor_Row, e: input.Key_Event) -> (Editor_Outcome, bool) {
	if row == nil {return .None, false}
	if curve, open := p.mode.(Editor_Curve_Popup); open {
		if curve.naming {
			#partial switch e.key {
			case .Enter, .Numpad_Enter:
				p.motion_curve_action = .Rename
				return .Save, true
			case .Escape:
				editor_mode_set(p, Editor_Curve_Popup{})
				return .Changed, true
			}
			// Typed text arrives through editor_text; the field takes every other key.
			_ = field_key(&p.choice_search, e)
			return .Changed, true
		}
		count := motion_curve_count(p)
		visible := min(count, CHOICE_LIST_ROWS)
		if choice_list_key(&p.choice_list, e, count, visible) {return .Changed, true}
		#partial switch e.key {
		case .Home, .End:
			choice_list_move(&p.choice_list, e.key == .Home ? -count : count, count, visible)
			return .Changed, true
		case .Escape:
			editor_mode_set(p, Editor_Editing{})
			return .Changed, true
		case .Enter, .Numpad_Enter, .Space:
			return motion_curve_choose(p, p.choice_list.index), true
		case .F2:
			motion_curve_naming(p)
			return .Changed, true
		}
		return .None, false
	}
	if row.kind != .Motion_Context {return .None, false}
	c := row.motion_context
	#partial switch e.key {
	case .Enter, .Numpad_Enter:
		editor_motion_toggle(p, c)
		return .Changed, true
	case .Arrow_Right:
		if c not_in p.motion_expanded {editor_motion_toggle(p, c)}
		return .Changed, true
	case .Arrow_Left:
		if c in p.motion_expanded {editor_motion_toggle(p, c)}
		return .Changed, true
	}
	return .None, false
}

// A header press expands or collapses it; a press on the Curve field opens the popover.
editor_motion_press :: proc(
	p: ^Editor, row: ^Editor_Row, parts: Row_Parts, x, y: f32,
) -> (Editor_Outcome, bool) {
	#partial switch row.kind {
	case .Motion_Context:
		editor_motion_toggle(p, row.motion_context)
		return .Changed, true
	case .Curve:
		if !render.rect_contains(parts.field, x, y) {return .None, false}
		motion_popover_open(p, row)
		return .Changed, true
	}
	return .None, false
}

// Only a field the context sets has a reset.
editor_motion_parts :: proc(row: ^Editor_Row, parts: Row_Parts) -> Row_Parts {
	result := parts
	if row.motion_part not_in MOTION_FIELD_PARTS || row.motion_inherited {result.reset = {}}
	return result
}

// `steps` segments of the curve across `area`, its values from `low` at the bottom to `high` at the top.
@(private = "file")
motion_curve_line :: proc(
	list: ^render.Draw_List, curve: settings.Motion_Curve, area: render.Rect,
	low, high: f32, steps: int, width: f32, color: render.Color,
) {
	previous := motion_point(area, low, high, 0, 0)
	for i in 1 ..= steps {
		t := f32(i) / f32(steps)
		next := motion_point(area, low, high, t, settings.motion_curve_ease(curve, t))
		_ = render.push_segment(list, previous, next, width, color)
		previous = next
	}
}

@(private = "file")
motion_spark_draw :: proc(
	list: ^render.Draw_List, curve: settings.Motion_Curve, area: render.Rect, color: render.Color, s: f32,
) {
	motion_curve_line(list, curve, area, MOTION_SPARK_LOW, MOTION_SPARK_HIGH, MOTION_SPARK_STEPS, 1.5 * s, color)
}

@(private = "file")
motion_spark_rect :: proc(x, cy, s: f32) -> render.Rect {
	return {x, cy - MOTION_SPARK_HEIGHT / 2 * s, MOTION_SPARK_WIDTH * s, MOTION_SPARK_HEIGHT * s}
}

// The Curve row's field: the curve's sparkline and name, like a choice.
@(private)
motion_curve_field_draw :: proc(
	p: ^Editor, row: ^Editor_Row, parts: Row_Parts, selected: bool,
	list: ^render.Draw_List, text: ^Text, theme: Theme, scale: f32,
) -> render.Build_Status {
	s, field := scale, parts.field
	box_draw(list, field, theme, selected && editor_editing(p), s)
	name := selected && editor_popup(p) == .Curve ? p.motion_curve_name : row.value
	curve := selected && editor_popup(p) == .Curve ? p.motion_curve : motion_curve_named(p, row.value)
	spark := motion_spark_rect(field.x + CONTROL_INSET * s, field.y + field.height / 2, s)
	motion_spark_draw(list, curve, spark, theme.muted, s)
	chevron := render.Rect {
		field.x + field.width - (CONTROL_INSET + ICON_INDICATOR) * s,
		field.y,
		ICON_INDICATOR * s,
		field.height,
	}
	icon_draw(list, .Chevron_Down, chevron, theme.muted, ICON_INDICATOR, s)
	input_text := text_styled(text, .Body)
	x := spark.x + spark.width + SPACE_2 * s
	baseline := field.y + (field.height - input_text.line_height) / 2 + input_text.ascent
	return draw_text(&input_text, list, name, x, baseline, theme.text, max(1, chevron.x - SPACE_1 * s - x))
}

// Draws a Motion row: a context header, or a labelled control whose inherited value is faint.
editor_motion_draw :: proc(
	p: ^Editor, index: int, parts: Row_Parts, selected, reset_hovered: bool,
	list: ^render.Draw_List, text: ^Text, theme: Theme, page: render.Rect, pointer: [2]f32, scale: f32,
) -> render.Build_Status {
	row := &p.rows[index]
	if row.kind == .Motion_Context {return motion_header_draw(p, index, parts, list, text, theme, scale)}
	s, r := scale, parts.row
	x := r.x + ITEM_INSET * s
	if row.motion_part in MOTION_FIELD_PARTS {x += f32(motion_depth(row.motion_context) + 1) * SPACE_6 * s}
	small := text_styled(text, .Detail)
	limit := max(1, parts.text_right - x)
	baseline, detail_baseline := stacked_baselines(r, text, &small, s)
	if row.description == "" {baseline = r.y + (r.height - text.line_height) / 2 + text.ascent}
	if result := draw_text(text, list, row.title, x, baseline, theme.text, limit); result != .Ok {return result}
	if result := draw_text(&small, list, row.description, x, detail_baseline, theme.muted, limit);
	   result != .Ok {return result}
	shown := theme
	if row.motion_inherited && (!selected || field_string(&p.value) == row.value) {shown.text = theme.faint}
	if result := control_draw(p, row, parts, selected, list, text, shown, page, s); result != .Ok {return result}
	if render.push_layer(list, page) != .None {return .Ok}
	if row.motion_part == .Duration && !selected {
		unit := "ms"
		unit_x := parts.field.x + parts.field.width - CONTROL_INSET * s - text_width(&small, unit)
		unit_baseline := parts.field.y + (parts.field.height - small.line_height) / 2 + small.ascent
		if result := draw_text(&small, list, unit, unit_x, unit_baseline, theme.muted);
		   result != .Ok {return result}
	}
	if parts.reset.width == 0 {return .Ok}
	modified := row.value != row.default_value
	_ = reset_button_draw(list, theme, parts.reset, modified, reset_hovered, selected, pointer, s)
	return .Ok
}

// A context header: chevron, title and description, and on the right a summary of the values in
// effect with the curve's sparkline, faint when the context sets none of them.
@(private = "file")
motion_header_draw :: proc(
	p: ^Editor, index: int, parts: Row_Parts,
	list: ^render.Draw_List, text: ^Text, theme: Theme, scale: f32,
) -> render.Build_Status {
	s, r := scale, parts.row
	row := &p.rows[index]
	c := row.motion_context
	depth := f32(motion_depth(c))
	chevron := render.Rect{r.x + (CONTROL_INSET + depth * SPACE_6) * s, r.y, SPACE_6 * s, r.height}
	icon := c in p.motion_expanded ? Icon.Chevron_Down : Icon.Chevron_Right
	icon_draw(list, icon, chevron, theme.muted, ICON_INDICATOR, s)
	on, inherited := true, true
	duration, curve, effect := "", "", ""
	for &field in p.rows[index + 1:] {
		if field.motion_context != c || field.motion_part not_in MOTION_FIELD_PARTS {break}
		inherited = inherited && field.motion_inherited
		#partial switch field.motion_part {
		case .On:
			on = field.value == "true"
		case .Duration:
			duration = field.value
		case .Curve:
			curve = field.value
		case .Effect:
			effect = choice_label(&field, field.value)
		}
	}
	buffer: [128]u8
	summary := "Off"
	if on && effect != "" {
		summary = fmt.bprintf(buffer[:], "%s ms · %s · %s", duration, curve, effect)
	} else if on {
		summary = fmt.bprintf(buffer[:], "%s ms · %s", duration, curve)
	}
	ink := inherited ? theme.faint : theme.muted
	small := text_styled(text, .Detail)
	right := r.x + r.width - SPACE_3 * s
	cy := r.y + r.height / 2
	summary_x := right - text_width(&small, summary)
	if result := draw_text(&small, list, summary, summary_x, cy - small.line_height / 2 + small.ascent, ink);
	   result != .Ok {return result}
	spark := motion_spark_rect(summary_x - (SPACE_2 + MOTION_SPARK_WIDTH) * s, cy, s)
	if on {motion_spark_draw(list, motion_curve_named(p, curve), spark, ink, s)}
	x := chevron.x + chevron.width
	limit := max(1, spark.x - SPACE_3 * s - x)
	baseline, detail_baseline := stacked_baselines(r, text, &small, s)
	if result := draw_text(text, list, row.title, x, baseline, theme.text, limit); result != .Ok {return result}
	return draw_text(&small, list, row.description, x, detail_baseline, theme.muted, limit)
}

// The curve list with sparklines, and the shown curve's plot with its handles or bounce slider.
@(private)
editor_motion_popup_draw :: proc(
	p: ^Editor, l: Editor_Layout, popup: render.Rect,
	list: ^render.Draw_List, text: ^Text, theme: Theme, pointer: [2]f32,
) -> render.Build_Status {
	s := l.scale
	row := editor_row(p)
	curve := p.motion_curve
	c := motion_curve_parts(popup, curve.spring, s)
	count := motion_curve_count(p)
	for shown in 0 ..< min(count, CHOICE_LIST_ROWS) {
		i := p.choice_list.scroll + shown
		if i >= count {break}
		named := motion_curve_at(p, i)
		option := render.Rect{c.list.x, c.list.y + f32(shown) * CHOICE_HEIGHT * s, c.list.width, CHOICE_HEIGHT * s}
		if i == p.choice_list.index {
			draw_rect(list, {rect = option, color = theme.selection, radius = RADIUS_CONTROL * s})
		}
		if render.rect_contains(option, pointer.x, pointer.y) {
			// Options carry the selection tint, not the paper fill, so no hairline.
			if hover_rim_draw(list, theme, option, RADIUS_CONTROL * s, 1, s, pointer, false) != .None {return .Ok}
		}
		if row != nil && named.name == row.value {
			mark := render.Rect{option.x, option.y + SPACE_2 * s, 3 * s, option.height - 2 * SPACE_2 * s}
			draw_rect(list, {rect = mark, color = theme.accent, radius = pill_radius(mark)})
		}
		spark_x := option.x + option.width - (SPACE_2 + MOTION_SPARK_WIDTH) * s
		spark := motion_spark_rect(spark_x, option.y + option.height / 2, s)
		motion_spark_draw(list, named.curve, spark, theme.muted, s)
		baseline := option.y + (option.height - text.line_height) / 2 + text.ascent
		x := option.x + SPACE_3 * s
		if result := draw_text(text, list, named.name, x, baseline, theme.text, max(1, spark.x - SPACE_2 * s - x));
		   result != .Ok {return result}
	}
	draw_rect(list, {rect = c.plot, color = theme.surface, radius = RADIUS_CONTROL * s})
	draw_rect(list, {rect = c.plot, color = theme.border, radius = RADIUS_CONTROL * s, stroke = s})
	for level in ([2]f32{0, 1}) {
		y := motion_plot_point(c.graph, 0, level).y
		draw_rect(list, {rect = {c.plot.x, y, c.plot.width, s}, color = theme.border})
	}
	if render.push_layer(list, c.plot, RADIUS_CONTROL * s) != .None {return .Ok}
	first := motion_plot_point(c.graph, curve.p[0], curve.p[1])
	second := motion_plot_point(c.graph, curve.p[2], curve.p[3])
	if !curve.spring {
		_ = render.push_segment(list, motion_plot_point(c.graph, 0, 0), first, s, theme.muted)
		_ = render.push_segment(list, motion_plot_point(c.graph, 1, 1), second, s, theme.muted)
	}
	motion_curve_line(list, curve, c.graph, MOTION_PLOT_LOW, MOTION_PLOT_HIGH, MOTION_PLOT_STEPS, 2 * s,
		theme.accent)
	if !curve.spring {
		size := MOTION_HANDLE_SIZE * s
		for point in ([2][2]f32{first, second}) {
			dot := render.Rect{point.x - size / 2, point.y - size / 2, size, size}
			draw_rect(list, {rect = dot, color = theme.accent, radius = pill_radius(dot)})
			draw_rect(list, {rect = dot, color = theme.surface, radius = pill_radius(dot), stroke = 2 * s})
		}
	}
	if render.push_layer(list, l.page) != .None {return .Ok}
	small := text_styled(text, .Detail)
	buffer: [96]u8
	caption: string
	if curve.spring {
		caption = fmt.bprintf(buffer[:], "bounce %.2f", curve.p[0])
	} else {
		caption = fmt.bprintf(buffer[:], "%.2f, %.2f, %.2f, %.2f", curve.p[0], curve.p[1], curve.p[2], curve.p[3])
	}
	if result := draw_text(&small, list, caption, c.plot.x + SPACE_2 * s, c.plot.y + SPACE_2 * s + small.ascent,
		theme.muted, max(1, c.plot.width - SPACE_4 * s)); result != .Ok {return result}
	if result := motion_curve_name_draw(p, c, list, text, theme, pointer, s); result != .Ok {return result}
	if curve.spring {slider_draw(list, c.bounce, curve.p[0] / MOTION_BOUNCE_MAXIMUM, theme, s)}
	if result := text_button_draw(list, text, theme, c.new_bezier, "New Bézier", false, s, pointer);
	   result != .Ok {return result}
	return text_button_draw(list, text, theme, c.new_spring, "New Spring", false, s, pointer)
}

// The shown curve's name: a field while naming, else its name, with Delete for the file's own curves.
// A built-in says so and has neither.
@(private = "file")
motion_curve_name_draw :: proc(
	p: ^Editor, c: Curve_Parts, list: ^render.Draw_List, text: ^Text, theme: Theme, pointer: [2]f32, s: f32,
) -> render.Build_Status {
	naming := false
	if curve, open := p.mode.(Editor_Curve_Popup); open {naming = curve.naming}
	box_draw(list, c.name, theme, naming, s)
	box := field_box_standard(&p.choice_search, text, c.name, s)
	if naming {return field_box_draw(box, list, theme, field_box_baseline(box), true, "")}
	builtin := settings.motion_curve_builtin(p.motion_curve_name)
	buffer: [64]u8
	label := builtin ? fmt.bprintf(buffer[:], "%s (built-in)", p.motion_curve_name) : p.motion_curve_name
	x := c.name.x + CONTROL_INSET * s
	if result := draw_text(text, list, label, x, field_box_baseline(box), builtin ? theme.muted : theme.text,
		max(1, c.name.x + c.name.width - CONTROL_INSET * s - x)); result != .Ok {return result}
	if builtin {return .Ok}
	return text_button_draw(list, text, theme, c.delete, "Delete", false, s, pointer)
}
