package settings

import "base:runtime"
import "core:strings"

@(private = "file")
STATUS_STATES :: [5]string{"idle", "working", "blocked", "error", "done"}

// Before per-state channel sets, status.notify_<state> was an on/off master and each channel had
// its own status.<channel>_<state> toggle. Returns the state index and, for a channel toggle, its
// channel; `master` marks the old on/off value of status.notify_<state>.
@(private = "file")
status_legacy_key :: proc(key, value: string) -> (state: int, channel: int, master, matches: bool) {
	if !strings.has_prefix(key, "status.") {return}
	rest := key[len("status."):]
	for name, i in STATUS_STATES {
		if rest == strings.concatenate({"notify_", name}, context.temp_allocator) {
			bare := strings.trim(strings.trim_space(value), "\"")
			if bare != "true" && bare != "false" {return}
			return i, -1, true, true
		}
		for channel_name, c in STATUS_CHANNEL_NAMES {
			if rest == strings.concatenate({channel_name, "_", name}, context.temp_allocator) {
				return i, c, false, true
			}
		}
	}
	return
}

// Rewrites the old master and channel toggles into one status.notify_<state> set per state, keeping
// what they delivered: an off master becomes none, and missing toggles take their old defaults.
@(require_results)
migrate_status_notify_text :: proc(
	text: string,
	allocator := context.allocator,
) -> (
	updated: string,
	migrated: bool,
	err: runtime.Allocator_Error,
) {
	// Old defaults: blocked and error were on; every state used banner and sound.
	master := [5]bool{false, false, true, true, false}
	channels: [5]u32
	for &c in channels {c = u32(1 << u32(Status_Channel.Banner) | 1 << u32(Status_Channel.Sound))}
	legacy: [5]bool
	scanner := line_scanner_init(text)
	for {
		line, ok := line_next(&scanner)
		if !ok {break}
		if !line.split {continue}
		state, channel, is_master, matches := status_legacy_key(line.key, line.value)
		if !matches {continue}
		legacy[state] = true
		on := strings.trim(strings.trim_space(line.value), "\"") == "true"
		if is_master {
			master[state] = on
		} else if on {
			channels[state] |= 1 << u32(channel)
		} else {
			channels[state] &~= 1 << u32(channel)
		}
	}
	if !(legacy[0] || legacy[1] || legacy[2] || legacy[3] || legacy[4]) {return "", false, nil}

	builder := strings.builder_make(allocator) or_return
	defer strings.builder_destroy(&builder)
	rescanner := line_scanner_init(text)
	if rescanner.bom {write_parts(&builder, UTF8_BOM) or_return}
	written: [5]bool
	// A comment directly above a removed key described that key, so it goes with it.
	held: string
	for {
		line, ok := line_next(&rescanner)
		if !ok {break}
		state := -1
		if line.split {
			if s, _, _, matches := status_legacy_key(line.key, line.value); matches {state = s}
		}
		if state < 0 {
			if held != "" {write_parts(&builder, held) or_return}
			held = ""
			if strings.has_prefix(line.text, "#") {held = line.raw} else {write_parts(&builder, line.raw) or_return}
			continue
		}
		if written[state] {
			held = ""
			continue
		}
		written[state] = true
		states := STATUS_STATES
		key := strings.concatenate({"status.notify_", states[state]}, context.temp_allocator)
		if held != "" {
			write_parts(&builder, "# ", schema_find(key).description, line.eol) or_return
		}
		held = ""
		value := set_text(STATUS_CHANNEL_NAMES, master[state] ? channels[state] : 0)
		write_parts(&builder, key, " = ", value, line.eol) or_return
	}
	if held != "" {write_parts(&builder, held) or_return}
	updated = strings.clone(strings.to_string(builder), allocator) or_return
	return updated, true, nil
}
