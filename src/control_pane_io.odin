package main

import "aio:cli_protocol"
import "aio:commands"
import "cosmos:input"
import "aio:localpath"
import "cosmos:platform"
import "aio:procinfo"
import "aio:settings"
import "aio:term"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:strings"

// Prepare the entire list before sending anything, including native key data for win32-input mode.
// The terminal's send_key chooses its own negotiated VT, kitty or win32-input encoding.
@(private)
control_pane_send_keys :: proc(entry: ^Session_Entry, text: string) -> Outcome {
	if entry == nil {return outcome_failure(.Failed, "that pane does not show a terminal")}
	if entry.status != .Running {return outcome_failure(.Failed, "the pane's program is not running")}
	words: []string
	trimmed := strings.trim_space(text)
	if strings.has_prefix(trimmed, "[") {
		if json.unmarshal_string(trimmed, &words, allocator = context.temp_allocator) != nil {
			return outcome_failure(.Usage, "--keys needs a JSON array of chord strings")
		}
	} else {
		words = strings.fields(trimmed, context.temp_allocator)
	}
	if len(words) == 0 {return outcome_failure(.Usage, "--keys needs at least one chord")}
	Synthetic_Key :: struct {
		press, release: input.Key_Event,
		text:           [32]u8,
	}
	keys := make([]Synthetic_Key, len(words), context.temp_allocator)
	for word, i in words {
		chord, valid := commands.parse_shortcut(word)
		if !valid {return outcome_failure(.Usage, fmt.tprintf("unknown chord %q", word))}
		press, press_error := platform.synthesize_key(0, chord.key, chord.modifiers, true, keys[i].text[:])
		release, release_error := platform.synthesize_key(0, chord.key, chord.modifiers, false, nil)
		if press_error != .None || release_error != .None {
			return outcome_failure(.Usage, fmt.tprintf("cannot synthesize chord %q", word))
		}
		keys[i].press, keys[i].release = press, release
	}
	for &key in keys {
		if !term.send_key(entry.session, key.press) {
			return outcome_failure(.Failed, "the pane is not accepting input")
		}
		// Legacy VT sends no release bytes. Kitty and win32-input may need the release.
		_ = term.send_key(entry.session, key.release)
	}
	return {}
}

@(private)
control_pane_process :: proc(app: ^App, entry: ^Session_Entry) -> Outcome {
	if entry == nil {return outcome_failure(.Failed, "that pane does not show a terminal")}
	if entry.status != .Running {return outcome_failure(.Failed, "the pane's program is not running")}
	processes := session_processes(app)
	index := pane_process(app, entry, processes)
	if index < 0 {return outcome_failure(.Failed, "could not read the pane's process")}
	process := processes[index]
	root := term.process_id(entry.session)
	report := cli_protocol.Process_Report{name = process.executable, pid = process.id}
	report.path, _ = procinfo.process_image(process.id, root, context.temp_allocator)
	report.directory, _ = procinfo.process_directory(process.id, root, context.temp_allocator)
	// Shells report Set-Location through OSC 7 rather than changing the Windows process directory.
	if process.id == root {
		raw := term.working_directory(entry.session, context.temp_allocator)
		if directory, err := localpath.directory_label(raw, context.temp_allocator); err == nil && directory != "" {
			report.directory = directory
		}
	}
	ancestors := make([dynamic]cli_protocol.Process_Ancestor, context.temp_allocator)
	parent := process.parent
	for _ in 0 ..< len(processes) {
		if process.id == root || parent == 0 || parent == process.id {break}
		duplicate := false
		for ancestor in ancestors {if ancestor.pid == parent {duplicate = true; break}}
		if duplicate {break}
		found := false
		for candidate in processes {
			if candidate.id != parent {continue}
			append(&ancestors, cli_protocol.Process_Ancestor{candidate.executable, candidate.id})
			parent = candidate.parent
			found = true
			if candidate.id == root {parent = 0}
			break
		}
		if !found {break}
	}
	report.ancestors = ancestors[:]
	return {payload = Outcome_Process(report)}
}

@(private)
control_app_notify :: proc(app: ^App, title, text: string) {
	headline := title == "" ? "AIODev" : title
	notify(app, .Info, fmt.tprintf("%s: %s", headline, text))
	for window in app.windows {if window_drawable(window) {return}}
	// A script announcing completion follows the user's existing done-program preferences.
	channels := status_notification_channels(&app.settings.status, .Done)
	sound := .Sound in channels
	if .Banner in channels {
		result := platform.notification_show(&app.platform, NOTIFICATION_IDENTITY, headline, text, 0, sound)
		if result == .None {
			sound = false
		} else if result != .Unavailable {
			log.error("Windows could not show a script notification. Check notification settings.")
		}
	}
	if .Tray in channels {
		if platform.tray_notify(&app.platform, headline, text, 0, sound) == .None {
			sound = false
		} else {
			log.error("Windows could not show a script tray notification.")
		}
	}
	if sound && platform.notification_sound() != .None {
		log.error("playing script notification sound failed")
	}
}

@(private)
control_settings_value :: proc(app: ^App, invocation: commands.Invocation, write: bool) -> Outcome {
	entry := settings.schema_find(invocation.name)
	if entry == nil {
		return outcome_failure(.Usage, fmt.tprintf("unknown setting %q", invocation.name))
	}
	if !write {
		builder := strings.builder_make(context.temp_allocator)
		if settings.encode_value(&builder, entry^, settings.value_text(&app.settings, entry^)) != nil {
			return outcome_failure(.Failed, "not enough memory for the setting value")
		}
		return {payload = Outcome_Text(strings.to_string(builder))}
	}
	result := settings_change(app, Setting_Value{invocation.name, invocation.text}, Settings_Current{})
	switch result.status {
	case .Applied, .Unchanged:
		return {}
	case .Refused, .Unprepared, .Conflict, .Failed:
		return outcome_failure(.Failed, settings_result_text(result, .Setting))
	}
	return {}
}
