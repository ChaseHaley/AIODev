package frecency

import "base:runtime"
import "core:math"
import "core:strings"

// Frecency: how often and how recently something was used, as one number. Every use adds 1 to a weight
// that halves each HALF_LIFE, so a use a week old counts half as much as one now, and ten uses a month
// ago count for less than one today.
HALF_LIFE :: 7 * 24 * 60 * 60
// The most entries one table keeps. Recording past it drops the entry with the lowest score.
LIMIT :: 256

// One item's uses: how many, the last one in Unix seconds, and the decayed weight at that moment.
Usage :: struct {
	count:  int,
	last:   i64,
	weight: f64,
}

// The usage's weight at `now`. A clock that moved back counts the last use as current.
score :: proc(u: Usage, now: i64) -> f64 {
	if u.count <= 0 || u.weight <= 0 {return 0}
	age := f64(max(0, now - u.last))
	return u.weight * math.pow(2, -age / HALF_LIFE)
}

// The usage after one more use at `now`.
use :: proc(u: Usage, now: i64) -> Usage {
	return {count = u.count + 1, last = max(now, u.last), weight = score(u, now) + 1}
}

// Bounded usage keyed by a stable identity: a command name, a setting key, a tab id. String keys are
// owned copies.
Table :: struct($K: typeid) {
	entries: map[K]Usage,
}

destroy :: proc(t: ^Table($K)) {
	when K == string {
		for key in t.entries {delete(key)}
	}
	delete(t.entries)
	t^ = {}
}

lookup :: proc(t: ^Table($K), key: K, now: i64) -> f64 {
	u, found := t.entries[key]
	return found ? score(u, now) : 0
}

// Records one use of `key` at `now`. False, with the table unchanged, when its storage could not grow.
record :: proc(t: ^Table($K), key: K, now: i64) -> bool {
	if u, found := &t.entries[key]; found {
		u^ = use(u^, now)
		return true
	}
	return put(t, key, use({}, now), now)
}

// Adds a stored usage, as reading saved usage does; an entry already present keeps its usage.
restore :: proc(t: ^Table($K), key: K, u: Usage, now: i64) -> bool {
	if key in t.entries || u.count <= 0 {return true}
	return put(t, key, u, now)
}

@(private)
put :: proc(t: ^Table($K), key: K, u: Usage, now: i64) -> bool {
	if len(t.entries) >= LIMIT {evict(t, now)}
	owned := key
	when K == string {
		copied, err := clone_key(key)
		if err != nil {return false}
		owned = copied
	}
	if map_insert(&t.entries, owned, u) == nil {
		when K == string {delete(owned)}
		return false
	}
	return true
}

// Outside the polymorphic procs, which are checked only where a package instantiates them.
@(private)
clone_key :: proc(key: string) -> (string, runtime.Allocator_Error) {return strings.clone(key)}

// Drops the entry with the lowest score, the oldest of equals.
@(private)
evict :: proc(t: ^Table($K), now: i64) {
	victim: K
	lowest := max(f64)
	oldest := max(i64)
	found := false
	for key, u in t.entries {
		s := score(u, now)
		if found && (s > lowest || (s == lowest && u.last >= oldest)) {continue}
		victim, lowest, oldest, found = key, s, u.last, true
	}
	if !found {return}
	delete_key(&t.entries, victim)
	when K == string {delete(victim)}
}
