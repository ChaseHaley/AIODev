package main

import "aio:commands"
import "aio:settings"
import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"

// One side of a binding conflict and the source line that supplied its effective shortcut.
Binding_Source :: struct {
	name, title: string,
	line:        int,
}

// Both sides of a rejected shortcut, with the effective source line for each.
Binding_Conflict :: struct {
	shortcut:    commands.Shortcut,
	leader_text: string,
	loser:       Binding_Source,
	winner:      Binding_Source,
}

Binding_Issue_Kind :: enum {
	Unknown_Command,
	Invalid_Shortcut,
	Unsupported_Leader_Shortcut,
	Apply_Failed,
	Duplicate_Shortcut,
	Leader_Prefix,
}

// One binding setting that could not apply. Conflicts carry both sides so callers never parse text.
Binding_Issue :: struct {
	kind:        Binding_Issue_Kind,
	severity:    settings.Diagnostic_Kind,
	line:        int,
	key:         string,
	name, value: string,
	apply_error: commands.Error,
	conflict:    Binding_Conflict,
}

// Issues live in the temp allocator; consume the report before the frame ends.
Binding_Report :: struct {
	issues: []Binding_Issue,
	leader: Maybe(commands.Shortcut),
}

// Applies the file's overrides and leader policy to the registry, then reports what happened.
// Origins are the effective ones: a rejected override leaves its command on defaults.
@(require_results)
binding_report :: proc(
	registry: ^commands.Registry,
	s: ^settings.Settings,
) -> (
	report: Binding_Report,
	alloc_error: runtime.Allocator_Error,
) {
	issues := make([dynamic]Binding_Issue, context.temp_allocator)
	overrides: [len(Action)]commands.Override
	lines: [len(Action)]int
	count := 0
	for binding, i in s.keys {
		command := commands.find(registry, binding.name)
		if command == nil {
			issue := Binding_Issue {
				kind     = .Unknown_Command,
				severity = .Invalid_Value,
				line     = binding.line,
				key      = binding_key(binding.name),
				name     = binding.name,
			}
			if _, err := append(&issues, issue); err != nil {
				report.issues = issues[:]
				return report, err
			}
			continue
		}
		storage := make([]commands.Shortcut, len(binding.value) + 1, context.temp_allocator)
		n, parse_error := commands.parse_shortcuts(binding.value, storage)
		if parse_error != .None {
			issue := Binding_Issue {
				kind     = .Invalid_Shortcut,
				severity = .Invalid_Value,
				line     = binding.line,
				key      = binding_key(binding.name),
				name     = binding.name,
				value    = binding.value,
			}
			if _, err := append(&issues, issue); err != nil {
				report.issues = issues[:]
				return report, err
			}
			continue
		}
		unsupported := false
		for shortcut in storage[:n] {
			if .Leader in shortcut.modifiers &&
			   (shortcut.key == .Unidentified || is_modifier_key(shortcut.key)) {
				unsupported = true
			}
		}
		if unsupported {
			issue := Binding_Issue {
				kind     = .Unsupported_Leader_Shortcut,
				severity = .Invalid_Value,
				line     = binding.line,
				key      = binding_key(binding.name),
				name     = binding.name,
			}
			if _, err := append(&issues, issue); err != nil {
				report.issues = issues[:]
				return report, err
			}
			continue
		}
		overrides[count] = {command.id, storage[:n]}
		lines[count] = i
		count += 1
	}
	errors: [len(Action)]commands.Error
	if commands.rebind(registry, overrides[:count], errors[:count]) != .None {
		report.issues = issues[:]
		return report, .Out_Of_Memory
	}
	applied_lines: [len(Action)]int
	for error, i in errors[:count] {
		if error == .None {
			applied_lines[int(overrides[i].id)] = s.keys[lines[i]].line
		}
	}
	for error, i in errors[:count] {
		if error == .None {continue}
		binding := s.keys[lines[i]]
		issue := Binding_Issue {
			kind        = .Apply_Failed,
			severity    = .Invalid_Value,
			line        = binding.line,
			key         = binding_key(binding.name),
			name        = binding.name,
			apply_error = error,
		}
		if error == .Duplicate_Shortcut {
			for shortcut in overrides[i].shortcuts {
				other := commands.find_by_shortcut(registry, shortcut)
				if other != nil && other.id != overrides[i].id {
					issue.kind = .Duplicate_Shortcut
					issue.conflict = {
						shortcut = shortcut,
						loser    = {
							name  = binding.name,
							title = commands.find(registry, binding.name).title,
							line  = binding.line,
						},
						winner   = {
							name  = other.name,
							title = other.title,
							line  = applied_lines[int(other.id)],
						},
					}
					break
				}
			}
		}
		if _, err := append(&issues, issue); err != nil {
			report.issues = issues[:]
			return report, err
		}
	}
	if s.input.leader != "" {
		leader, valid := commands.parse_shortcut(s.input.leader)
		if !valid ||
		   .Leader in leader.modifiers ||
		   leader.key == .Unidentified ||
		   is_modifier_key(leader.key) {
			issue := Binding_Issue {
				kind     = .Unsupported_Leader_Shortcut,
				severity = .Invalid_Value,
				line     = s.leader_line,
				key      = "input.leader",
			}
			if _, err := append(&issues, issue); err != nil {
				report.issues = issues[:]
				return report, err
			}
		} else {
			winner: ^commands.Command
			for &other in registry.items {
				for shortcut in commands.active_shortcuts(&other) {
					if commands.prefix_conflicts(leader, shortcut) &&
					   applied_lines[int(other.id)] >= s.leader_line &&
					   (winner == nil ||
							   applied_lines[int(other.id)] > applied_lines[int(winner.id)]) {
						winner = &other
					}
				}
			}
			leader_wins := winner == nil
			winner_source: Binding_Source
			if leader_wins {
				winner_source = {"input.leader", "", s.leader_line}
				report.leader = leader
			} else {
				winner_source = {winner.name, winner.title, applied_lines[int(winner.id)]}
			}
			for &other in registry.items {
				// Copy because unbind compacts the active shortcut array.
				shortcuts := slice.clone(commands.active_shortcuts(&other), context.temp_allocator)
				for shortcut in shortcuts {
					if !commands.prefix_conflicts(leader, shortcut) {continue}
					if leader_wins {_ = commands.unbind(registry, other.id, shortcut)}
					issue := Binding_Issue {
						kind     = .Leader_Prefix,
						severity = .Shortcut_Warning,
						line     = s.leader_line,
						key      = "input.leader",
						conflict = {
							shortcut    = shortcut,
							leader_text = s.input.leader,
							loser       = {other.name, other.title, applied_lines[int(other.id)]},
							winner      = winner_source,
						},
					}
					if _, err := append(&issues, issue); err != nil {
						report.issues = issues[:]
						return report, err
					}
				}
			}
		}
	}
	report.issues = issues[:]
	return
}

// The one English rendering of a binding issue, including the settings file's base name.
@(require_results)
binding_issue_text :: proc(issue: Binding_Issue, path: string) -> string {
	switch issue.kind {
	case .Unknown_Command:
		return fmt.tprintf("unknown command \"%s\"", issue.name)
	case .Invalid_Shortcut:
		return fmt.tprintf("cannot parse shortcut \"%s\"", issue.value)
	case .Unsupported_Leader_Shortcut:
		return "Leader shortcuts require a nonmodifier key."
	case .Apply_Failed:
		return fmt.tprintf(
			"cannot apply shortcuts for \"%s\": %v",
			issue.name,
			issue.apply_error,
		)
	case .Duplicate_Shortcut:
		conflict := issue.conflict
		buffer: [128]u8
		label, err := commands.shortcut_label(conflict.shortcut, buffer[:])
		assert(err == .None)
		return fmt.tprintf(
			"shortcut \"%s\" for %s (%s at %s) already used by %s (%s at %s)",
			label,
			conflict.loser.title,
			conflict.loser.name,
			binding_origin(path, conflict.loser.line),
			conflict.winner.title,
			conflict.winner.name,
			binding_origin(path, conflict.winner.line),
		)
	case .Leader_Prefix:
		conflict := issue.conflict
		return fmt.tprintf(
			"input.leader (%s) vs %s (%s); %s wins [%s:%d; %s]",
			conflict.leader_text,
			conflict.loser.title,
			conflict.loser.name,
			conflict.winner.name,
			binding_file_name(path),
			issue.line,
			binding_origin(path, conflict.loser.line),
		)
	}
	return ""
}

// A source line, or "defaults" when the effective shortcut is built in.
@(require_results)
binding_origin :: proc(path: string, line: int) -> string {
	if line > 0 {return fmt.tprintf("%s:%d", binding_file_name(path), line)}
	return "defaults"
}

@(private)
binding_key :: proc(name: string) -> string {
	return fmt.tprintf("%s%s", settings.KEY_BINDING_PREFIX, name)
}

@(private)
binding_file_name :: proc(path: string) -> string {
	i := max(strings.last_index_byte(path, '/'), strings.last_index_byte(path, '\\'))
	return path[i + 1:]
}
