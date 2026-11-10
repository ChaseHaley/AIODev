package main

import "aio:input"

// The surfaces that can own the pointer, listed topmost first. The order is the precedence: hover,
// cursor and press all resolve through `pointer_target`, so the surface that shows a hover is the one
// a press reaches, and the surfaces beneath it see the pointer leave. Each surface's handlers live with
// its feature; this file composes them and holds the policy that decides between surfaces.
Pointer_Target :: enum u8 {
	Notice,
	Workspace_Picker,
	Tab_Menu,
	Divider_Menu,
	Profile_Menu,
	Document_Menu,
	Status_Inbox,
	Rename,
	// Window caption buttons, which stay usable over every overlay.
	Caption,
	// An open confirmation takes the rest of the window.
	Confirmation,
	// The command palette takes the rest of the window while it is open.
	Palette,
	Tab_Orientation,
	Title_Action,
	// The hidden panes glyph in the header of a pane a view shows alone, and its map while open, which
	// hangs over the panes, the find bar and floats.
	Hidden_Panes,
	// The find bar floats over panes, headers and the Activity panel.
	Find,
	Workspace_Button,
	Status_Pill,
	Divider,
	Status_Panel,
	// The tab strip band or the rail, including an overlay rail above the panes.
	Tabs,
	// A floating pane's resize edges and the capsules of minimized floating panes. A floating pane also
	// hides the dividers below it.
	Floating,
	// Pane headers and a single pane's floating split controls.
	Pane_Header,
	Scrollbar,
	// A settings page shown in a pane.
	Settings_Page,
	// A Markdown document shown in a pane.
	Markdown_Page,
	// Terminal content, including its links, and anything uncovered.
	Content,
}

// What a drag a surface holds did with a move.
Pointer_Held :: enum u8 {
	// No drag of this surface is held, or it leaves this move to the surfaces.
	Free,
	// The drag followed the move, which ends there.
	Taken,
	// The move ended a drag whose release was missed. What lies under the pointer may have changed with
	// it, so routing resolves the target again.
	Ended,
}

// Everything a surface tells the pointer system: its handlers and its policy. A new surface adds a
// target above and one entry in pointer_surfaces.
Pointer_Surface :: struct {
	// Whether the point lies on the surface while it is showing.
	claims:       proc(app: ^App, w: ^Window, x, y: f32) -> bool,
	// Runs for every surface on every move. The owner updates its hover and sets the cursor; every
	// other surface clears its own hover, cheaply when there is none.
	hover:        proc(app: ^App, w: ^Window, owner: Pointer_Target, e: input.Mouse_Move_Event),
	// A press the surface owns. A modal surface also receives every release while it is open.
	press:        proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event),
	// The release of a press the surface owned, wherever it lands; false passes it on to the shared
	// completion for confirmations, the palette and pane content. A release of a press the surface
	// swallowed ends there either way.
	release:      proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) -> bool,
	// The hovered control supplies a short label; the shared tooltip owns timing and drawing.
	tooltip:      proc(app: ^App, w: ^Window, x, y: f32) -> string,
	// Optional: what the labelled control would do, drawn under the label while the tooltip shows.
	tooltip_card: proc(app: ^App, w: ^Window, x, y: f32) -> Tooltip_Card,
	// Capture loss: the surface drops its hover, armed control and drag, whether or not it holds a button.
	cancel:       proc(app: ^App, w: ^Window),
	// The pointer left the window: the surface drops its hover, as a move another surface owns does.
	leave:        proc(app: ^App, w: ^Window),
	// A drag the surface holds follows every move before hover runs; `under` is the surface under the
	// pointer. Only one drag is held at a time, since each starts with a Left press.
	held:         proc(app: ^App, w: ^Window, under: Pointer_Target, e: input.Mouse_Move_Event) -> Pointer_Held,
	// Takes the whole window while it shows: every press, every release that began elsewhere, and the
	// moves of held presses and of drags that have not started.
	modal:        bool,
	// A press here keeps the pointer with this surface until its release, whatever buttons a move
	// reports. The palette and a confirmation take the whole window while open, so a press on one that
	// has since closed keeps nothing.
	holds:        bool,
	// A press here hands the keyboard back from the find bar to the pane; the bar and its matches stay.
	blurs_find:   bool,
	// Lies in a pane, so a single pane's split controls show while the pointer is over it.
	in_pane:      bool,
	// A floating pane over the point hides the surface.
	under_floats: bool,
}

@(rodata)
pointer_surfaces := [Pointer_Target]Pointer_Surface {
	.Notice           = {
		claims = notice_claims, hover = notice_hover, press = notice_press, release = notice_release,
		tooltip = notice_tooltip, cancel = notice_cancel, leave = notice_leave, holds = true,
	},
	.Workspace_Picker = {
		claims = workspace_picker_claims, hover = workspace_picker_pointer_hover,
		press = workspace_picker_button, tooltip = workspace_picker_tooltip,
		cancel = workspace_picker_pointer_cancel, leave = workspace_picker_leave, modal = true,
	},
	.Tab_Menu         = {
		claims = tab_menu_claims, hover = tab_menu_hover, press = tab_menu_button, modal = true,
	},
	.Divider_Menu     = {
		claims = divider_menu_claims, hover = divider_menu_hover, press = divider_menu_button, modal = true,
	},
	.Profile_Menu     = {
		claims = profile_menu_claims, hover = profile_menu_hover, press = profile_menu_button, modal = true,
	},
	.Document_Menu    = {
		claims = document_menu_claims, hover = document_menu_pointer_hover, press = document_menu_button,
		tooltip = document_menu_tooltip, cancel = document_menu_pointer_cancel, leave = document_menu_leave,
		modal = true,
	},
	.Status_Inbox     = {
		claims = status_inbox_claims, hover = status_inbox_hover, press = status_inbox_button, modal = true,
	},
	.Rename           = {
		claims = rename_claims, hover = rename_hover, press = rename_button, cancel = rename_pointer_cancel,
		modal = true,
	},
	// No leave: Windows reports a leave as the pointer moves onto the maximize button, whose hover the
	// native caption moves keep; a caption move outside the client area clears it instead.
	.Caption          = {
		claims = caption_claims, hover = caption_hover, press = caption_press, release = caption_release,
		tooltip = caption_tooltip, cancel = caption_cancel, holds = true,
	},
	.Confirmation     = {
		claims = confirmation_claims, hover = confirmation_pointer_hover, press = confirmation_press,
		cancel = confirmation_pointer_cancel,
	},
	.Palette          = {
		claims = palette_claims, hover = palette_hover, press = palette_press, tooltip = palette_tooltip,
		cancel = palette_pointer_cancel,
	},
	.Tab_Orientation  = {
		claims = orientation_claims, hover = orientation_hover, press = orientation_press,
		release = orientation_release, tooltip = orientation_tooltip, cancel = orientation_cancel,
		leave = orientation_leave, holds = true,
	},
	.Title_Action     = {
		claims = title_action_claims, hover = title_action_pointer_hover, press = title_action_press,
		release = title_action_release, tooltip = title_action_tooltip, cancel = title_action_cancel,
		leave = title_action_leave, holds = true,
	},
	.Hidden_Panes     = {
		claims = hidden_panes_claims, hover = hidden_panes_hover, press = hidden_panes_press,
		cancel = hidden_panes_leave, leave = hidden_panes_leave, holds = true, blurs_find = true,
	},
	.Find             = {
		claims = find_claims, hover = find_pointer_hover, press = find_press, release = find_release,
		tooltip = find_tooltip, cancel = find_pointer_cancel, leave = find_leave, holds = true,
	},
	.Workspace_Button = {
		claims = workspace_button_claims, hover = workspace_button_hover, press = workspace_button_press,
		tooltip = workspace_button_tooltip, leave = workspace_button_leave, holds = true, blurs_find = true,
	},
	.Status_Pill      = {
		claims = status_pill_claims, hover = status_pill_hover, press = status_pill_press,
		tooltip = status_pill_tooltip, leave = status_pill_leave, holds = true, blurs_find = true,
		under_floats = true,
	},
	.Divider          = {
		claims = divider_claims, hover = divider_hover, press = divider_pointer_press, release = divider_release,
		cancel = divider_pointer_cancel, held = divider_held, holds = true, blurs_find = true,
	},
	.Status_Panel     = {
		claims = status_panel_claims, hover = status_panel_hover, press = status_panel_press,
		release = status_panel_release, tooltip = status_panel_tooltip, cancel = status_panel_cancel,
		leave = status_panel_leave, holds = true, blurs_find = true, under_floats = true,
	},
	.Tabs             = {
		claims = tabs_claims, hover = tabs_hover, press = tab_interaction_press, release = tabs_release,
		tooltip = tabs_tooltip, cancel = tabs_cancel, leave = tabs_leave, held = tabs_held, holds = true,
		blurs_find = true, under_floats = true,
	},
	.Floating         = {
		claims = floating_claims, hover = floating_hover, press = floating_press, release = floating_release,
		tooltip = floating_tooltip, cancel = floating_pointer_cancel, leave = floating_leave,
		held = floating_held, holds = true, blurs_find = true,
	},
	.Pane_Header      = {
		claims = header_claims, hover = header_hover, press = pane_header_press, release = header_release,
		tooltip = header_tooltip, tooltip_card = header_tooltip_card, cancel = header_cancel,
		leave = header_leave, held = pane_drag_held, holds = true, blurs_find = true, in_pane = true,
	},
	.Scrollbar        = {
		claims = scrollbar_claims, hover = scrollbar_hover, press = scrollbar_press,
		release = scrollbar_release, cancel = scrollbar_cancel, leave = scrollbar_leave,
		held = scrollbar_held, holds = true, blurs_find = true, in_pane = true,
	},
	.Settings_Page    = {
		claims = settings_claims, hover = settings_pointer_hover, press = settings_press,
		release = settings_release, tooltip = settings_tooltip, cancel = settings_pointer_cancel,
		leave = settings_leave, holds = true, blurs_find = true, in_pane = true,
	},
	// Not in_pane: a lone Markdown pane's content does not reveal its split controls, as it never has.
	.Markdown_Page    = {
		claims = markdown_claims, hover = markdown_hover, press = markdown_press, release = markdown_release,
		cancel = markdown_gesture_clear, leave = markdown_leave, holds = true, blurs_find = true,
	},
	.Content          = {
		claims = content_claims, hover = content_hover, press = content_press, release = content_release,
		cancel = content_cancel, leave = content_leave, holds = true, blurs_find = true, in_pane = true,
	},
}

// The workspace and tab chrome a linked window does not draw.
@(private = "file")
POINTER_LINKED_ABSENT :: bit_set[Pointer_Target] {
	.Tab_Orientation,
	.Title_Action,
	.Workspace_Button,
	.Status_Pill,
	.Status_Panel,
	.Tabs,
}

// The topmost surface whose area holds the point. Below the modal surfaces, callers handle presses
// and drags that already hold the pointer before acting on the answer.
pointer_target :: proc(app: ^App, w: ^Window, x, y: f32) -> Pointer_Target {
	for target in Pointer_Target {
		if window_linked(w) && target in POINTER_LINKED_ABSENT {continue}
		if pointer_surfaces[target].under_floats && floating_covers(w, x, y) {continue}
		if pointer_surfaces[target].claims(app, w, x, y) {return target}
	}
	return .Content
}

// Whether the target takes the whole window ahead of held presses and drags.
pointer_modal :: proc(target: Pointer_Target) -> bool {
	return pointer_surfaces[target].modal
}

// Lets every surface see the move: the owner hovers and sets the cursor, the rest clear their hover.
pointer_move :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: input.Mouse_Move_Event) {
	for surface in pointer_surfaces {
		if surface.hover != nil {surface.hover(app, w, owner, e)}
	}
	tooltip_hover(app, w, owner, e)
}

// The pointer left the window: every surface drops its hover through its own leave.
pointer_leave :: proc(app: ^App, w: ^Window) {
	tooltip_cancel(w)
	for surface in pointer_surfaces {
		if surface.leave != nil {surface.leave(app, w)}
	}
	w.dirty = true
}

// The held drag, if any, follows the move.
pointer_held :: proc(
	app: ^App,
	w: ^Window,
	under: Pointer_Target,
	e: input.Mouse_Move_Event,
) -> Pointer_Held {
	for surface in pointer_surfaces {
		if surface.held == nil {continue}
		if held := surface.held(app, w, under, e); held != .Free {return held}
	}
	return .Free
}

pointer_press :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: input.Mouse_Button_Event) {
	if e.pressed {tooltip_cancel(w)}
	pointer_surfaces[owner].press(app, w, e)
}

pointer_release :: proc(
	app: ^App,
	w: ^Window,
	owner: Pointer_Target,
	e: input.Mouse_Button_Event,
) -> bool {
	release := pointer_surfaces[owner].release
	return release != nil && release(app, w, e)
}

