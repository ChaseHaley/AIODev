package commands

import "aio:input"
import "core:reflect"
import "core:strings"

// How a binding answers a search, weakest first. Settings and the palette rank by it.
Shortcut_Match :: enum u8 {
	None,
	// The query's letters run through the label's parts in order and reach its key ("al8").
	Label,
	// The binding holds the modifiers asked for, with any key: a query naming no key, held
	// modifiers, or the leader alone.
	Modifiers,
	// The query's key under every modifier it names, and more besides.
	Partial,
	// The chord asked for, exactly.
	Exact,
}

// What one binding matched and which parts of its label did: modifiers (Leader included) and the key.
Shortcut_Hit :: struct {
	match:     Shortcut_Match,
	modifiers: input.Modifiers,
	key:       bool,
}

// The longest query whose letters are compared with labels; a longer query is never a label match.
@(private = "file")
QUERY_LETTERS_CAP :: 64

// A typed search query, read once for every binding it is compared with. `chord` when the text uses the
// shortcut grammar: modifier words or initials (`ctrl+shift+c`, `cs c`, `alt8`, `leader h`) and a key
// when `keyed`. `letters` is the text lowercased without spaces or plus signs.
Shortcut_Query :: struct {
	modifiers:     input.Modifiers,
	key:           input.Key,
	chord, keyed:  bool,
	letters:       [QUERY_LETTERS_CAP]u8,
	letters_count: int,
}

@(private = "file", rodata)
QUERY_MODIFIER_WORDS := [?]struct {
	word:     string,
	modifier: input.Modifier,
} {
	{"control", .Control},
	{"leader", .Leader},
	{"shift", .Shift},
	{"ctrl", .Control},
	{"alt", .Alt},
	{SUPER_LABEL, .Super},
}

@(private = "file", rodata)
QUERY_KEY_ALIASES := [?]struct {
	word: string,
	key:  input.Key,
} {
	{"pgup", .Page_Up},
	{"pgdn", .Page_Down},
	{"ins", .Insert},
	{"del", .Delete},
	{"return", .Enter},
}

@(private = "file")
QUERY_SEPARATORS :: " \t+"

@(private = "file")
query_modifier :: proc(word: string) -> (input.Modifier, bool) {
	for entry in QUERY_MODIFIER_WORDS {
		if strings.equal_fold(word, entry.word) {return entry.modifier, true}
	}
	return {}, false
}

// One to four modifier initials before the key, such as the `cs` of `cs c`.
@(private = "file")
query_initials :: proc(word: string) -> (modifiers: input.Modifiers, ok: bool) {
	if len(word) == 0 || len(word) > 4 {return}
	for c in transmute([]u8)word {
		switch c | 0x20 {
		case 'c': modifiers += {.Control}
		case 's': modifiers += {.Shift}
		case 'a': modifiers += {.Alt}
		case 'w': modifiers += {.Super}
		case 'l': modifiers += {.Leader}
		case: return {}, false
		}
	}
	return modifiers, true
}

// Whether `text` names `name`, ignoring case and the underscores of enum names (`pageup`, `arrowleft`).
@(private = "file")
key_name_equal :: proc(text, name: string) -> bool {
	i := 0
	for j in 0 ..< len(name) {
		c := name[j]
		if c == '_' {continue}
		if i == len(text) || (text[i] | 0x20) != (c | 0x20) {return false}
		i += 1
	}
	return i == len(text)
}

// The key a query word names: its label, its enum name or a short alias. Modifier keys name no chord.
@(private = "file")
query_key :: proc(word: string) -> (input.Key, bool) {
	if word == "" {return {}, false}
	for alias in QUERY_KEY_ALIASES {
		if strings.equal_fold(word, alias.word) {return alias.key, true}
	}
	buffer: [SHORTCUT_TEXT_CAP]u8
	for key in input.Key {
		if key == .Unidentified || input.is_modifier_key(key) {continue}
		if strings.equal_fold(word, shortcut_text({key, {}}, buffer[:])) {return key, true}
		if name, named := reflect.enum_name_from_value(key); named && key_name_equal(word, name) {
			return key, true
		}
	}
	return {}, false
}

// Reads the shortcut grammar. A lone character without modifiers is ordinary text, never a chord.
@(private = "file")
query_chord :: proc(text: string) -> (modifiers: input.Modifiers, key: input.Key, keyed, ok: bool) {
	rest := strings.trim_left(strings.trim_space(text), QUERY_SEPARATORS)
	for {
		end := strings.index_any(rest, QUERY_SEPARATORS)
		if end < 0 {break}
		word := rest[:end]
		after := strings.trim_left(rest[end:], QUERY_SEPARATORS)
		if after == "" {break}
		if modifier, named := query_modifier(word); named {
			modifiers += {modifier}
		} else if initials, initialled := query_initials(word); initialled {
			modifiers += initials
		} else {
			break
		}
		rest = after
	}
	if modifier, named := query_modifier(strings.trim_right(rest, QUERY_SEPARATORS)); named {
		return modifiers + {modifier}, {}, false, true
	}
	// Modifier words written against the key: `alt8`, `ctrlshiftc`.
	glued: for {
		for entry in QUERY_MODIFIER_WORDS {
			if len(rest) > len(entry.word) && strings.equal_fold(rest[:len(entry.word)], entry.word) {
				modifiers += {entry.modifier}
				rest = rest[len(entry.word):]
				continue glued
			}
		}
		break
	}
	found: bool
	key, found = query_key(rest)
	if !found {return {}, {}, false, false}
	if modifiers == {} && len(rest) < 2 {return {}, {}, false, false}
	return modifiers, key, true, true
}

shortcut_query :: proc(text: string) -> Shortcut_Query {
	q: Shortcut_Query
	for c in transmute([]u8)text {
		if c == ' ' || c == '\t' || c == '+' {continue}
		if q.letters_count == len(q.letters) {
			q.letters_count = 0
			break
		}
		q.letters[q.letters_count] = c >= 'A' && c <= 'Z' ? c | 0x20 : c
		q.letters_count += 1
	}
	q.modifiers, q.key, q.keyed, q.chord = query_chord(text)
	return q
}

// One part of a shortcut label: a modifier word, or the key, which is always last.
Label_Part :: struct {
	text:        string,
	modifier:    input.Modifier,
	is_modifier: bool,
}

// The part that starts `rest`, and the rest after it. A key label may itself hold a plus sign ("Num+"),
// so only a modifier word ends at one.
@(require_results)
shortcut_label_next :: proc(rest: ^string) -> (part: Label_Part, ok: bool) {
	if rest^ == "" {return}
	if plus := strings.index_byte(rest^, '+'); plus > 0 {
		if modifier, named := modifier_named(rest^[:plus]); named {
			part = {rest^[:plus], modifier, true}
			rest^ = rest^[plus + 1:]
			return part, true
		}
	}
	part = {text = rest^}
	rest^ = ""
	return part, true
}

// Compares a typed query with one binding. A chord query matches only by the grammar; other text
// matches the label's letters, which must start at a part and reach the key through two parts or more.
shortcut_query_match :: proc(q: ^Shortcut_Query, shortcut: Shortcut) -> Shortcut_Hit {
	held := chord_modifiers(shortcut.modifiers)
	if q.chord {
		if !(q.modifiers <= held) {return {}}
		if !q.keyed {return {.Modifiers, q.modifiers, false}}
		if shortcut.key != q.key {return {}}
		return {q.modifiers == held ? .Exact : .Partial, q.modifiers, true}
	}
	if q.letters_count < 2 {return {}}
	buffer: [SHORTCUT_TEXT_CAP]u8
	label := shortcut_text({shortcut.key, held}, buffer[:])
	// Each label letter's part: a modifier, or the key as the part after the last modifier.
	parts: [SHORTCUT_TEXT_CAP]u8
	modifiers: [8]input.Modifier
	count, length: int
	letters: [SHORTCUT_TEXT_CAP]u8
	rest := label
	for part in shortcut_label_next(&rest) {
		modifiers[count] = part.modifier
		for c in transmute([]u8)part.text {
			if c == ' ' {continue}
			letters[length] = c >= 'A' && c <= 'Z' ? c | 0x20 : c
			parts[length] = u8(count)
			length += 1
		}
		if !part.is_modifier {break}
		count += 1
	}
	key_part := u8(count)
	want := q.letters[:q.letters_count]
	for start in 0 ..< length {
		if letters[start] != want[0] || (start > 0 && parts[start - 1] == parts[start]) {continue}
		hit: bit_set[0 ..< 8]
		matched := 0
		for i := start; i < length && matched < len(want); i += 1 {
			if letters[i] != want[matched] {continue}
			hit += {int(parts[i])}
			matched += 1
		}
		if matched < len(want) || int(key_part) not_in hit || card(hit) < 2 {continue}
		result := Shortcut_Hit{match = .Label, key = true}
		for i in 0 ..< count {if i in hit {result.modifiers += {modifiers[i]}}}
		return result
	}
	return {}
}

// The chord a query names in full: its key with a held modifier or the leader, which a binding needs
// for a typing key. False when the query names no such chord.
shortcut_query_chord :: proc(q: ^Shortcut_Query) -> (Shortcut, bool) {
	if !q.chord || !q.keyed || q.modifiers & {.Control, .Alt, .Super, .Leader} == {} {return {}, false}
	return {q.key, q.modifiers}, true
}

// What record mode has taken from the keyboard: modifiers held alone, the leader, or a chord, which
// keeps both key identities so a binding matches the way dispatch would match it.
Key_Press_State :: enum u8 {
	None,
	Held,
	Leader,
	Chord,
}

Key_Press :: struct {
	state:             Key_Press_State,
	// Held: the modifiers down; Chord: the chord's held modifiers.
	modifiers:         input.Modifiers,
	physical, logical: input.Key,
	// The chord followed the leader.
	leader:            bool,
}

@(private = "file")
key_modifier :: proc(key: input.Key) -> input.Modifiers {
	#partial switch key {
	case .Control_Left, .Control_Right: return {.Control}
	case .Shift_Left, .Shift_Right: return {.Shift}
	case .Alt_Left, .Alt_Right: return {.Alt}
	case .Meta_Left, .Meta_Right: return {.Super}
	}
	return {}
}

// Records one key press, as shortcut capture reads it: a modifier alone is held, the configured leader
// waits for its key, and anything else completes the chord, which the result reports.
key_press_record :: proc(press: ^Key_Press, e: input.Key_Event, leader: Maybe(Shortcut)) -> (complete: bool) {
	if e.repeat {return false}
	modifiers := e.modifiers & {.Control, .Shift, .Alt, .Super}
	if input.is_modifier_key(e.key) {
		held := key_modifier(e.key)
		if press.state == .Leader || held == {} {return false}
		press^ = {state = .Held, modifiers = modifiers + held}
		return false
	}
	pending := press.state == .Leader
	if chord, ok := leader.?; ok && !pending && shortcut_matches(chord, e.key, modifiers, e.unshifted) {
		press^ = {state = .Leader}
		return false
	}
	press^ = {
		state     = .Chord,
		modifiers = modifiers,
		physical  = e.key,
		logical   = logical_key(e.key, e.unshifted),
		leader    = pending,
	}
	return true
}

// Compares a recorded press with one binding: held modifiers list the bindings under exactly that set,
// the leader lists its sequences, and a chord matches as dispatch does, by position for Physical.
key_press_match :: proc(press: Key_Press, shortcut: Shortcut) -> Shortcut_Hit {
	held := chord_modifiers(shortcut.modifiers)
	switch press.state {
	case .None:
	case .Held:
		if held == press.modifiers {return {.Modifiers, held, false}}
	case .Leader:
		if .Leader in held {return {.Modifiers, {.Leader}, false}}
	case .Chord:
		modifiers := press.modifiers
		if press.leader {modifiers += {.Leader}}
		if binding_matches(shortcut, press.physical, press.logical, modifiers) {return {.Exact, held, true}}
	}
	return {}
}

// The recorded press as the shortcut grammar writes it ("Ctrl+Shift+C", "Leader+H", "Ctrl+Shift",
// "Leader"), which a text search reads back as the same keys; empty before anything is recorded.
key_press_text :: proc(press: Key_Press, out: []u8) -> string {
	switch press.state {
	case .None:
	case .Held, .Leader:
		modifiers := press.state == .Held ? press.modifiers : input.Modifiers{.Leader}
		length := 0
		for entry in modifier_words {
			if entry.modifier not_in modifiers {continue}
			if length > 0 {length += copy(out[length:], "+")}
			length += copy(out[length:], entry.word)
		}
		return string(out[:length])
	case .Chord:
		chord, _ := key_press_chord(press)
		return shortcut_text(chord, out)
	}
	return ""
}

// The chord a recorded press names, under the layout's key; ok when it is complete and could be bound,
// which a typing key needs a held modifier or the leader for.
key_press_chord :: proc(press: Key_Press) -> (chord: Shortcut, ok: bool) {
	if press.state != .Chord {return}
	chord = {press.logical, press.modifiers}
	if press.leader {chord.modifiers += {.Leader}}
	return chord, chord.modifiers & {.Control, .Alt, .Super, .Leader} != {}
}

// Whether no command binds `chord`, comparing keys as the grammar names them, so a Physical binding of
// the same key counts; the leader itself is never free.
shortcut_free :: proc(registry: ^Registry, chord: Shortcut, leader: Maybe(Shortcut)) -> bool {
	same :: proc(a, b: Shortcut) -> bool {
		return a.key == b.key && chord_modifiers(a.modifiers) == chord_modifiers(b.modifiers)
	}
	if l, ok := leader.?; ok && same(l, chord) {return false}
	for &item in registry.items {
		for binding in active_shortcuts(&item) {
			if same(binding, chord) {return false}
		}
	}
	return true
}

// The byte offsets of a label's matched parts, written to `out`, for drawing them highlighted.
shortcut_hit_positions :: proc(label: string, hit: Shortcut_Hit, out: []int) -> []int {
	count := 0
	rest := label
	offset := 0
	for part in shortcut_label_next(&rest) {
		lit := part.is_modifier ? part.modifier in hit.modifiers : hit.key
		for i in 0 ..< len(part.text) {
			if !lit || count == len(out) {break}
			out[count] = offset + i
			count += 1
		}
		offset += len(part.text) + 1
	}
	return out[:count]
}
