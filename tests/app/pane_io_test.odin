package app_test

import app "../../src"
import "aio:cli_protocol"
import "aio:commands"
import "aio:platform"
import "aio:settings"
import "aio:term"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(private = "file")
Pane_IO_Fixture :: struct {
	state:           app.App,
	directory, path: string,
}

@(private = "file")
pane_io_create :: proc(t: ^testing.T, f: ^Pane_IO_Fixture, name: string) -> bool {
	directory, err := os.make_directory_temp("", "aio-paneio-*", context.allocator)
	if !testing.expect_value(t, err, nil) {return false}
	f.directory = directory
	f.path = strings.concatenate({directory, "/settings.ini"})
	text :: "shell.command = pwsh.exe -NoLogo -NoProfile\nfont.size = 12\ncursor.blink = false\n"
	if !testing.expect_value(t, os.write_entire_file(f.path, text), nil) {return false}
	f.state.options = {data_dir = directory, inactive = true}
	f.state.app_id = fmt.aprintf("AIODev.Test.PaneIO.%s.%d", name, os.get_pid())
	if !testing.expect_value(t, platform.init(&f.state.platform, f.state.app_id), platform.Init_Result.Primary) {
		return false
	}
	f.state.platform_ready = true
	return testing.expect(t, app.app_init(&f.state))
}

@(private = "file")
pane_io_destroy :: proc(t: ^testing.T, f: ^Pane_IO_Fixture) {
	app.app_destroy(&f.state)
	if f.path != "" {
		testing.expect_value(t, os.remove(f.path), nil)
		delete(f.path)
	}
	if f.directory != "" {
		testing.expect_value(t, os.remove(f.directory), nil)
		delete(f.directory)
	}
}

@(private = "file")
pane_io_invoke :: proc(state: ^app.App, caller: u32, args: ..string) -> app.Outcome {
	invocation, err := commands.parse_invocation(&state.registry, args, context.temp_allocator)
	if err.advice != "" {return {status = .Usage, message = err.advice}}
	return app.command_execute(state, app.Control_Request{caller = caller}, invocation)
}

@(private = "file")
pane_io_reply :: proc(t: ^testing.T, state: ^app.App, args: ..string) -> cli_protocol.Reply_Json {
	words := make([dynamic]string, context.temp_allocator)
	append(&words, "", "json", "")
	append(&words, ..args)
	response := app.control_cli_answer(state, words[:])
	reply: cli_protocol.Reply_Json
	testing.expect_value(t, json.unmarshal_string(response.text, &reply, allocator = context.temp_allocator), nil)
	return reply
}

@(private = "file")
pane_io_wait_text :: proc(state: ^app.App, pane: u32, text: string) -> bool {
	for deadline := time.tick_now(); time.tick_since(deadline) < 15 * time.Second; {
		app.tick(state)
		read := pane_io_invoke(state, pane, "pane.read", "--scrollback")
		if read.status == .Ok && strings.contains(string(read.payload.(app.Outcome_Text)), text) {return true}
		time.sleep(25 * time.Millisecond)
	}
	return false
}

@(private = "file")
pane_io_wait_process :: proc(state: ^app.App, pane: u32, name: string) -> (cli_protocol.Process_Report, bool) {
	for deadline := time.tick_now(); time.tick_since(deadline) < 15 * time.Second; {
		app.tick(state)
		outcome := pane_io_invoke(state, pane, "pane.process")
		if outcome.status == .Ok {
			report := cli_protocol.Process_Report(outcome.payload.(app.Outcome_Process))
			if strings.equal_fold(report.name, name) {return report, true}
		}
		time.sleep(25 * time.Millisecond)
	}
	return {}, false
}

// These tests start real shells and intentionally remain outside the process-free fast lane.
@(test)
pane_io_keys_interrupt_and_edit_the_shell_using_its_keyboard_protocol :: proc(t: ^testing.T) {
	f: Pane_IO_Fixture
	defer pane_io_destroy(t, &f)
	if !pane_io_create(t, &f, "keys") {return}
	state := &f.state
	pane := state.sessions[0].id
	pane_word := fmt.aprintf("%d", pane)
	defer delete(pane_word)
	// Wait for a command's output, not its echoed source, before editing an interactive line.
	ready := pane_io_invoke(state, pane, "pane.send", "--enter", "Write-Output ('aio-ready-' + 'paneio')")
	if !testing.expect_value(t, ready.status, cli_protocol.Status.Ok) {return}
	if !testing.expect(t, pane_io_wait_text(state, pane, "aio-ready-paneio")) {return}
	process := pane_io_reply(t, state, "pane.process", "--pane", pane_word)
	if !testing.expect(t, process.ok) {return}
	shell, has_shell := process.process.?
	if !testing.expect(t, has_shell) {return}
	testing.expect(t, strings.equal_fold(shell.name, "pwsh.exe"))
	testing.expect_value(t, shell.pid, term.process_id(state.sessions[0].session))
	testing.expect(t, strings.has_suffix(strings.to_lower(shell.path, context.temp_allocator), "pwsh.exe"))
	testing.expect(t, shell.directory != "")
	testing.expect_value(t, len(shell.ancestors), 0)

	testing.expect_value(t, pane_io_invoke(state, pane, "pane.send", "--enter", "ping.exe -t 127.0.0.1").status,
		cli_protocol.Status.Ok)
	ping, running := pane_io_wait_process(state, pane, "ping.exe")
	if !testing.expect(t, running, "ping started under pwsh") {return}
	if testing.expect(t, len(ping.ancestors) > 0) {
		testing.expect_value(t, ping.ancestors[0].pid, shell.pid)
		testing.expect(t, strings.equal_fold(ping.ancestors[0].name, "pwsh.exe"))
	}
	invalid := pane_io_invoke(state, pane, "pane.send_keys", "--keys", "Ctrl+C NotAChord")
	testing.expect_value(t, invalid.status, cli_protocol.Status.Usage)
	testing.expect(t, strings.contains(invalid.message, "NotAChord"))
	malformed := pane_io_invoke(state, pane, "pane.send_keys", "--keys", `["Ctrl+C",3]`)
	testing.expect_value(t, malformed.status, cli_protocol.Status.Usage)
	// If an invalid suffix sent its valid prefix, Ctrl+C would stop ping during this interval.
	for deadline := time.tick_now(); time.tick_since(deadline) < 250 * time.Millisecond; {
		app.tick(state)
		time.sleep(25 * time.Millisecond)
	}
	still_running := pane_io_invoke(state, pane, "pane.process")
	if testing.expect_value(t, still_running.status, cli_protocol.Status.Ok) {
		testing.expect(t, strings.equal_fold(cli_protocol.Process_Report(still_running.payload.(app.Outcome_Process)).name,
			"ping.exe"), "an invalid chord list sends none of its keys")
	}
	testing.expect_value(t, pane_io_invoke(state, pane, "pane.send_keys", "--pane", pane_word, "--keys", "Ctrl+C").status,
		cli_protocol.Status.Ok)
	_, interrupted := pane_io_wait_process(state, pane, "pwsh.exe")
	if !testing.expect(t, interrupted, "Ctrl+C interrupted the infinite ping") {return}

	// Move inside the final string literal, insert Y, then execute with a synthetic Enter.
	testing.expect_value(t, pane_io_invoke(state, pane, "pane.send", "Write-Output ('aio-arrow-' + 'X')").status,
		cli_protocol.Status.Ok)
	testing.expect_value(t, pane_io_invoke(state, pane, "pane.send_keys", "--keys", `["Left","Left","Left"]`).status,
		cli_protocol.Status.Ok)
	testing.expect_value(t, pane_io_invoke(state, pane, "pane.send", "Y").status, cli_protocol.Status.Ok)
	testing.expect_value(t, pane_io_invoke(state, pane, "pane.send_keys", "--keys", "End Enter").status,
		cli_protocol.Status.Ok)
	testing.expect(t, pane_io_wait_text(state, pane, "aio-arrow-YX"), "arrows and Enter reached the shell")
}

@(test)
pane_io_notice_clipboard_and_settings_share_the_apps_paths :: proc(t: ^testing.T) {
	f: Pane_IO_Fixture
	defer pane_io_destroy(t, &f)
	if !pane_io_create(t, &f, "services") {return}
	state := &f.state
	shown := pane_io_reply(t, state, "app.notify", "--title", "Build", "Finished")
	testing.expect(t, shown.ok)
	found := false
	for notice in state.notices.items {
		if notice.kind == .Info && notice.text == "Build: Finished" {found = true}
	}
	testing.expect(t, found, "app.notify publishes the ordinary Info notice")

	when platform.AIO_HEADLESS {
		state.settings.status.enabled = true
		state.settings.status.notify_done = {.Banner}
		window := state.windows[0]
		width, height := window.width, window.height
		window.width, window.height = 0, 0
		before := len(state.platform.record.notifications)
		hidden := pane_io_reply(t, state, "app.notify", "--title", "Hidden build", "Finished too")
		window.width, window.height = width, height
		testing.expect(t, hidden.ok)
		if testing.expect_value(t, len(state.platform.record.notifications), before + 1) {
			notice := state.platform.record.notifications[before]
			testing.expect_value(t, notice.title, "Hidden build")
			testing.expect_value(t, notice.text, "Finished too")
		}
	}

	text :: "paneio clipboard λ"
	written := pane_io_reply(t, state, "edit.clipboard_write", text)
	testing.expect(t, written.ok)
	read := pane_io_reply(t, state, "edit.clipboard_read")
	testing.expect(t, read.ok)
	testing.expect_value(t, read.text, text)
	testing.expect(t, pane_io_reply(t, state, "edit.clipboard_write", "").ok)
	testing.expect_value(t, pane_io_reply(t, state, "edit.clipboard_read").text, "")

	applied := pane_io_reply(t, state, "settings.set", "--name", "font.size", "19")
	if !testing.expect(t, applied.ok, applied.error) {return}
	testing.expect_value(t, state.settings.font.size, 19.0)
	saved, read_error := os.read_entire_file(f.path, context.temp_allocator)
	if !testing.expect_value(t, read_error, nil) {return}
	loaded, diagnostics, parse_error := settings.parse(string(saved))
	defer settings.destroy(&loaded)
	defer settings.diagnostics_destroy(&diagnostics)
	if testing.expect_value(t, parse_error, nil) {testing.expect_value(t, loaded.font.size, 19.0)}
	current := pane_io_reply(t, state, "settings.get", "--name", "font.size")
	testing.expect(t, current.ok)
	testing.expect_value(t, current.text, "19")

	_, expected_message, edit_error := settings.edit_text(string(saved), "font.size", "not-a-number", context.temp_allocator)
	if !testing.expect_value(t, edit_error, nil) {return}
	refused := pane_io_reply(t, state, "settings.set", "--name", "font.size", "not-a-number")
	testing.expect(t, !refused.ok)
	testing.expect_value(t, refused.status, u8(cli_protocol.Status.Failed))
	testing.expect_value(t, refused.error, expected_message)
	testing.expect_value(t, state.settings.font.size, 19.0)
	after, after_error := os.read_entire_file(f.path, context.temp_allocator)
	if testing.expect_value(t, after_error, nil) {testing.expect_value(t, string(after), string(saved))}
	testing.expect_value(t, pane_io_reply(t, state, "settings.get", "--name", "font.size").text, "19")
	unknown := pane_io_reply(t, state, "settings.get", "--name", "not.a.setting")
	testing.expect(t, !unknown.ok)
	testing.expect_value(t, unknown.status, u8(cli_protocol.Status.Usage))
	unknown_write := pane_io_reply(t, state, "settings.set", "--name", "not.a.setting", "value")
	testing.expect_value(t, unknown_write.status, u8(cli_protocol.Status.Usage))

	// Strings use the same quoting as settings.ini; callers pass unquoted edits like the Settings page.
	testing.expect(t, pane_io_reply(t, state, "settings.set", "--name", "font.family", "Cascadia Mono").ok)
	testing.expect_value(t, pane_io_reply(t, state, "settings.get", "--name", "font.family").text, `"Cascadia Mono"`)
}
