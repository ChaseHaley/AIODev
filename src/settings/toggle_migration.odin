package settings

import "base:runtime"
import "core:strings"

// A retired on/off key and the bit of its family's value that it set.
@(private = "file")
Retired_Toggle :: struct {
	key: string,
	bit: u32,
}

// Toggles that became one setting (WORK-418). `defaults` holds the bits of the toggles' old
// defaults, so a toggle the file never set keeps its old value; `text` writes the setting's value.
@(private = "file")
Toggle_Family :: struct {
	key:      string,
	toggles:  []Retired_Toggle,
	defaults: u32,
	text:     proc(bits: u32) -> string,
}

// status.taskbar was the on/off master of the per-state toggles; it is the bit after them.
@(private = "file")
TASKBAR_MASTER :: u32(len(Status_Taskbar_State))
@(private = "file")
FIND_KEEP :: 0
@(private = "file")
FIND_SELECT :: 1

@(private = "file")
toggle_families := [?]Toggle_Family {
	{
		key = "status.surfaces",
		toggles = {
			{"status.tab_indicators", u32(Status_Surface.Tabs)},
			{"status.active_tab_indicator", u32(Status_Surface.Active_Tab)},
			{"status.pane_headers", u32(Status_Surface.Pane_Headers)},
			{"status.workspace_picker", u32(Status_Surface.Workspace_Picker)},
		},
		defaults = transmute(u32)Status_Surfaces{.Tabs, .Active_Tab, .Pane_Headers, .Workspace_Picker},
		text = proc(bits: u32) -> string {return set_text(STATUS_SURFACE_NAMES, bits)},
	},
	{
		key = "status.show",
		toggles = {
			{"status.show_working", u32(Status_Show_State.Working)},
			{"status.show_blocked", u32(Status_Show_State.Blocked)},
			{"status.show_done", u32(Status_Show_State.Done)},
			{"status.show_error", u32(Status_Show_State.Error)},
			{"status.show_idle", u32(Status_Show_State.Idle)},
		},
		defaults = transmute(u32)Status_Show_States{.Working, .Blocked, .Done, .Error, .Idle},
		text = proc(bits: u32) -> string {return set_text(STATUS_SHOW_STATE_NAMES, bits)},
	},
	{
		key = "status.taskbar",
		toggles = {
			{"status.taskbar", TASKBAR_MASTER},
			{"status.taskbar_working", u32(Status_Taskbar_State.Working)},
			{"status.taskbar_blocked", u32(Status_Taskbar_State.Blocked)},
			{"status.taskbar_error", u32(Status_Taskbar_State.Error)},
		},
		defaults = transmute(u32)Status_Taskbar_States{.Working, .Blocked, .Error} | 1 << TASKBAR_MASTER,
		text = proc(bits: u32) -> string {
			on := bits & (1 << TASKBAR_MASTER) != 0
			return set_text(STATUS_TASKBAR_STATE_NAMES, on ? bits &~ (1 << TASKBAR_MASTER) : 0)
		},
	},
	{
		key = "interface.confirm",
		toggles = {
			{"tab.confirm_close", u32(Confirm_Prompt.Close_Split_Tab)},
			{"pane.confirm_shell_switch", u32(Confirm_Prompt.Shell_Switch)},
			{"terminal.confirm_multiline_paste", u32(Confirm_Prompt.Multiline_Paste)},
		},
		defaults = transmute(u32)Confirm_Prompts{.Close_Split_Tab, .Shell_Switch, .Multiline_Paste},
		text = proc(bits: u32) -> string {return set_text(CONFIRM_PROMPT_NAMES, bits)},
	},
	{
		key = "terminal.find_reopen",
		toggles = {{"terminal.find_keep_query", FIND_KEEP}, {"terminal.find_select_query", FIND_SELECT}},
		defaults = 0,
		// Selecting the last search also filled it in, with or without keep.
		text = proc(bits: u32) -> string {
			names := FIND_REOPEN_NAME
			if bits & (1 << FIND_SELECT) != 0 {return names[.Last_Selected]}
			return names[bits & (1 << FIND_KEEP) != 0 ? Find_Reopen.Last : Find_Reopen.Empty]
		},
	},
}

// The family and toggle a line sets, or -1 for a line no family retired. status.taskbar kept its
// key, so only its old true or false value is the retired master.
@(private = "file")
retired_toggle :: proc(key, value: string) -> (family: int, toggle: int) {
	for f, i in toggle_families {
		for r, j in f.toggles {
			if r.key != key {continue}
			if key == f.key && value != "true" && value != "false" {return -1, -1}
			return i, j
		}
	}
	return -1, -1
}

// Rewrites retired on/off toggles into the setting each family became, keeping their effect: a
// toggle the file leaves out takes its old default, and an invalid value, which the old parser
// replaced with the default, does too. A file that already sets the new key keeps it and loses
// the family's old lines. The new line takes the place of the family's first old line.
@(require_results)
migrate_toggle_sets_text :: proc(
	text: string,
	allocator := context.allocator,
) -> (
	updated: string,
	migrated: bool,
	err: runtime.Allocator_Error,
) {
	FAMILIES :: len(toggle_families)
	bits: [FAMILIES]u32
	for f, i in toggle_families {bits[i] = f.defaults}
	legacy, current: [FAMILIES]bool
	scanner := line_scanner_init(text)
	for {
		line, ok := line_next(&scanner)
		if !ok {break}
		if !line.split {continue}
		f, r := retired_toggle(line.key, line.value)
		if f < 0 {
			for family, i in toggle_families {
				if line.key == family.key {current[i] = true}
			}
			continue
		}
		legacy[f] = true
		bit := u32(1) << toggle_families[f].toggles[r].bit
		on := toggle_families[f].defaults & bit != 0
		switch line.value {
		case "true":
			on = true
		case "false":
			on = false
		}
		if on {bits[f] |= bit} else {bits[f] &~= bit}
	}
	any_legacy := false
	for l in legacy {any_legacy = any_legacy || l}
	if !any_legacy {return "", false, nil}

	builder := strings.builder_make(allocator) or_return
	defer strings.builder_destroy(&builder)
	rescanner := line_scanner_init(text)
	if rescanner.bom {write_parts(&builder, UTF8_BOM) or_return}
	written := current
	// A comment directly above a removed key described that key, so it goes with it.
	held: string
	for {
		line, ok := line_next(&rescanner)
		if !ok {break}
		f := -1
		if line.split {f, _ = retired_toggle(line.key, line.value)}
		if f < 0 {
			if held != "" {write_parts(&builder, held) or_return}
			held = ""
			if strings.has_prefix(line.text, "#") {held = line.raw} else {write_parts(&builder, line.raw) or_return}
			continue
		}
		if written[f] {
			held = ""
			continue
		}
		written[f] = true
		family := toggle_families[f]
		if held != "" {
			write_parts(&builder, "# ", schema_find(family.key).description, line.eol) or_return
		}
		held = ""
		write_parts(&builder, family.key, " = ", family.text(bits[f]), line.eol) or_return
	}
	if held != "" {write_parts(&builder, held) or_return}
	updated = strings.clone(strings.to_string(builder), allocator) or_return
	return updated, true, nil
}
