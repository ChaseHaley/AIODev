package ui

// The menu contains exactly the controls omitted by the current row geometry.
editor_profile_menu_open :: proc(p: ^Editor, row: ^Editor_Row, parts: Profile_Parts) {
	menu_clear(&p.profile_menu)
	controls := [?]struct {control: Profile_Control, label: string, hidden, checked: bool} {
		{.Radio, "Use as default", parts.radio.width <= 0, .Default in row.flags},
		{.Hidden, "Show in menus", parts.toggle.width <= 0, .Hidden not_in row.flags},
		{.Duplicate, "Duplicate profile", parts.duplicate.width <= 0, false},
		{.Remove, "Delete profile", parts.remove.width <= 0 &&
		 row.profile != "default" && .Protected not_in row.flags, false},
	}
	for item in controls {
		if !item.hidden {continue}
		index := len(p.profile_menu.items)
		if menu_add(&p.profile_menu, {label = item.label, enabled = true, checked = item.checked}) != nil {
			return
		}
		p.profile_menu_controls[index] = item.control
	}
	menu_anchor(&p.profile_menu, parts.more.x, parts.more.y + parts.more.height)
	next: Editor_Mode = Editor_Editing{}
	if len(p.profile_menu.items) > 0 {next = Editor_Profile_Menu{}}
	editor_mode_set(p, next)
	p.profile_control = .More
}

editor_profile_menu_choose :: proc(p: ^Editor) -> Editor_Outcome {
	index := p.profile_menu.selected
	editor_mode_set(p, Editor_Editing{})
	if index < 0 || index >= len(p.profile_menu.items) {return .Changed}
	row := editor_row(p)
	if row == nil || row.kind != .Profile {return .Changed}
	p.profile_control = p.profile_menu_controls[index]
	return profile_activate(p, row)
}
