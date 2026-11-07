package ui

// The profile table's state on the settings page: the one expanded profile, the control the focus
// ring is on, the pointer's hover, the overflow menu, and an inline field problem. Strings are owned.
Profile_Editor_State :: struct {
	profile_menu:                         Menu,
	profile_menu_controls:                [4]Profile_Control,
	profile_menu_parts:                   Profile_Parts,
	expanded:                             string,
	profile_control:                      Profile_Control,
	hover_profile_item:                   int,
	hover_profile_control:                Profile_Control,
	error_key, error_profile, error_text: string,
}

@(private)
profile_editor_destroy :: proc(state: ^Profile_Editor_State) {
	menu_destroy(&state.profile_menu)
	for text in ([?]string{state.expanded, state.error_key, state.error_profile, state.error_text}) {
		delete(text)
	}
}

// The menu contains exactly the controls omitted by the current row geometry.
editor_profile_menu_open :: proc(p: ^Editor, row: ^Editor_Row, parts: Profile_Parts) {
	menu_clear(&p.profile_menu)
	controls := [?]struct {control: Profile_Control, label: string, hidden, checked: bool} {
		{.Radio, "Use as default", parts.radio.width <= 0, .Default in row.flags},
		{.Hidden, "Show in menus", parts.toggle.width <= 0, .Hidden not_in row.flags},
		{.Duplicate, "Duplicate profile", parts.duplicate.width <= 0, false},
		{.Remove, "Delete profile", parts.remove.width <= 0 && .Protected not_in row.flags, false},
	}
	for item in controls {
		if !item.hidden {continue}
		added, err := menu_add(
			&p.profile_menu,
			{label = item.label, enabled = true, checked = item.checked, payload = u32(item.control)},
		)
		if err != nil || !added {return}
	}
	menu_anchor(&p.profile_menu, parts.more.x, parts.more.y + parts.more.height)
	next: Editor_Mode = Editor_Editing{}
	if len(p.profile_menu.items) > 0 {next = Editor_Profile_Menu{}}
	editor_mode_set(p, next)
	p.profile_control = .More
}

editor_profile_menu_choose :: proc(p: ^Editor) -> Editor_Outcome {
	index := menu_selected(&p.profile_menu)
	editor_mode_set(p, Editor_Editing{})
	if index < 0 || index >= len(p.profile_menu.items) {return .Changed}
	row := editor_row(p)
	if row == nil || row.kind != .Profile {return .Changed}
	p.profile_control = Profile_Control(p.profile_menu.items[index].payload)
	return profile_activate(p, row)
}
