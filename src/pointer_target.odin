package main

import "cosmos:host"
import "cosmos:input"

// The surfaces that can own the pointer, listed topmost first. The order is the precedence: hover,
// cursor and press all resolve through `pointer_target`, so the surface that shows a hover is the one
// a press reaches, and the surfaces beneath it see the pointer leave. Each surface's handlers live with
// its feature; this file composes them and holds the policy that decides between surfaces.
Pointer_Target :: enum u8 {
	Notice,
	Workspace_Picker,
	Tab_Menu,
	Divider_Menu,
	Activity_Menu,
	Activity_Row_Menu,
	Edit_Menu,
	Profile_Menu,
	Document_Menu,
	Command_Menu,
	Status_Inbox,
	Rename,
	// Window caption buttons, which stay usable over every overlay.
	Caption,
	// An open confirmation takes the rest of the window.
	Confirmation,
	// The everything palette takes the rest of the window while it is open.
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
	// The title bar button that shows and hides the Activity panel.
	Activity_Toggle,
	Divider,
	Status_Panel,
	// The tab strip band or the rail, including an overlay rail above the panes.
	Tabs,
	// A floating pane's resize edges and the capsules of minimized floating panes. A floating pane also
	// hides the dividers below it.
	Floating,
	// Pane headers.
	Pane_Header,
	Scrollbar,
	// A settings page shown in a pane.
	Settings_Page,
	// A Markdown document shown in a pane.
	Markdown_Page,
	// An Agent changes pane.
	Changes_Page,
	// An embedded web pane (URL bar and WebView2 body).
	Web_Page,
	// A Neovim pane's grid.
	Neovim_Page,
	// Terminal content, including its links, and anything uncovered.
	Content,
}

// What a surface's controls show in tooltips (tooltip.odin); every field may be nil.
Pointer_Tip :: struct {
	// The hovered control supplies a short label; the shared tooltip owns timing and drawing.
	tooltip:      proc(app: ^App, w: ^Window, x, y: f32) -> string,
	// What the labelled control would do, drawn under the label while the tooltip shows.
	tooltip_card: proc(app: ^App, w: ^Window, x, y: f32) -> Tooltip_Card,
	// The command or fixed key that does what the labelled control does, for a tooltip that names its
	// shortcut. A control names it here, never in its label, so the tooltip shows the key the handler uses
	// and a rebinding at once.
	shortcut:     proc(app: ^App, w: ^Window, x, y: f32) -> Tooltip_Shortcut,
}

// A new surface adds a target above and one entry in pointer_surfaces (host.Pointer_Surface), and one in
// pointer_tips when its controls have tooltips.

@(rodata)
pointer_surfaces := [Pointer_Target]host.Pointer_Surface(App, Window, Pointer_Target) {
	.Notice           = {
		claims = notice_claims, hover = notice_hover, press = notice_press, release = notice_release,
		cancel = notice_cancel, leave = notice_leave, holds = true,
	},
	.Workspace_Picker = {
		claims = workspace_picker_claims, hover = workspace_picker_pointer_hover,
		press = workspace_picker_button, cancel = workspace_picker_pointer_cancel,
		leave = workspace_picker_leave, modal = true,
	},
	.Tab_Menu         = {
		claims = tab_menu_claims, hover = tab_menu_hover, press = tab_menu_button, modal = true,
	},
	.Divider_Menu     = {
		claims = divider_menu_claims, hover = divider_menu_hover, press = divider_menu_button, modal = true,
	},
	.Activity_Menu    = {
		claims = activity_menu_claims, hover = activity_menu_hover, press = activity_menu_button,
		modal = true,
	},
	.Activity_Row_Menu = {
		claims = activity_row_menu_claims, hover = activity_row_menu_hover, press = activity_row_menu_button,
		modal = true,
	},
	.Edit_Menu        = {
		claims = edit_menu_claims, hover = edit_menu_hover, press = edit_menu_button, modal = true,
	},
	.Profile_Menu     = {
		claims = profile_menu_claims, hover = profile_menu_hover, press = profile_menu_button, modal = true,
	},
	.Document_Menu    = {
		claims = document_menu_claims, hover = document_menu_pointer_hover, press = document_menu_button,
		cancel = document_menu_pointer_cancel, leave = document_menu_leave, modal = true,
	},
	.Command_Menu     = {
		claims = command_menu_claims, hover = command_menu_pointer_hover, press = command_menu_button,
		cancel = command_menu_pointer_cancel, leave = command_menu_leave, modal = true,
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
		cancel = caption_cancel, holds = true,
	},
	.Confirmation     = {
		claims = confirmation_claims, hover = confirmation_pointer_hover, press = confirmation_press,
		cancel = confirmation_pointer_cancel,
	},
	.Palette          = {
		claims = palette_claims, hover = palette_hover, press = palette_press,
		cancel = palette_pointer_cancel,
	},
	.Tab_Orientation  = {
		claims = orientation_claims, hover = orientation_hover, press = orientation_press,
		release = orientation_release, cancel = orientation_cancel, leave = orientation_leave, holds = true,
	},
	.Title_Action     = {
		claims = title_action_claims, hover = title_action_pointer_hover, press = title_action_press,
		release = title_action_release, cancel = title_action_cancel, leave = title_action_leave,
		holds = true,
	},
	.Hidden_Panes     = {
		claims = hidden_panes_claims, hover = hidden_panes_hover, press = hidden_panes_press,
		cancel = hidden_panes_leave, leave = hidden_panes_leave, holds = true,
	},
	.Find             = {
		claims = find_claims, hover = find_pointer_hover, press = find_press, release = find_release,
		cancel = find_pointer_cancel, leave = find_leave, holds = true,
	},
	.Workspace_Button = {
		claims = workspace_button_claims, hover = workspace_button_hover, press = workspace_button_press,
		leave = workspace_button_leave, holds = true,
	},
	.Status_Pill      = {
		claims = status_pill_claims, hover = status_pill_hover, press = status_pill_press,
		leave = status_pill_leave, holds = true, under_covers = true,
	},
	.Activity_Toggle  = {
		claims = status_panel_toggle_claims, hover = status_panel_toggle_hover,
		press = status_panel_toggle_press, release = status_panel_toggle_release,
		cancel = status_panel_toggle_cancel, leave = status_panel_toggle_leave, holds = true,
	},
	.Divider          = {
		claims = divider_claims, hover = divider_hover, press = divider_pointer_press,
		release = divider_release, cancel = divider_pointer_cancel, held = divider_held, holds = true,
	},
	.Status_Panel     = {
		claims = status_panel_claims, hover = status_panel_hover, press = status_panel_press,
		release = status_panel_release, cancel = status_panel_cancel, leave = status_panel_leave,
		holds = true, under_covers = true,
	},
	.Tabs             = {
		claims = tabs_claims, hover = tabs_hover, press = tab_interaction_press, release = tabs_release,
		cancel = tabs_cancel, leave = tabs_leave, held = tabs_held, holds = true, under_covers = true,
	},
	.Floating         = {
		claims = floating_claims, hover = floating_hover, press = floating_press, release = floating_release,
		cancel = floating_pointer_cancel, leave = floating_leave, held = floating_held, holds = true,
	},
	.Pane_Header      = {
		claims = header_claims, hover = header_hover, press = pane_header_press, release = header_release,
		cancel = header_cancel, leave = header_leave, held = pane_drag_held, holds = true,
	},
	.Scrollbar        = {
		claims = scrollbar_claims, hover = scrollbar_hover, press = scrollbar_press,
		release = scrollbar_release, cancel = scrollbar_cancel, leave = scrollbar_leave,
		held = scrollbar_held, holds = true,
	},
	.Settings_Page    = {
		claims = settings_claims, hover = settings_pointer_hover, press = settings_press,
		release = settings_release, cancel = settings_pointer_cancel, leave = settings_leave, holds = true,
	},
	.Markdown_Page    = {
		claims = markdown_claims, hover = markdown_hover, press = markdown_press, release = markdown_release,
		cancel = markdown_gesture_clear, leave = markdown_leave, holds = true,
	},
	.Changes_Page     = {
		claims = changes_claims, hover = changes_hover, press = changes_press, release = changes_release,
		cancel = changes_cancel, leave = changes_leave, held = changes_divider_held, holds = true,
	},
	.Web_Page         = {
		claims = web_claims, hover = web_hover, press = web_press, release = web_release, cancel = web_cancel,
		leave = web_leave, holds = true,
	},
	.Neovim_Page      = {
		claims = neovim_claims, hover = neovim_hover, press = neovim_press, release = neovim_release,
		cancel = neovim_cancel, holds = true,
	},
	.Content          = {
		claims = content_claims, hover = content_hover, press = content_press, release = content_release,
		cancel = content_cancel, leave = content_leave, holds = true,
	},
}

@(rodata)
pointer_tips := #partial [Pointer_Target]Pointer_Tip {
	.Notice           = {
		tooltip = notice_tooltip,
	},
	.Workspace_Picker = {
		tooltip = workspace_picker_tooltip, shortcut = workspace_picker_shortcut,
	},
	.Document_Menu    = {
		tooltip = document_menu_tooltip,
	},
	.Caption          = {
		tooltip = caption_tooltip, shortcut = caption_shortcut,
	},
	.Palette          = {
		tooltip = palette_tooltip, shortcut = palette_shortcut,
	},
	.Tab_Orientation  = {
		tooltip = orientation_tooltip, shortcut = orientation_shortcut,
	},
	.Title_Action     = {
		tooltip = title_action_tooltip, shortcut = title_action_shortcut,
	},
	.Find             = {
		tooltip = find_tooltip, shortcut = find_shortcut,
	},
	.Workspace_Button = {
		tooltip = workspace_button_tooltip, shortcut = workspace_button_shortcut,
	},
	.Status_Pill      = {
		tooltip = status_pill_tooltip, shortcut = status_pill_shortcut,
	},
	.Activity_Toggle  = {
		tooltip = status_panel_toggle_tooltip, shortcut = status_panel_toggle_shortcut,
	},
	.Status_Panel     = {
		tooltip = status_panel_tooltip,
	},
	.Tabs             = {
		tooltip = tabs_tooltip, shortcut = tabs_shortcut,
	},
	.Floating         = {
		tooltip = floating_tooltip, shortcut = floating_shortcut,
	},
	.Pane_Header      = {
		tooltip = header_tooltip, tooltip_card = header_tooltip_card, shortcut = header_shortcut,
	},
	.Settings_Page    = {
		tooltip = settings_tooltip, shortcut = settings_shortcut,
	},
	.Changes_Page     = {
		tooltip = changes_tooltip, shortcut = changes_shortcut,
	},
	.Web_Page         = {
		tooltip = web_tooltip,
	},
}

// A press on one of these hands the keyboard back from the find bar to the pane; the bar and its matches
// stay.
POINTER_BLURS_FIND :: bit_set[Pointer_Target] {
	.Hidden_Panes,
	.Workspace_Button,
	.Status_Pill,
	.Activity_Toggle,
	.Divider,
	.Status_Panel,
	.Tabs,
	.Floating,
	.Pane_Header,
	.Scrollbar,
	.Settings_Page,
	.Markdown_Page,
	.Changes_Page,
	.Web_Page,
	.Neovim_Page,
	.Content,
}

// The workspace and tab chrome a linked window does not draw.
@(private = "file")
POINTER_LINKED_ABSENT :: bit_set[Pointer_Target] {
	.Tab_Orientation,
	.Title_Action,
	.Workspace_Button,
	.Status_Pill,
	.Activity_Toggle,
	.Status_Panel,
	.Tabs,
}

// The chrome Fullscreen hides: the title bar's caption buttons and controls, and the tabs. The caption
// buttons and the tab strip keep their places while hidden, over the pane header at the top edge.
@(private = "file")
POINTER_SCREEN_ABSENT :: bit_set[Pointer_Target] {
	.Caption,
	.Tab_Orientation,
	.Title_Action,
	.Workspace_Button,
	.Status_Pill,
	.Activity_Toggle,
	.Tabs,
}

// The topmost surface whose area holds the point. Below the modal surfaces, callers handle presses
// and drags that already hold the pointer before acting on the answer.
pointer_target :: proc(app: ^App, w: ^Window, x, y: f32) -> Pointer_Target {
	absent: bit_set[Pointer_Target]
	if window_linked(w) {absent += POINTER_LINKED_ABSENT}
	if w.pane_fill == .Screen {absent += POINTER_SCREEN_ABSENT}
	return host.pointer_target(&pointer_surfaces, app, w, x, y, absent, floating_covers, Pointer_Target.Content)
}

// Whether the target takes the whole window ahead of held presses and drags.
pointer_modal :: proc(target: Pointer_Target) -> bool {
	return pointer_surfaces[target].modal
}

// Lets every surface see the move: the owner hovers and sets the cursor, the rest clear their hover.
pointer_move :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: input.Mouse_Move_Event) {
	host.pointer_move(&pointer_surfaces, app, w, owner, e)
	tooltip_hover(app, w, owner, e)
}

// The pointer left the window: every surface drops its hover through its own leave.
pointer_leave :: proc(app: ^App, w: ^Window) {
	tooltip_cancel(w)
	host.pointer_leave(&pointer_surfaces, app, w)
	w.dirty = true
}

// The held drag, if any, follows the move.
pointer_held :: proc(
	app: ^App,
	w: ^Window,
	under: Pointer_Target,
	e: input.Mouse_Move_Event,
) -> host.Pointer_Held {
	return host.pointer_held(&pointer_surfaces, app, w, under, e)
}

pointer_press :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: input.Mouse_Button_Event) {
	if e.pressed {tooltip_cancel(w)}
	host.pointer_press(&pointer_surfaces, app, w, owner, e)
}

pointer_release :: proc(
	app: ^App,
	w: ^Window,
	owner: Pointer_Target,
	e: input.Mouse_Button_Event,
) -> bool {
	return host.pointer_release(&pointer_surfaces, app, w, owner, e)
}
