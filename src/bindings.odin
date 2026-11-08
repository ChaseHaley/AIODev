package main

import "aio:commands"
import "aio:input"
import "aio:settings"
import "base:runtime"
import "core:fmt"
import "core:log"
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
				key      = settings.binding_key(binding.name),
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
				key      = settings.binding_key(binding.name),
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
			if .Leader in shortcut.modifiers && !leader_key_supported(shortcut.key) {
				unsupported = true
			}
		}
		if unsupported {
			issue := Binding_Issue {
				kind     = .Unsupported_Leader_Shortcut,
				severity = .Invalid_Value,
				line     = binding.line,
				key      = settings.binding_key(binding.name),
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
	// The registry holds this app's commands, whose ids are their Actions.
	applied_lines: [Action]int
	for error, i in errors[:count] {
		if error == .None {
			applied_lines[Action(overrides[i].id)] = s.keys[lines[i]].line
		}
	}
	for error, i in errors[:count] {
		if error == .None {continue}
		binding := s.keys[lines[i]]
		issue := Binding_Issue {
			kind        = .Apply_Failed,
			severity    = .Invalid_Value,
			line        = binding.line,
			key         = settings.binding_key(binding.name),
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
							line  = applied_lines[Action(other.id)],
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
		leader_line := settings.setting_line(s, settings.LEADER_KEY)
		leader, valid := commands.parse_shortcut(s.input.leader)
		if !valid || .Leader in leader.modifiers || !leader_key_supported(leader.key) {
			issue := Binding_Issue {
				kind     = .Unsupported_Leader_Shortcut,
				severity = .Invalid_Value,
				line     = leader_line,
				key      = settings.LEADER_KEY,
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
					   applied_lines[Action(other.id)] >= leader_line &&
					   (winner == nil ||
							   applied_lines[Action(other.id)] > applied_lines[Action(winner.id)]) {
						winner = &other
					}
				}
			}
			leader_wins := winner == nil
			winner_source: Binding_Source
			if leader_wins {
				winner_source = {settings.LEADER_KEY, "", leader_line}
				report.leader = leader
			} else {
				winner_source = {winner.name, winner.title, applied_lines[Action(winner.id)]}
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
						line     = leader_line,
						key      = settings.LEADER_KEY,
						conflict = {
							shortcut    = shortcut,
							leader_text = s.input.leader,
							loser       = {other.name, other.title, applied_lines[Action(other.id)]},
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
		buffer: [commands.SHORTCUT_TEXT_CAP]u8
		label := commands.shortcut_text(conflict.shortcut, buffer[:])
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
		return fmt.tprintf(
			"%s [%s:%d; %s]",
			binding_issue_identity(issue, path),
			binding_file_name(path),
			issue.line,
			binding_origin(path, issue.conflict.loser.line),
		)
	}
	return ""
}

// What a binding issue means without the source lines it names, so an edit that only moves lines
// leaves it the same problem. Only the leader conflict appends its locations.
@(require_results)
binding_issue_identity :: proc(issue: Binding_Issue, path: string) -> string {
	if issue.kind != .Leader_Prefix {return binding_issue_text(issue, path)}
	conflict := issue.conflict
	return fmt.tprintf(
		settings.LEADER_KEY + " (%s) vs %s (%s); %s wins",
		conflict.leader_text,
		conflict.loser.title,
		conflict.loser.name,
		conflict.winner.name,
	)
}

// A source line, or "defaults" when the effective shortcut is built in.
@(require_results)
binding_origin :: proc(path: string, line: int) -> string {
	if line > 0 {return fmt.tprintf("%s:%d", binding_file_name(path), line)}
	return "defaults"
}

@(private)
binding_file_name :: proc(path: string) -> string {
	i := max(strings.last_index_byte(path, '/'), strings.last_index_byte(path, '\\'))
	return path[i + 1:]
}

@(private)
binding_comment :: proc(descriptor: Command_Descriptor) -> string {
	if len(descriptor.shortcuts) == 0 {return fmt.tprintf("%s =", settings.binding_key(descriptor.name))}
	set := commands.Shortcut_Set{descriptor.shortcuts, len(descriptor.shortcuts)}
	value := commands.shortcut_set_text(set, context.temp_allocator)
	return fmt.tprintf("%s = %s", settings.binding_key(descriptor.name), value)
}

// The settings file's shortcut comments: a heading, then one line per command a key can run.
@(private)
binding_comments :: proc() -> (lines: [len(Action) + 1]string, count: int) {
	lines[0] =
		"Shortcuts: uncomment a line to change it. Separate several with commas; " +
		"leave the value empty to remove them."
	count = 1
	@(static, rodata)
	descriptors := ACTIONS
	for descriptor in descriptors {
		if descriptor.spec.hidden {continue}
		lines[count] = binding_comment(descriptor)
		count += 1
	}
	return
}

@(private)
apply_bindings :: proc(app: ^App, diagnostics: ^[dynamic]settings.Diagnostic) {
	report, report_error := binding_report(&app.registry, &app.settings)
	for issue in report.issues {
		message := binding_issue_text(issue, app.settings_path)
		identity := binding_issue_identity(issue, app.settings_path)
		if err := settings.diagnostic_append(
			diagnostics, issue.line, issue.key, message, issue.severity, identity,
		); err != nil {
			log.errorf("recording shortcut diagnostic failed: %v", err)
			notify(app, .Error, message)
		}
	}
	if report_error != nil {
		notify(app, .Error, "Could not allocate shortcut bindings.")
		return
	}
	app.leader = report.leader
}

// A leader, and a key following one, must be an identified key that is not itself a modifier.
@(private)
leader_key_supported :: proc(key: input.Key) -> bool {
	return key != .Unidentified && !input.is_modifier_key(key)
}
