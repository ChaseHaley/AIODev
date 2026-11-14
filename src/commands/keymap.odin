package commands

import "aio:input"
import "core:strings"

Key_Sequence :: struct {
	mode: string,
	chords: [4]Shortcut,
	count: int,
}
Command_Target :: struct {
	id: Command_Id,
	fields: string,
}
// Nil is never stored: keymap_bind refuses it, so a Run always carries a variant.
Binding_Target :: union {Command_Target}
Binding :: struct {
	sequence: Key_Sequence,
	target: Binding_Target,
	source: string,
}
Mode :: struct {
	name: string,
	exclusive: bool,
}
// Stored strings belong to the keymap; callers may release their source after binding.
Keymap :: struct {
	bindings: [dynamic]Binding,
	modes: [dynamic]Mode,
	blocked: [dynamic]Key_Sequence,
}
Key_Chord :: struct {
	physical: input.Key,
	modifiers: input.Modifiers,
	unshifted: rune,
}
Mode_Entry :: struct {
	name: string,
	once: bool,
}
Key_State :: struct {
	pending: [4]Key_Chord,
	count: int,
	// The layer that accepted the first chord owns the rest of the sequence.
	layer: int,
	modes: [dynamic]Mode_Entry,
}
Run :: struct {binding: Binding}
Pending :: struct {}
Pass :: struct {}
Blocked :: struct {}
Feed_Result :: union #no_nil {Run, Pending, Pass, Blocked}
Keymap_Conflict :: struct {
	sequence: Key_Sequence,
	winner, loser: Binding_Target,
	winner_source, loser_source: string,
}

@(private)
mode_name_valid :: proc(name: string) -> bool {
	if name == "" {return false}
	for c in name {
		if !(c >= 'a' && c <= 'z') && !(c >= '0' && c <= '9') && c != '_' && c != '-' {return false}
	}
	return true
}

@(require_results)
parse_sequence :: proc(text: string) -> (Key_Sequence, bool) {
	result: Key_Sequence
	rest := strings.trim_space(text)
	// Slash is also a key: only a nonempty prefix can name a mode.
	if slash := strings.index_byte(rest, '/'); slash > 0 {
		if mode_name_valid(rest[:slash]) {
			result.mode = rest[:slash]
			rest = rest[slash + 1:]
		}
	}
	for {
		if result.count == len(result.chords) {return {}, false}
		separator := strings.index_byte(rest, '>')
		part := separator < 0 ? rest : rest[:separator]
		chord, ok := parse_shortcut(part)
		if !ok || input.is_modifier_key(chord.key) {return {}, false}
		result.chords[result.count] = chord
		result.count += 1
		if separator < 0 {return result, true}
		rest = rest[separator + 1:]
	}
}

sequence_equal :: proc(a, b: Key_Sequence) -> bool {
	if a.mode != b.mode || a.count != b.count {return false}
	for i in 0 ..< a.count {
		if !shortcut_equal(a.chords[i], b.chords[i]) {return false}
	}
	return true
}

keymap_init :: proc(keymap: ^Keymap, allocator := context.allocator) {
	keymap.bindings.allocator = allocator
	keymap.modes.allocator = allocator
	keymap.blocked.allocator = allocator
}

@(private)
binding_release :: proc(keymap: ^Keymap, binding: Binding) {
	allocator := keymap.bindings.allocator
	delete(binding.sequence.mode, allocator)
	delete(binding.source, allocator)
	switch target in binding.target {
	case nil:
	case Command_Target:
		delete(target.fields, allocator)
	}
}

keymap_clear :: proc(keymap: ^Keymap) {
	for binding in keymap.bindings {binding_release(keymap, binding)}
	for mode in keymap.modes {delete(mode.name, keymap.modes.allocator)}
	for sequence in keymap.blocked {delete(sequence.mode, keymap.blocked.allocator)}
	clear(&keymap.bindings)
	clear(&keymap.modes)
	clear(&keymap.blocked)
}

keymap_destroy :: proc(keymap: ^Keymap) {
	keymap_clear(keymap)
	delete(keymap.bindings)
	delete(keymap.modes)
	delete(keymap.blocked)
	keymap^ = {}
}

@(require_results)
mode_declare :: proc(keymap: ^Keymap, mode: Mode) -> Error {
	if !mode_name_valid(mode.name) {return .Invalid_Shortcut}
	for &stored in keymap.modes {
		if stored.name == mode.name {stored.exclusive = mode.exclusive; return .None}
	}
	name, err := strings.clone(mode.name, keymap.modes.allocator)
	if err != nil {return .Out_Of_Memory}
	_, append_error := append(&keymap.modes, Mode{name, mode.exclusive})
	if append_error != nil {delete(name, keymap.modes.allocator); return .Out_Of_Memory}
	return .None
}

@(private)
keymap_unblock :: proc(keymap: ^Keymap, sequence: Key_Sequence) {
	for stored, i in keymap.blocked {
		if sequence_equal(stored, sequence) {
			delete(stored.mode, keymap.blocked.allocator)
			ordered_remove(&keymap.blocked, i)
			return
		}
	}
}

@(require_results)
keymap_bind :: proc(keymap: ^Keymap, binding: Binding) -> Error {
	sequence := binding.sequence
	// A nil target never runs, so it is refused rather than stored.
	if binding.target == nil {return .Unknown_Command}
	if sequence.count < 1 || sequence.count > len(sequence.chords) ||
	   (sequence.mode != "" && !mode_name_valid(sequence.mode)) {return .Invalid_Shortcut}
	// A complete binding cannot also be a prefix: neither alternative should become unreachable.
	for stored in keymap.bindings {
		if stored.sequence.mode != sequence.mode || stored.sequence.count == sequence.count {continue}
		prefix := true
		for i in 0 ..< min(sequence.count, stored.sequence.count) {
			if !shortcut_equal(sequence.chords[i], stored.sequence.chords[i]) {prefix = false; break}
		}
		if prefix {return .Duplicate_Shortcut}
	}
	allocator := keymap.bindings.allocator
	owned := binding
	name, name_error := strings.clone(sequence.mode, allocator)
	if name_error != nil {return .Out_Of_Memory}
	owned.sequence.mode = name
	source, source_error := strings.clone(binding.source, allocator)
	if source_error != nil {delete(name, allocator); return .Out_Of_Memory}
	owned.source = source
	switch target in binding.target {
	case nil:
	case Command_Target:
		fields, err := strings.clone(target.fields, allocator)
		if err != nil {delete(name, allocator); delete(source, allocator); return .Out_Of_Memory}
		owned.target = Command_Target{target.id, fields}
	}
	for &stored in keymap.bindings {
		if sequence_equal(stored.sequence, sequence) {
			binding_release(keymap, stored)
			stored = owned
			keymap_unblock(keymap, sequence)
			return .None
		}
	}
	_, err := append(&keymap.bindings, owned)
	if err != nil {binding_release(keymap, owned); return .Out_Of_Memory}
	keymap_unblock(keymap, sequence)
	return .None
}

@(require_results)
keymap_block :: proc(keymap: ^Keymap, sequence: Key_Sequence) -> Error {
	if sequence.mode == "" || !mode_name_valid(sequence.mode) || sequence.count < 1 ||
	   sequence.count > len(sequence.chords) {return .Invalid_Shortcut}
	for stored in keymap.blocked {if sequence_equal(stored, sequence) {return .None}}
	owned := sequence
	name, err := strings.clone(sequence.mode, keymap.blocked.allocator)
	if err != nil {return .Out_Of_Memory}
	owned.mode = name
	_, append_error := append(&keymap.blocked, owned)
	if append_error != nil {delete(name, keymap.blocked.allocator); return .Out_Of_Memory}
	return .None
}

@(private)
binding_target_equal :: proc(a, b: Binding_Target) -> bool {
	switch target in a {
	case nil:
		return b == nil
	case Command_Target:
		other, ok := b.(Command_Target)
		return ok && target.id == other.id && target.fields == other.fields
	}
	return false
}

// Removing a mode key masks lower layers even when this layer had no binding for it. A nil target
// removes whatever the sequence runs; any other target removes the binding only when it runs that.
@(require_results)
keymap_unbind :: proc(keymap: ^Keymap, sequence: Key_Sequence, target: Binding_Target = nil) -> Error {
	index := -1
	for stored, i in keymap.bindings {
		if !sequence_equal(stored.sequence, sequence) {continue}
		if target != nil && !binding_target_equal(stored.target, target) {return .None}
		index = i
		break
	}
	if index < 0 && target != nil {return .None}
	if sequence.mode != "" {
		if err := keymap_block(keymap, sequence); err != .None {return err}
	}
	if index >= 0 {
		binding_release(keymap, keymap.bindings[index])
		ordered_remove(&keymap.bindings, index)
	}
	return .None
}

key_pending_clear :: proc(state: ^Key_State) {
	state.count = 0
}

@(require_results)
mode_enter :: proc(keymap: ^Keymap, state: ^Key_State, name: string, once := false) -> bool {
	known := false
	if state.modes.allocator.procedure == nil {state.modes.allocator = context.allocator}
	for mode in keymap.modes {if mode.name == name {known = true; break}}
	if !known {return false}
	owned, err := strings.clone(name, state.modes.allocator)
	if err != nil {return false}
	_, append_error := append(&state.modes, Mode_Entry{owned, once})
	if append_error != nil {delete(owned, state.modes.allocator); return false}
	key_pending_clear(state)
	return true
}

mode_exit :: proc(state: ^Key_State) {
	key_pending_clear(state)
	if len(state.modes) == 0 {return}
	delete(state.modes[len(state.modes) - 1].name, state.modes.allocator)
	ordered_remove(&state.modes, len(state.modes) - 1)
}

mode_exit_all :: proc(state: ^Key_State) {
	for len(state.modes) > 0 {mode_exit(state)}
	key_pending_clear(state)
}

key_state_destroy :: proc(state: ^Key_State) {
	mode_exit_all(state)
	delete(state.modes)
	state^ = {}
}

@(private)
sequence_matches :: proc(sequence: Key_Sequence, state: ^Key_State) -> (bool, int) {
	if sequence.count < state.count {return false, 0}
	score := 0
	for i in 0 ..< state.count {
		chord := state.pending[i]
		if !shortcut_matches(sequence.chords[i], chord.physical, chord.modifiers, chord.unshifted) {return false, 0}
		score *= 2
		if .Physical in sequence.chords[i].modifiers {score += 1}
	}
	return true, score
}

@(private)
feed_layer :: proc(keymap: ^Keymap, state: ^Key_State, registry: ^Registry, layer: int) -> Feed_Result {
	name := layer < 0 ? "" : state.modes[layer].name
	exclusive := false
	for mode in keymap.modes {if mode.name == name {exclusive = mode.exclusive; break}}
	best: ^Binding
	best_score := -1
	prefix_score := -1
	for &binding in keymap.bindings {
		if binding.sequence.mode != name {continue}
		matches, score := sequence_matches(binding.sequence, state)
		if !matches {continue}
		if binding.sequence.count > state.count {prefix_score = max(prefix_score, score); continue}
		if score > best_score {best, best_score = &binding, score}
	}
	for sequence in keymap.blocked {
		if sequence.mode != name {continue}
		matches, score := sequence_matches(sequence, state)
		if !matches {continue}
		if sequence.count == state.count {return Blocked{}}
		prefix_score = max(prefix_score, score)
	}
	// A shortcut set in Settings outranks the keymap's normal layer, prefixes included, because the user
	// chose it last; mode bindings stay above it. Checked only after a match, so unbound typing never
	// walks the registry twice.
	if layer < 0 && state.count == 1 && (best != nil || prefix_score >= 0) {
		chord := state.pending[0]
		if command := find_by_key(registry, chord.physical, chord.modifiers, chord.unshifted);
		   command != nil && !shortcut_set_equal(command.shortcuts, command.defaults) {return Pass{}}
	}
	if prefix_score > best_score {state.layer = layer; return Pending{}}
	if best != nil {return Run{best^}}
	chord := state.pending[state.count - 1]
	if layer >= 0 && chord.physical == .Escape {
		mode_exit(state)
		return Blocked{}
	}
	if exclusive {return Blocked{}}
	return Pass{}
}

// Every mode the key passed through on its way to the binding counts that binding as its one.
@(private)
once_modes_exit :: proc(state: ^Key_State, layer: int) {
	for i := len(state.modes) - 1; i >= max(layer, 0); i -= 1 {
		if !state.modes[i].once {continue}
		delete(state.modes[i].name, state.modes.allocator)
		ordered_remove(&state.modes, i)
	}
}

// The hot path borrows existing storage and does not allocate. A failed continuation is consumed,
// rather than sending the tail of an app-owned sequence to the terminal.
@(require_results)
feed :: proc(keymap: ^Keymap, state: ^Key_State, registry: ^Registry, physical: input.Key,
             modifiers: input.Modifiers, unshifted: rune) -> Feed_Result {
	if input.is_modifier_key(physical) {return Pass{}}
	continuing := state.count > 0
	if state.count == len(state.pending) {key_pending_clear(state)}
	state.pending[state.count] = {physical, modifiers, unshifted}
	state.count += 1
	if continuing {
		layer := state.layer
		result := feed_layer(keymap, state, registry, layer)
		if _, pending := result.(Pending); pending {return result}
		key_pending_clear(state)
		if _, run := result.(Run); run {once_modes_exit(state, layer)}
		if _, pass := result.(Pass); pass {return Blocked{}}
		return result
	}
	for layer := len(state.modes) - 1; layer >= -1; layer -= 1 {
		result := feed_layer(keymap, state, registry, layer)
		if _, pass := result.(Pass); pass {continue}
		if _, pending := result.(Pending); pending {return result}
		key_pending_clear(state)
		if _, run := result.(Run); run {once_modes_exit(state, layer)}
		return result
	}
	key_pending_clear(state)
	return Pass{}
}

// Each normal-layer binding whose first chord a registry command also holds: the keymap beats defaults,
// and a shortcut set in Settings beats the keymap. Strings borrow the keymap and registry; the list
// belongs to allocator.
@(require_results)
keymap_conflicts :: proc(
	keymap: ^Keymap,
	registry: ^Registry,
	allocator := context.allocator,
) -> []Keymap_Conflict {
	result := make([dynamic]Keymap_Conflict, allocator)
	for binding in keymap.bindings {
		if binding.sequence.mode != "" {continue}
		if command := find_by_shortcut(registry, binding.sequence.chords[0]); command != nil {
			registry_target: Binding_Target = Command_Target{id = command.id}
			conflict := Keymap_Conflict{sequence = binding.sequence}
			if shortcut_set_equal(command.shortcuts, command.defaults) {
				conflict.winner, conflict.loser = binding.target, registry_target
				conflict.winner_source, conflict.loser_source = binding.source, "defaults"
			} else {
				conflict.winner, conflict.loser = registry_target, binding.target
				conflict.winner_source, conflict.loser_source = "settings", binding.source
			}
			append(&result, conflict)
		}
	}
	return result[:]
}
