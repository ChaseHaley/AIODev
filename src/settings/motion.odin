package settings

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:time"

MOTION_PREFIX :: "motion."
MOTION_CURVE_PREFIX :: "motion.curve."
MOTION_PRESET_PREFIX :: "motion.preset."
MOTION_CURVE_LIMIT :: 32
MOTION_PRESET_LIMIT :: 32
// Curve and preset names share the profile ID grammar but declare their own limit.
MOTION_NAME_MAX_LENGTH :: 32
MOTION_DURATION_MAXIMUM :: 5000
// What a field falls back to when even Panes leaves it unset: the single pane motion AIODev had
// before motion became a setting.
MOTION_DEFAULT_DURATION :: 160
MOTION_DEFAULT_CURVE :: "decelerate"
// The file comments of the context settings add the value grammar to each description.
@(private)
MOTION_ROOT_HINT ::
	" Set on or off, a duration such as 160ms and a curve such as decelerate, spring or a " +
	"motion.curve name, in any order."
@(private)
MOTION_CHILD_HINT ::
	" Set any of on or off, a duration such as 160ms and a curve, in any order; empty inherits " +
	"motion.panes."

// The animated situations, as a tree: each context sets its own fields or inherits its parent's.
Motion_Context :: enum u8 {
	Panes,
	Split,
	Close,
	View,
	Resize,
	Move,
	Float,
	Chrome,
}

// Panes is the root, so it is its own parent.
MOTION_CONTEXT_PARENT :: [Motion_Context]Motion_Context {
	.Panes  = .Panes,
	.Split  = .Panes,
	.Close  = .Panes,
	.View   = .Panes,
	.Resize = .Panes,
	.Move   = .Panes,
	.Float  = .Panes,
	.Chrome = .Panes,
}

MOTION_CONTEXT_KEY :: [Motion_Context]string {
	.Panes  = "motion.panes",
	.Split  = "motion.panes.split",
	.Close  = "motion.panes.close",
	.View   = "motion.panes.view",
	.Resize = "motion.panes.resize",
	.Move   = "motion.panes.move",
	.Float  = "motion.panes.float",
	.Chrome = "motion.panes.chrome",
}

// The short names preset lines use.
MOTION_CONTEXT_NAME :: [Motion_Context]string {
	.Panes  = "panes",
	.Split  = "split",
	.Close  = "close",
	.View   = "view",
	.Resize = "resize",
	.Move   = "move",
	.Float  = "float",
	.Chrome = "chrome",
}

MOTION_CONTEXT_TITLE :: [Motion_Context]string {
	.Panes  = "Panes",
	.Split  = "Split",
	.Close  = "Close",
	.View   = "Zoom and Fill Window",
	.Resize = "Balance and Resize",
	.Move   = "Rearrange and Swap",
	.Float  = "Floating Panes",
	.Chrome = "Rail and Activity Panel",
}

MOTION_CONTEXT_DESCRIPTION :: [Motion_Context]string {
	.Panes  = "Every pane layout change. The other pane motions inherit what they leave unset.",
	.Split  = "A new pane opening out of the pane it divides.",
	.Close  = "A closing pane giving its space back to its neighbors.",
	.View   = "A pane zooming in or filling the window, and returning.",
	.Resize = "Panes settling after Balance, a keyboard resize or a divider snap.",
	.Move   = "Panes trading places when you rearrange or swap them.",
	.Float  = "Panes floating, tiling, minimizing and restoring.",
	.Chrome = "The tab rail and activity panel opening and closing beside the panes.",
}

// How an entering or leaving pane appears. Edge grows it from, or collapses it into, the side it
// shares with its neighbor.
Motion_Effect :: enum u8 {
	Edge,
	Pop,
	Fade,
	Slide,
}

// The file names of each context's effects, indexed by Motion_Effect; only Split and Close have any.
// This table and the labels are variables because motion_effect_names hands out slices of them.
@(private)
MOTION_EFFECT_NAME := #partial [Motion_Context][len(Motion_Effect)]string {
	.Split = {"grow", "popin", "fade", "slide"},
	.Close = {"collapse", "popout", "fade", "slide"},
}

@(private)
MOTION_EFFECT_LABEL := #partial [Motion_Context][len(Motion_Effect)]string {
	.Split = {"Grow from Side", "Pop In", "Fade", "Slide In"},
	.Close = {"Collapse", "Pop Out", "Fade", "Slide Out"},
}

// The effect names as problems list them.
@(private, rodata)
MOTION_EFFECT_LIST := #partial [Motion_Context]string {
	.Split = "grow, popin, fade or slide",
	.Close = "collapse, popout, fade or slide",
}

motion_context_parent :: proc(c: Motion_Context) -> (parent: Motion_Context, ok: bool) {
	@(static, rodata)
	parents := MOTION_CONTEXT_PARENT
	return parents[c], parents[c] != c
}

motion_context_has_effect :: proc(c: Motion_Context) -> bool {
	return c == .Split || c == .Close
}

// Indexed by Motion_Effect; nil for a context without effects.
motion_effect_names :: proc(c: Motion_Context) -> []string {
	if !motion_context_has_effect(c) {return nil}
	return MOTION_EFFECT_NAME[c][:]
}

motion_effect_labels :: proc(c: Motion_Context) -> []string {
	if !motion_context_has_effect(c) {return nil}
	return MOTION_EFFECT_LABEL[c][:]
}

@(private)
motion_context_key :: proc(c: Motion_Context) -> string {
	@(static, rodata)
	keys := MOTION_CONTEXT_KEY
	return keys[c]
}

@(private)
motion_context_from_key :: proc(key: string) -> (Motion_Context, bool) {
	@(static, rodata)
	keys := MOTION_CONTEXT_KEY
	for candidate, c in keys {
		if candidate == key {return c, true}
	}
	return .Panes, false
}

// Whether `c` is `root` or lies below it in the context tree.
@(private)
motion_context_within :: proc(c, root: Motion_Context) -> bool {
	at := c
	for {
		if at == root {return true}
		parent, has_parent := motion_context_parent(at)
		if !has_parent {return false}
		at = parent
	}
}

// A timing curve. A Bézier's p is x1, y1, x2, y2 with x within 0..1 and y within -1..2, so it can
// overshoot; a spring's p[0] is its bounce, 0..0.9.
Motion_Curve :: struct {
	spring: bool,
	p:      [4]f32,
}

Motion_Named_Curve :: struct {
	name:  string,
	curve: Motion_Curve,
}

// Their names are reserved for these curves.
MOTION_BUILTIN_CURVES :: [?]Motion_Named_Curve {
	{"linear", {p = {0, 0, 1, 1}}},
	{"decelerate", {p = {0.2, 0, 0, 1}}},
	{"accelerate", {p = {0.4, 0, 1, 1}}},
	{"smooth", {p = {0.4, 0, 0.2, 1}}},
	{"quick", {p = {0.15, 0, 0.1, 1}}},
	{"overshot", {p = {0.05, 0.9, 0.1, 1.1}}},
	{"back", {p = {0.34, 1.56, 0.64, 1}}},
	{"spring", {spring = true, p = {0.2, 0, 0, 0}}},
	{"wobbly", {spring = true, p = {0.5, 0, 0, 0}}},
}

// A spring's natural frequency in radians over the whole motion: about 1.4 oscillations, so even a
// bouncy spring has settled by the time the duration ends.
@(private)
MOTION_SPRING_FREQUENCY :: 2 * math.PI * 1.4
// The least damping a spring keeps, so the largest bounce still settles.
@(private)
MOTION_SPRING_DAMPING_MINIMUM :: 0.08

// Progress along `c` at time t in 0..1: 0 at the start, exactly 1 from the end on, and free to leave
// 0..1 between them where the curve overshoots.
motion_curve_ease :: proc(c: Motion_Curve, t: f32) -> f32 {
	if t <= 0 {return 0}
	if t >= 1 {return 1}
	if c.spring {
		w: f32 = MOTION_SPRING_FREQUENCY
		z := max(MOTION_SPRING_DAMPING_MINIMUM, 1 - c.p[0])
		if z >= 1 {return 1 - math.exp(-w * t) * (1 + w * t)}
		wd := w * math.sqrt(1 - z * z)
		return 1 - math.exp(-z * w * t) * (math.cos(wd * t) + (z * w / wd) * math.sin(wd * t))
	}
	// Control points on the diagonal make y equal x: the curve is linear, exactly.
	if c.p[0] == c.p[1] && c.p[2] == c.p[3] {return t}
	// With both x control points within 0..1, x rises with u, so bisection finds the one u where
	// x(u) = t.
	low, high: f32 = 0, 1
	for _ in 0 ..< 24 {
		u := (low + high) / 2
		if motion_bezier(c.p[0], c.p[2], u) < t {low = u} else {high = u}
	}
	return motion_bezier(c.p[1], c.p[3], (low + high) / 2)
}

// One coordinate of a cubic Bézier from (0, 0) to (1, 1) with control coordinates a and b.
@(private)
motion_bezier :: proc(a, b, u: f32) -> f32 {
	v := 1 - u
	return 3 * v * v * u * a + 3 * v * u * u * b + u * u * u
}

motion_curve_builtin :: proc(name: string) -> bool {
	@(static, rodata)
	builtins := MOTION_BUILTIN_CURVES
	for builtin in builtins {
		if builtin.name == name {return true}
	}
	return false
}

// A curve by name: a built-in, then one of the file's curves.
motion_curve_find :: proc(s: ^Settings, name: string) -> (Motion_Curve, bool) {
	@(static, rodata)
	builtins := MOTION_BUILTIN_CURVES
	for builtin in builtins {
		if builtin.name == name {return builtin.curve, true}
	}
	if index := motion_curve_index(s, name); index >= 0 {return s.motion.curves[index].curve, true}
	return {}, false
}

@(private)
motion_curve_index :: proc(s: ^Settings, name: string) -> int {
	for curve, i in s.motion.curves {
		if curve.name == name {return i}
	}
	return -1
}

// Why `curve` cannot be saved, or empty. Temporary.
@(private)
motion_curve_problem :: proc(curve: Motion_Curve) -> string {
	if curve.spring {
		if !(curve.p[0] >= 0 && curve.p[0] <= 0.9) {return "spring bounce must be within 0..0.9"}
		return ""
	}
	within :: proc(v, low, high: f32) -> bool {return v >= low && v <= high}
	if !within(curve.p[0], 0, 1) || !within(curve.p[2], 0, 1) {return "x1 and x2 must be within 0..1"}
	if !within(curve.p[1], -1, 2) || !within(curve.p[3], -1, 2) {return "y1 and y2 must be within -1..2"}
	return ""
}

// Reads a curve line's value: "x1, y1, x2, y2" for a Bézier or "spring BOUNCE". `problem` is
// temporary and empty when the value is valid.
@(private)
motion_curve_parse :: proc(text: string) -> (curve: Motion_Curve, problem: string) {
	FORMS :: "expected \"x1, y1, x2, y2\" or \"spring BOUNCE\""
	if strings.has_prefix(text, "spring") {
		bounce, ok := strconv.parse_f32(strings.trim_space(text[len("spring"):]))
		if !ok {return {}, FORMS}
		curve = {spring = true, p = {bounce, 0, 0, 0}}
	} else {
		count := 0
		rest := text
		for part in strings.split_iterator(&rest, ",") {
			if count == len(curve.p) {return {}, FORMS}
			value, ok := strconv.parse_f32(strings.trim_space(part))
			if !ok {return {}, FORMS}
			curve.p[count] = value
			count += 1
		}
		if count != len(curve.p) {return {}, FORMS}
	}
	if problem = motion_curve_problem(curve); problem != "" {return {}, problem}
	return curve, ""
}

// The canonical value of a curve line. Temporary.
@(private)
motion_curve_text :: proc(curve: Motion_Curve) -> string {
	if curve.spring {return fmt.tprintf("spring %g", curve.p[0])}
	return fmt.tprintf("%g, %g, %g, %g", curve.p[0], curve.p[1], curve.p[2], curve.p[3])
}

// One context's own values; an unset field inherits.
Motion_Spec :: struct {
	on:       Maybe(bool),
	// Milliseconds, 0..MOTION_DURATION_MAXIMUM.
	duration: Maybe(int),
	// Empty when unset. In Settings it borrows the context's text.
	curve:    string,
	effect:   Maybe(Motion_Effect),
}

// Whether `token` reads as a duration, such as 160ms, or as a number missing its unit.
@(private)
motion_token_numeric :: proc(token: string) -> bool {
	return len(token) > 0 && token[0] >= '0' && token[0] <= '9'
}

// Whether `token` names an effect of any context.
@(private)
motion_token_effect :: proc(token: string) -> bool {
	for names in MOTION_EFFECT_NAME {
		for name in names {
			if name == token {return true}
		}
	}
	return false
}

// Reads one context's value: on or off, a duration such as 160ms, a curve name and, for contexts
// with effects, an effect name, each at most once and in any order. Empty inherits everything.
// `spec.curve` borrows `text`; `problem` is temporary and empty when the text is valid.
motion_spec_parse :: proc(c: Motion_Context, text: string) -> (spec: Motion_Spec, problem: string) {
	@(static, rodata)
	titles := MOTION_CONTEXT_TITLE
	effects := motion_effect_names(c)
	rest := text
	tokens: for token in strings.fields_iterator(&rest) {
		if token == "on" || token == "off" {
			if spec.on != nil {return {}, "give on or off once"}
			spec.on = token == "on"
			continue
		}
		if motion_token_numeric(token) {
			if !strings.has_suffix(token, "ms") {
				return {}, fmt.tprintf("\"%s\" needs a unit, such as 160ms", token)
			}
			milliseconds, ok := strconv.parse_int(token[:len(token) - len("ms")], 10)
			if !ok {return {}, fmt.tprintf("\"%s\" is not whole milliseconds, such as 160ms", token)}
			if milliseconds > MOTION_DURATION_MAXIMUM {
				return {}, fmt.tprintf("\"%s\" is out of range 0..%dms", token, MOTION_DURATION_MAXIMUM)
			}
			if spec.duration != nil {return {}, "give one duration"}
			spec.duration = milliseconds
			continue
		}
		for name, effect in effects {
			if name != token {continue}
			if spec.effect != nil {return {}, "give one effect"}
			spec.effect = Motion_Effect(effect)
			continue tokens
		}
		if motion_token_effect(token) {
			if effects == nil {
				return {}, fmt.tprintf("\"%s\" is an effect, and only Split and Close have effects", token)
			}
			return {}, fmt.tprintf(
				"\"%s\" is not an effect of %s; use %s",
				token,
				titles[c],
				MOTION_EFFECT_LIST[c],
			)
		}
		if id_valid(token, MOTION_NAME_MAX_LENGTH) {
			if spec.curve != "" {
				return {}, fmt.tprintf("give one curve; \"%s\" and \"%s\" both read as curves", spec.curve, token)
			}
			spec.curve = token
			continue
		}
		if effects == nil {
			return {}, fmt.tprintf("\"%s\" is not on, off, a duration such as 160ms or a curve name", token)
		}
		return {}, fmt.tprintf(
			"\"%s\" is not on, off, a duration such as 160ms, a curve name or an effect (%s)",
			token,
			MOTION_EFFECT_LIST[c],
		)
	}
	return spec, ""
}

// The longest canonical spec: off, 5000ms, a curve name at its length limit and the longest effect.
@(private)
MOTION_SPEC_TEXT_CAPACITY :: 64

// The canonical text of `spec`: on or off, the duration, the curve, then the effect, such as
// "on 160ms decelerate" or "420ms wobbly popin". Empty when nothing is set.
motion_spec_text :: proc(
	c: Motion_Context,
	spec: Motion_Spec,
	allocator := context.temp_allocator,
) -> string {
	buffer: [MOTION_SPEC_TEXT_CAPACITY]u8
	b := strings.builder_from_bytes(buffer[:])
	if on, set := spec.on.?; set {strings.write_string(&b, on ? "on" : "off")}
	if duration, set := spec.duration.?; set {
		if strings.builder_len(b) > 0 {strings.write_byte(&b, ' ')}
		strings.write_int(&b, duration)
		strings.write_string(&b, "ms")
	}
	if spec.curve != "" {
		if strings.builder_len(b) > 0 {strings.write_byte(&b, ' ')}
		strings.write_string(&b, spec.curve)
	}
	if effect, set := spec.effect.?; set && motion_context_has_effect(c) {
		if strings.builder_len(b) > 0 {strings.write_byte(&b, ' ')}
		strings.write_string(&b, MOTION_EFFECT_NAME[c][int(effect)])
	}
	text, _ := strings.clone(strings.to_string(b), allocator)
	return text
}

Motion_Field :: enum u8 {
	On,
	Duration,
	Curve,
	Effect,
}

Motion_Resolved :: struct {
	on:         bool,
	// Milliseconds before the global speed.
	duration:   int,
	// Borrowed from the settings or the built-in table.
	curve_name: string,
	curve:      Motion_Curve,
	// Edge for contexts without effects.
	effect:     Motion_Effect,
	// The context that set each field: the context itself, an ancestor, or Panes for a fallback.
	from:       [Motion_Field]Motion_Context,
}

// The values `c` animates with: its own, else the nearest ancestor's, else the root fallbacks. A
// curve name that names no curve counts as unset.
motion_resolve :: proc(s: ^Settings, c: Motion_Context) -> Motion_Resolved {
	return motion_resolve_specs(s, &s.motion.specs, c)
}

@(private)
motion_resolve_specs :: proc(
	s: ^Settings,
	specs: ^[Motion_Context]Motion_Spec,
	c: Motion_Context,
) -> (
	r: Motion_Resolved,
) {
	found: bit_set[Motion_Field]
	at := c
	for {
		spec := specs^[at]
		if on, set := spec.on.?; set && .On not_in found {
			r.on, r.from[.On] = on, at
			found += {.On}
		}
		if duration, set := spec.duration.?; set && .Duration not_in found {
			r.duration, r.from[.Duration] = duration, at
			found += {.Duration}
		}
		if spec.curve != "" && .Curve not_in found {
			if curve, known := motion_curve_find(s, spec.curve); known {
				r.curve_name, r.curve, r.from[.Curve] = spec.curve, curve, at
				found += {.Curve}
			}
		}
		if effect, set := spec.effect.?; set && .Effect not_in found {
			r.effect, r.from[.Effect] = effect, at
			found += {.Effect}
		}
		parent, has_parent := motion_context_parent(at)
		if !has_parent {break}
		at = parent
	}
	if .On not_in found {r.on, r.from[.On] = true, at}
	if .Duration not_in found {r.duration, r.from[.Duration] = MOTION_DEFAULT_DURATION, at}
	if .Curve not_in found {
		r.curve_name, r.from[.Curve] = MOTION_DEFAULT_CURVE, at
		r.curve, _ = motion_curve_find(s, MOTION_DEFAULT_CURVE)
	}
	if .Effect not_in found {r.effect, r.from[.Effect] = .Edge, at}
	return
}

// How long a resolved motion lasts at the global speed; zero when it is off.
motion_duration :: proc(s: ^Settings, r: Motion_Resolved) -> time.Duration {
	if !r.on {return 0}
	return time.Duration(math.round(f64(r.duration) / s.motion.speed)) * time.Millisecond
}

// Saved context values; an empty text leaves that context inheriting.
Motion_Preset :: struct {
	name:  string,
	specs: [Motion_Context]string,
}

// Their names are reserved for these presets.
MOTION_BUILTIN_PRESETS :: [?]Motion_Preset {
	{
		name = "default",
		specs = #partial [Motion_Context]string {
			.Panes = "on 160ms decelerate",
			.Split = "grow",
			.Close = "collapse",
		},
	},
	{name = "snappy", specs = #partial [Motion_Context]string{.Panes = "on 110ms quick"}},
	{name = "fluid", specs = #partial [Motion_Context]string{.Panes = "on 260ms smooth"}},
	{
		name = "bouncy",
		specs = #partial [Motion_Context]string {
			.Panes = "on 200ms decelerate",
			.Split = "420ms wobbly popin",
			.Close = "220ms accelerate popout",
			.View = "360ms spring",
			.Resize = "320ms spring",
		},
	},
	{
		name = "hyprland",
		specs = #partial [Motion_Context]string {
			.Panes = "on 500ms overshot",
			.Split = "700ms popin",
			.Close = "700ms linear popout",
		},
	},
	{
		name = "calm",
		specs = #partial [Motion_Context]string {
			.Panes = "on 220ms smooth",
			.Split = "fade",
			.Close = "fade",
			.Chrome = "off",
		},
	},
	{name = "off", specs = #partial [Motion_Context]string{.Panes = "off"}},
}

@(private)
motion_preset_builtin :: proc(name: string) -> bool {
	@(static, rodata)
	builtins := MOTION_BUILTIN_PRESETS
	for builtin in builtins {
		if builtin.name == name {return true}
	}
	return false
}

@(private)
motion_preset_index :: proc(s: ^Settings, name: string) -> int {
	for preset, i in s.motion.presets {
		if preset.name == name {return i}
	}
	return -1
}

// A preset by name: a built-in, then one of the file's presets.
@(private)
motion_preset_find :: proc(s: ^Settings, name: string) -> (Motion_Preset, bool) {
	@(static, rodata)
	builtins := MOTION_BUILTIN_PRESETS
	for builtin in builtins {
		if builtin.name == name {return builtin, true}
	}
	if index := motion_preset_index(s, name); index >= 0 {return s.motion.presets[index], true}
	return {}, false
}

// The first preset that animates every context exactly as the settings do, or empty ("Custom").
// Presets compare by resolved values, so a preset that spells out what the settings inherit, such as
// the default preset's "grow", still matches.
motion_preset_matching :: proc(s: ^Settings) -> string {
	@(static, rodata)
	builtins := MOTION_BUILTIN_PRESETS
	for builtin in builtins {
		if motion_preset_matches(s, builtin) {return builtin.name}
	}
	for preset in s.motion.presets {
		if motion_preset_matches(s, preset) {return preset.name}
	}
	return ""
}

@(private)
motion_preset_matches :: proc(s: ^Settings, preset: Motion_Preset) -> bool {
	specs: [Motion_Context]Motion_Spec
	for text, c in preset.specs {specs[c], _ = motion_spec_parse(c, text)}
	for c in Motion_Context {
		wanted := motion_resolve_specs(s, &specs, c)
		current := motion_resolve(s, c)
		if wanted.on != current.on || wanted.duration != current.duration ||
		   wanted.curve_name != current.curve_name || wanted.effect != current.effect {
			return false
		}
	}
	return true
}

// Reads a preset line's value, such as "panes: on 160ms decelerate; split: popin". Contexts it
// omits are empty. The specs borrow `text`; `problem` is temporary and empty when the text is valid.
@(private)
motion_preset_parse :: proc(text: string) -> (specs: [Motion_Context]string, problem: string) {
	@(static, rodata)
	names := MOTION_CONTEXT_NAME
	given: bit_set[Motion_Context]
	rest := text
	parts: for part in strings.split_iterator(&rest, ";") {
		entry := strings.trim_space(part)
		if entry == "" {continue}
		colon := strings.index_byte(entry, ':')
		if colon < 0 {
			return {}, fmt.tprintf("expected \"context: value\" such as \"split: popin\", not \"%s\"", entry)
		}
		name := strings.trim_space(entry[:colon])
		value := strings.trim_space(entry[colon + 1:])
		for candidate, c in names {
			if candidate != name {continue}
			if c in given {return {}, fmt.tprintf("\"%s\" appears twice", name)}
			if _, issue := motion_spec_parse(c, value); issue != "" {
				return {}, fmt.tprintf("%s: %s", name, issue)
			}
			specs[c] = value
			given += {c}
			continue parts
		}
		return {}, fmt.tprintf(
			"\"%s\" is not a motion; use panes, split, close, view, resize, move, float or chrome",
			name,
		)
	}
	return specs, ""
}

// The canonical value of a preset line: each set context's canonical spec in context order.
// Temporary.
@(private)
motion_preset_text :: proc(specs: [Motion_Context]string) -> string {
	@(static, rodata)
	names := MOTION_CONTEXT_NAME
	b := strings.builder_make(context.temp_allocator)
	for text, c in specs {
		spec, _ := motion_spec_parse(c, text)
		canonical := motion_spec_text(c, spec)
		if canonical == "" {continue}
		if strings.builder_len(b) > 0 {strings.write_string(&b, "; ")}
		strings.write_string(&b, names[c])
		strings.write_string(&b, ": ")
		strings.write_string(&b, canonical)
	}
	return strings.to_string(b)
}

// A name for a curve or preset from free text: lowercase, with every run of other characters
// turned into one -, trimmed to the name limit. Empty when nothing usable remains. Temporary.
motion_name_from :: proc(text: string) -> string {
	buffer: [MOTION_NAME_MAX_LENGTH]u8
	length := 0
	gap := false
	for i in 0 ..< len(text) {
		c := text[i]
		if c >= 'A' && c <= 'Z' {c += 'a' - 'A'}
		if c == '-' || !id_byte_valid(c) || (length == 0 && c == '_') {
			gap = true
			continue
		}
		if gap && length > 0 {
			if length == len(buffer) {break}
			buffer[length] = '-'
			length += 1
		}
		gap = false
		if length == len(buffer) {break}
		buffer[length] = c
		length += 1
	}
	name, _ := strings.clone(strings.trim_right(string(buffer[:length]), "-"), context.temp_allocator)
	return name
}

@(private)
Motion_Family :: enum {
	Curve,
	Preset,
}

// Why `name` cannot name a curve or preset, or empty. Temporary.
@(private)
motion_name_problem :: proc(family: Motion_Family, name: string) -> string {
	word := family == .Curve ? "curve" : "preset"
	if !id_valid(name, MOTION_NAME_MAX_LENGTH) {
		return fmt.tprintf(
			"invalid %s name \"%s\"; use up to %d lowercase letters, digits, - and _",
			word,
			name,
			MOTION_NAME_MAX_LENGTH,
		)
	}
	builtin := family == .Curve ? motion_curve_builtin(name) : motion_preset_builtin(name)
	if builtin {return fmt.tprintf("\"%s\" is a built-in %s; choose another name", name, word)}
	// A curve name must not read as another part of a motion value.
	reserved := name == "on" || name == "off" || motion_token_numeric(name) || motion_token_effect(name)
	if family == .Curve && reserved {
		return fmt.tprintf("\"%s\" reads as part of a motion value; choose another curve name", name)
	}
	return ""
}

// Checks one motion.curve.NAME or motion.preset.NAME line from Settings and returns its canonical
// file value. Both strings are temporary.
@(private)
motion_line_value :: proc(key, value: string) -> (serialized, issue: string) {
	if strings.has_prefix(key, MOTION_CURVE_PREFIX) {
		if issue = motion_name_problem(.Curve, key[len(MOTION_CURVE_PREFIX):]); issue != "" {return}
		curve: Motion_Curve
		if curve, issue = motion_curve_parse(value); issue != "" {return}
		return motion_curve_text(curve), ""
	}
	if issue = motion_name_problem(.Preset, key[len(MOTION_PRESET_PREFIX):]); issue != "" {return}
	specs: [Motion_Context]string
	if specs, issue = motion_preset_parse(value); issue != "" {return}
	return motion_preset_text(specs), ""
}

Motion_Settings :: struct {
	// Divides every duration: 2 runs motions twice as fast.
	speed:    f64,
	// Each context's SCHEMA string.
	contexts: [Motion_Context]string,
	// `contexts` parsed; kept in step by every assignment of a context.
	specs:    [Motion_Context]Motion_Spec,
	curves:   [dynamic]Motion_Named_Curve,
	presets:  [dynamic]Motion_Preset,
}

// Where the context strings start inside Settings; SCHEMA entry c is this plus c strings.
@(private)
MOTION_CONTEXTS_OFFSET :: offset_of(Settings, motion) + offset_of(Motion_Settings, contexts)

@(private)
motion_init :: proc(m: ^Motion_Settings, allocator: runtime.Allocator) {
	m.curves.allocator = allocator
	m.presets.allocator = allocator
}

// Frees the curves and presets; the context strings belong to SCHEMA's loop in destroy.
@(private)
motion_destroy :: proc(m: ^Motion_Settings, allocator: runtime.Allocator) {
	for curve in m.curves {delete(curve.name, allocator)}
	delete(m.curves)
	for &preset in m.presets {
		delete(preset.name, allocator)
		motion_preset_specs_delete(&preset.specs, allocator)
	}
	delete(m.presets)
}

@(private)
motion_preset_specs_delete :: proc(specs: ^[Motion_Context]string, allocator: runtime.Allocator) {
	for &text in specs^ {
		delete(text, allocator)
		text = ""
	}
}

// Re-reads a context's spec after its SCHEMA string changed, so the borrowed curve name never
// outlives the string it points into.
@(private)
motion_spec_refresh :: proc(s: ^Settings, key: string) {
	c, _ := motion_context_from_key(key)
	s.motion.specs[c], _ = motion_spec_parse(c, s.motion.contexts[c])
}

@(private, require_results)
parse_motion_curve_key :: proc(
	s: ^Settings,
	diagnostics: ^[dynamic]Diagnostic,
	key, value: string,
	line: int,
) -> runtime.Allocator_Error {
	name := key[len(MOTION_CURVE_PREFIX):]
	if name_issue := motion_name_problem(.Curve, name); name_issue != "" {
		return diagnostic_append(diagnostics, line, key, name_issue, .Unknown_Key)
	}
	index := motion_curve_index(s, name)
	if index >= 0 {duplicate_key_diagnostic(diagnostics, key, line) or_return}
	text, text_issue := text_value_decode(value)
	if text_issue != "" {return diagnostic_append(diagnostics, line, key, text_issue)}
	curve, issue := motion_curve_parse(text)
	if issue != "" {return diagnostic_append(diagnostics, line, key, issue)}
	if index >= 0 {
		s.motion.curves[index].curve = curve
		return nil
	}
	if len(s.motion.curves) >= MOTION_CURVE_LIMIT {
		return diagnostic_append(diagnostics, line, key, limit_message("motion curves", MOTION_CURVE_LIMIT))
	}
	owned := strings.clone(name, s.allocator) or_return
	if _, append_error := append(&s.motion.curves, Motion_Named_Curve{owned, curve}); append_error != nil {
		delete(owned, s.allocator)
		return append_error
	}
	return nil
}

@(private, require_results)
parse_motion_preset_key :: proc(
	s: ^Settings,
	diagnostics: ^[dynamic]Diagnostic,
	key, value: string,
	line: int,
) -> runtime.Allocator_Error {
	name := key[len(MOTION_PRESET_PREFIX):]
	if name_issue := motion_name_problem(.Preset, name); name_issue != "" {
		return diagnostic_append(diagnostics, line, key, name_issue, .Unknown_Key)
	}
	index := motion_preset_index(s, name)
	if index >= 0 {duplicate_key_diagnostic(diagnostics, key, line) or_return}
	text, text_issue := text_value_decode(value)
	if text_issue != "" {return diagnostic_append(diagnostics, line, key, text_issue)}
	given, issue := motion_preset_parse(text)
	if issue != "" {return diagnostic_append(diagnostics, line, key, issue)}
	if index < 0 && len(s.motion.presets) >= MOTION_PRESET_LIMIT {
		return diagnostic_append(diagnostics, line, key, limit_message("motion presets", MOTION_PRESET_LIMIT))
	}
	specs: [Motion_Context]string
	for spec_text, c in given {
		if spec_text == "" {continue}
		spec, _ := motion_spec_parse(c, spec_text)
		canonical, clone_error := strings.clone(motion_spec_text(c, spec), s.allocator)
		if clone_error != nil {
			motion_preset_specs_delete(&specs, s.allocator)
			return clone_error
		}
		specs[c] = canonical
	}
	if index >= 0 {
		motion_preset_specs_delete(&s.motion.presets[index].specs, s.allocator)
		s.motion.presets[index].specs = specs
		return nil
	}
	owned, name_error := strings.clone(name, s.allocator)
	if name_error == nil {
		_, name_error = append(&s.motion.presets, Motion_Preset{owned, specs})
	}
	if name_error != nil {
		delete(owned, s.allocator)
		motion_preset_specs_delete(&specs, s.allocator)
	}
	return name_error
}

// Reports each context whose curve names no curve; it inherits its curve instead.
@(private, require_results)
motion_finalize :: proc(s: ^Settings, diagnostics: ^[dynamic]Diagnostic) -> runtime.Allocator_Error {
	for spec, c in s.motion.specs {
		if spec.curve == "" {continue}
		if _, known := motion_curve_find(s, spec.curve); known {continue}
		key := motion_context_key(c)
		message := fmt.tprintf("unknown curve \"%s\"; the motion inherits its curve instead", spec.curve)
		diagnostic_append(diagnostics, setting_line(s, key), key, message) or_return
	}
	return nil
}

// Sets user curve `name`, and with `assign` also makes that context use it.
Motion_Curve_Set :: struct {
	name:   string,
	curve:  Motion_Curve,
	assign: Maybe(Motion_Context),
}

// Contexts naming the removed curve keep their text and inherit their curve until it returns.
Motion_Curve_Remove :: struct {
	name: string,
}

// Copies a preset's values for `root` and every context below it. The values are copied, not
// linked: later changes to the preset leave the settings alone.
Motion_Preset_Apply :: struct {
	name: string,
	root: Motion_Context,
}

// Saves the current context values as user preset `name`, replacing one of that name.
Motion_Preset_Save :: struct {
	name: string,
}

Motion_Preset_Remove :: struct {
	name: string,
}

Motion_Mutation :: union #no_nil {
	Motion_Curve_Set,
	Motion_Curve_Remove,
	Motion_Preset_Apply,
	Motion_Preset_Save,
	Motion_Preset_Remove,
}

// Builds the revision of `source`, which parses to `model`, that `m` makes. A refusal returns no
// revision and its reason in `message`; both are owned by `allocator`.
@(require_results)
motion_mutate :: proc(
	model: ^Settings,
	source: string,
	m: Motion_Mutation,
	allocator := context.allocator,
) -> (
	revision, message: string,
	err: runtime.Allocator_Error,
) {
	revision = strings.clone(source, allocator) or_return
	refusal: string
	switch change in m {
	case Motion_Curve_Set:
		refusal, err = motion_curve_set(model, &revision, change, allocator)
	case Motion_Curve_Remove:
		refusal, err = motion_line_remove(model, &revision, .Curve, change.name, allocator)
	case Motion_Preset_Apply:
		refusal, err = motion_preset_apply(model, &revision, change, allocator)
	case Motion_Preset_Save:
		refusal, err = motion_preset_save(model, &revision, change.name, allocator)
	case Motion_Preset_Remove:
		refusal, err = motion_line_remove(model, &revision, .Preset, change.name, allocator)
	}
	if err == nil && refusal != "" {message, err = strings.clone(refusal, allocator)}
	if err != nil || refusal != "" {
		delete(revision, allocator)
		revision = ""
	}
	if err != nil {
		delete(message, allocator)
		message = ""
	}
	return
}

// Sets one line of `text` through edit_text. `refusal` is temporary.
@(private, require_results)
motion_edit_line :: proc(
	text: ^string,
	key, value: string,
	allocator: runtime.Allocator,
) -> (
	refusal: string,
	err: runtime.Allocator_Error,
) {
	message := revision_edit_owned(text, key, value, allocator) or_return
	defer delete(message, allocator)
	if message == "" {return "", nil}
	return strings.clone(message, context.temp_allocator)
}

@(private, require_results)
motion_curve_set :: proc(
	model: ^Settings,
	revision: ^string,
	change: Motion_Curve_Set,
	allocator: runtime.Allocator,
) -> (
	refusal: string,
	err: runtime.Allocator_Error,
) {
	// edit_text checks the name and values; only the limit needs the model.
	if motion_curve_index(model, change.name) < 0 && len(model.motion.curves) >= MOTION_CURVE_LIMIT {
		return limit_message("motion curves", MOTION_CURVE_LIMIT), nil
	}
	if problem := motion_curve_problem(change.curve); problem != "" {return problem, nil}
	key := fmt.tprintf("%s%s", MOTION_CURVE_PREFIX, change.name)
	refusal = motion_edit_line(revision, key, motion_curve_text(change.curve), allocator) or_return
	c, assign := change.assign.?
	if refusal != "" || !assign {return}
	spec := model.motion.specs[c]
	spec.curve = change.name
	return motion_edit_line(revision, motion_context_key(c), motion_spec_text(c, spec), allocator)
}

@(private, require_results)
motion_preset_apply :: proc(
	model: ^Settings,
	revision: ^string,
	change: Motion_Preset_Apply,
	allocator: runtime.Allocator,
) -> (
	refusal: string,
	err: runtime.Allocator_Error,
) {
	preset, found := motion_preset_find(model, change.name)
	if !found {return fmt.tprintf("no motion preset is named \"%s\"", change.name), nil}
	specs: [Motion_Context]Motion_Spec
	for text, c in preset.specs {specs[c], _ = motion_spec_parse(c, text)}
	for c in Motion_Context {
		if !motion_context_within(c, change.root) {continue}
		value := motion_spec_text(c, specs[c])
		// A root below Panes takes every value the preset gives it, its own or inherited, so nothing
		// leaks in from the contexts above it.
		if _, has_parent := motion_context_parent(c); has_parent && c == change.root {
			r := motion_resolve_specs(model, &specs, c)
			full := Motion_Spec {
				on       = r.on,
				duration = r.duration,
				curve    = r.curve_name,
			}
			if motion_context_has_effect(c) {full.effect = r.effect}
			value = motion_spec_text(c, full)
		}
		key := motion_context_key(c)
		// A value equal to the default needs no line of its own.
		if entry := schema_find(key); value == entry.default_value {
			if theme_remove_lines(revision, key, false, allocator) != .None {return "", .Out_Of_Memory}
			continue
		}
		refusal = motion_edit_line(revision, key, value, allocator) or_return
		if refusal != "" {return}
	}
	return
}

@(private, require_results)
motion_preset_save :: proc(
	model: ^Settings,
	revision: ^string,
	name: string,
	allocator: runtime.Allocator,
) -> (
	refusal: string,
	err: runtime.Allocator_Error,
) {
	if motion_preset_index(model, name) < 0 && len(model.motion.presets) >= MOTION_PRESET_LIMIT {
		return limit_message("motion presets", MOTION_PRESET_LIMIT), nil
	}
	key := fmt.tprintf("%s%s", MOTION_PRESET_PREFIX, name)
	return motion_edit_line(revision, key, motion_preset_text(model.motion.contexts), allocator)
}

// Removes a user curve or preset line.
@(private, require_results)
motion_line_remove :: proc(
	model: ^Settings,
	revision: ^string,
	family: Motion_Family,
	name: string,
	allocator: runtime.Allocator,
) -> (
	refusal: string,
	err: runtime.Allocator_Error,
) {
	word := family == .Curve ? "curve" : "preset"
	builtin := family == .Curve ? motion_curve_builtin(name) : motion_preset_builtin(name)
	if builtin {return fmt.tprintf("\"%s\" is a built-in %s and cannot be removed", name, word), nil}
	index := family == .Curve ? motion_curve_index(model, name) : motion_preset_index(model, name)
	if index < 0 {return fmt.tprintf("no saved %s is named \"%s\"", word, name), nil}
	prefix := family == .Curve ? MOTION_CURVE_PREFIX : MOTION_PRESET_PREFIX
	if theme_remove_lines(revision, fmt.tprintf("%s%s", prefix, name), false, allocator) != .None {
		return "", .Out_Of_Memory
	}
	return "", nil
}
