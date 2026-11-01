package vector

import "core:math"
import "core:slice"
import "core:strconv"

// Fills SVG path data into an anti-aliased coverage mask, so single-colour artwork can be drawn
// sharp at whatever pixel size a DPI asks for. Supports every path command (M L H V C S Q T A Z,
// absolute and relative); strokes, transforms and paint are out of scope.

Fill_Rule :: enum u8 {
	Nonzero,
	Even_Odd,
}

MAX_SIZE :: 256

// Vertical samples per pixel row; horizontal coverage is exact.
@(private)
SUBSAMPLES :: 16

@(private)
Edge :: struct {
	x0, y0, x1, y1: f32,
	direction:      i32,
}

@(private)
Crossing :: struct {
	x:         f32,
	direction: i32,
}

@(private)
Builder :: struct {
	edges:          [dynamic]Edge,
	scale:          f32,
	start, current: [2]f32,
	// The second control point of the previous C/S or Q/T, for the next S or T to reflect.
	cubic, quad:    [2]f32,
	has_cubic:      bool,
	has_quad:       bool,
}

@(private)
Scanner :: struct {
	text: string,
	at:   int,
}

// Fills each path of `paths`, drawn in a square `view` units wide, into a size x size mask of
// coverage bytes, one per pixel. Overlapping paths combine as separate layers of one colour.
// Returns false for malformed path data, a size outside 1..MAX_SIZE or a short mask.
@(require_results)
fill :: proc(paths: []string, view: f32, rule: Fill_Rule, size: int, coverage: []u8) -> bool {
	if size < 1 || size > MAX_SIZE || len(coverage) < size * size || view <= 0 {return false}
	total := make([]f32, size * size)
	defer delete(total)
	layer := make([]f32, size * size)
	defer delete(layer)
	b := Builder {
		scale = f32(size) / view,
	}
	defer delete(b.edges)
	for data in paths {
		clear(&b.edges)
		if !parse(&b, data) {return false}
		slice.fill(layer, 0)
		scan(b.edges[:], rule, size, layer)
		for &value, i in total {value = 1 - (1 - value) * (1 - min(layer[i], 1))}
	}
	for value, i in total {coverage[i] = u8(math.round(clamp(value, 0, 1) * 255))}
	return true
}

@(private)
scan :: proc(edges: []Edge, rule: Fill_Rule, size: int, coverage: []f32) {
	crossings := make([dynamic]Crossing, 0, 64)
	defer delete(crossings)
	weight := 1 / f32(SUBSAMPLES)
	for row in 0 ..< size {
		for sample in 0 ..< SUBSAMPLES {
			y := f32(row) + (f32(sample) + 0.5) * weight
			clear(&crossings)
			for e in edges {
				// Edges are stored top to bottom, so the half-open test counts a shared vertex once.
				if y < e.y0 || y >= e.y1 {continue}
				x := e.x0 + (y - e.y0) * (e.x1 - e.x0) / (e.y1 - e.y0)
				append(&crossings, Crossing{x, e.direction})
			}
			slice.sort_by(crossings[:], proc(a, b: Crossing) -> bool {return a.x < b.x})
			winding: i32
			start: f32
			for c in crossings {
				before := inside(winding, rule)
				winding += c.direction
				after := inside(winding, rule)
				if !before && after {start = c.x}
				if before && !after {span(coverage[row * size:(row + 1) * size], start, c.x, weight)}
			}
		}
	}
}

@(private)
inside :: proc(winding: i32, rule: Fill_Rule) -> bool {
	return rule == .Nonzero ? winding != 0 : winding & 1 != 0
}

// Adds `weight` times the covered fraction of each pixel between from and to.
@(private)
span :: proc(row: []f32, from, to, weight: f32) {
	a, b := clamp(from, 0, f32(len(row))), clamp(to, 0, f32(len(row)))
	if b <= a {return}
	for x := int(a); x < len(row) && f32(x) < b; x += 1 {
		row[x] += (min(b, f32(x + 1)) - max(a, f32(x))) * weight
	}
}

@(private)
parse :: proc(b: ^Builder, data: string) -> bool {
	s := Scanner {
		text = data,
	}
	command: u8
	for {
		skip(&s)
		if s.at >= len(s.text) {break}
		c := s.text[s.at]
		if is_command(c) {
			command = c
			s.at += 1
		} else if command == 0 || command == 'Z' || command == 'z' {
			return false
		}
		relative := command >= 'a'
		origin := relative ? b.current : [2]f32{}
		cubic, quad := false, false
		switch command | 0x20 {
		case 'm':
			p := point(&s) or_return
			close(b)
			b.start = origin + p
			b.current = b.start
			// Further pairs after a move are implicit line commands.
			command = relative ? 'l' : 'L'
		case 'l':
			p := point(&s) or_return
			line_to(b, origin + p)
		case 'h':
			x := number(&s) or_return
			line_to(b, {origin.x + x, b.current.y})
		case 'v':
			y := number(&s) or_return
			line_to(b, {b.current.x, origin.y + y})
		case 'c':
			c1 := point(&s) or_return
			c2 := point(&s) or_return
			p := point(&s) or_return
			cubic_to(b, origin + c1, origin + c2, origin + p)
			cubic = true
		case 's':
			c2 := point(&s) or_return
			p := point(&s) or_return
			c1 := b.has_cubic ? 2 * b.current - b.cubic : b.current
			cubic_to(b, c1, origin + c2, origin + p)
			cubic = true
		case 'q':
			c := point(&s) or_return
			p := point(&s) or_return
			quad_to(b, origin + c, origin + p)
			quad = true
		case 't':
			p := point(&s) or_return
			c := b.has_quad ? 2 * b.current - b.quad : b.current
			quad_to(b, c, origin + p)
			quad = true
		case 'a':
			rx := number(&s) or_return
			ry := number(&s) or_return
			rotation := number(&s) or_return
			large := flag(&s) or_return
			sweep := flag(&s) or_return
			p := point(&s) or_return
			arc_to(b, abs(rx), abs(ry), rotation, large, sweep, origin + p)
		case 'z':
			close(b)
			b.current = b.start
		case:
			return false
		}
		b.has_cubic, b.has_quad = cubic, quad
	}
	close(b)
	return true
}

@(private)
is_command :: proc(c: u8) -> bool {
	switch c | 0x20 {
	case 'm', 'l', 'h', 'v', 'c', 's', 'q', 't', 'a', 'z':
		return true
	}
	return false
}

@(private)
skip :: proc(s: ^Scanner) {
	for s.at < len(s.text) {
		switch s.text[s.at] {
		case ' ', '\t', '\n', '\r', '\f', ',':
			s.at += 1
		case:
			return
		}
	}
}

// Reads one number. Path data packs numbers without separators: "1.5.5" is 1.5 then .5 and
// "1-2" is 1 then -2.
@(private, require_results)
number :: proc(s: ^Scanner) -> (f32, bool) {
	skip(s)
	start := s.at
	if s.at < len(s.text) && (s.text[s.at] == '-' || s.text[s.at] == '+') {s.at += 1}
	digits := 0
	for s.at < len(s.text) && is_digit(s.text[s.at]) {s.at += 1; digits += 1}
	if s.at < len(s.text) && s.text[s.at] == '.' {
		s.at += 1
		for s.at < len(s.text) && is_digit(s.text[s.at]) {s.at += 1; digits += 1}
	}
	if digits == 0 {return 0, false}
	if s.at < len(s.text) && (s.text[s.at] == 'e' || s.text[s.at] == 'E') {
		mark := s.at
		s.at += 1
		if s.at < len(s.text) && (s.text[s.at] == '-' || s.text[s.at] == '+') {s.at += 1}
		if s.at < len(s.text) && is_digit(s.text[s.at]) {
			for s.at < len(s.text) && is_digit(s.text[s.at]) {s.at += 1}
		} else {
			s.at = mark
		}
	}
	value, ok := strconv.parse_f32(s.text[start:s.at])
	return value, ok && !math.is_nan(value) && !math.is_inf(value)
}

@(private, require_results)
point :: proc(s: ^Scanner) -> (p: [2]f32, ok: bool) {
	x := number(s) or_return
	y := number(s) or_return
	return {x, y}, true
}

// Arc flags are single digits that need no separator: "011" is large 0, sweep 1, then 1.
@(private, require_results)
flag :: proc(s: ^Scanner) -> (bool, bool) {
	skip(s)
	if s.at >= len(s.text) || (s.text[s.at] != '0' && s.text[s.at] != '1') {return false, false}
	s.at += 1
	return s.text[s.at - 1] == '1', true
}

@(private)
is_digit :: proc(c: u8) -> bool {
	return c >= '0' && c <= '9'
}

@(private)
line_to :: proc(b: ^Builder, p: [2]f32) {
	from, to := b.current * b.scale, p * b.scale
	b.current = p
	if from.y == to.y {return}
	if from.y < to.y {
		append(&b.edges, Edge{from.x, from.y, to.x, to.y, 1})
	} else {
		append(&b.edges, Edge{to.x, to.y, from.x, from.y, -1})
	}
}

// Every subpath is filled as if closed.
@(private)
close :: proc(b: ^Builder) {
	if b.current != b.start {line_to(b, b.start)}
}

// Enough straight pieces that a curve of this drawn length stays within a small fraction of a pixel.
@(private)
pieces :: proc(length: f32) -> int {
	return clamp(int(math.ceil(math.sqrt(length * 8))), 1, 128)
}

@(private)
cubic_to :: proc(b: ^Builder, c1, c2, p: [2]f32) {
	p0 := b.current
	n := pieces((distance(p0, c1) + distance(c1, c2) + distance(c2, p)) * b.scale)
	for i in 1 ..= n {
		t := f32(i) / f32(n)
		u := 1 - t
		line_to(b, i == n ? p : u * u * u * p0 + 3 * u * u * t * c1 + 3 * u * t * t * c2 + t * t * t * p)
	}
	b.cubic = c2
}

@(private)
quad_to :: proc(b: ^Builder, c, p: [2]f32) {
	p0 := b.current
	n := pieces((distance(p0, c) + distance(c, p)) * b.scale)
	for i in 1 ..= n {
		t := f32(i) / f32(n)
		u := 1 - t
		line_to(b, i == n ? p : u * u * p0 + 2 * u * t * c + t * t * p)
	}
	b.quad = c
}

// Endpoint to centre conversion from the SVG specification, appendix B.2.4.
@(private)
arc_to :: proc(b: ^Builder, radius_x, radius_y, rotation: f32, large, sweep: bool, p: [2]f32) {
	p0 := b.current
	if p0 == p {return}
	rx, ry := radius_x, radius_y
	if rx == 0 || ry == 0 {line_to(b, p); return}
	phi := rotation * math.PI / 180
	cos, sin := math.cos(phi), math.sin(phi)
	half := (p0 - p) / 2
	x1 := cos * half.x + sin * half.y
	y1 := -sin * half.x + cos * half.y
	if lambda := x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry); lambda > 1 {
		rx *= math.sqrt(lambda)
		ry *= math.sqrt(lambda)
	}
	numerator := rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
	denominator := rx * rx * y1 * y1 + ry * ry * x1 * x1
	factor := math.sqrt(max(0, numerator / denominator))
	if large == sweep {factor = -factor}
	cx1, cy1 := factor * rx * y1 / ry, -factor * ry * x1 / rx
	centre := [2]f32{cos * cx1 - sin * cy1, sin * cx1 + cos * cy1} + (p0 + p) / 2
	start := angle({1, 0}, {(x1 - cx1) / rx, (y1 - cy1) / ry})
	delta := angle({(x1 - cx1) / rx, (y1 - cy1) / ry}, {(-x1 - cx1) / rx, (-y1 - cy1) / ry})
	if !sweep && delta > 0 {delta -= 2 * math.PI}
	if sweep && delta < 0 {delta += 2 * math.PI}
	n := pieces(abs(delta) * max(rx, ry) * b.scale)
	for i in 1 ..= n {
		if i == n {line_to(b, p); break}
		t := start + delta * f32(i) / f32(n)
		x, y := rx * math.cos(t), ry * math.sin(t)
		line_to(b, centre + {cos * x - sin * y, sin * x + cos * y})
	}
}

@(private)
angle :: proc(u, v: [2]f32) -> f32 {
	return math.atan2(u.x * v.y - u.y * v.x, u.x * v.x + u.y * v.y)
}

@(private)
distance :: proc(a, b: [2]f32) -> f32 {
	d := b - a
	return math.sqrt(d.x * d.x + d.y * d.y)
}
