package main

import "aio:render"
import "aio:ui"

// The surfaces that can own the pointer, listed topmost first. The order is the precedence: hover,
// cursor and press all resolve through `pointer_target`, so the surface that shows a hover is the one
// a press reaches, and the surfaces beneath it see the pointer leave.
Pointer_Target :: enum u8 {
	// Modal surfaces take the whole window, including presses and releases that began elsewhere.
	Workspace_Picker,
	Tab_Menu,
	Profile_Menu,
	Status_Inbox,
	Rename,
	// Window caption buttons, which stay usable over every overlay.
	Caption,
	// An open confirmation takes the rest of the window.
	Confirmation,
	// The command palette takes the rest of the window while it is open.
	Palette,
	Tab_Orientation,
	// The find bar floats over panes, headers and the Activity panel.
	Find,
	Workspace_Button,
	Status_Pill,
	Divider,
	Status_Panel,
	// The tab strip band or the rail, including an overlay rail above the panes.
	Tabs,
	// Pane headers and a single pane's floating split controls.
	Pane_Header,
	Scrollbar,
	// Pane content (terminal text, links, settings pages) and anything uncovered.
	Content,
}

// The topmost surface whose area holds the point. Below the modal surfaces, callers handle presses
// and drags that already hold the pointer before acting on the answer.
pointer_target :: proc(app: ^App, w: ^Window, x, y: f32) -> Pointer_Target {
	for target in Pointer_Target {
		if pointer_claims(app, w, target, x, y) {return target}
	}
	return .Content
}

// Whether the target takes the whole window ahead of held presses and drags.
pointer_modal :: proc(target: Pointer_Target) -> bool {return target <= .Rename}

// The area each surface claims. A surface that is not showing claims nothing.
pointer_claims :: proc(app: ^App, w: ^Window, target: Pointer_Target, x, y: f32) -> bool {
	switch target {
	case .Workspace_Picker:
		return workspace_picker_active(&w.workspace_picker)
	case .Tab_Menu:
		return w.tab_menu.open
	case .Profile_Menu:
		return w.profile_menu.open
	case .Status_Inbox:
		return w.status.inbox_open
	case .Rename:
		return w.rename_open
	case .Caption:
		return ui.caption_hit(f32(w.width), x, y, w.scale) >= 0
	case .Confirmation:
		return confirmation_current(w) != nil
	case .Palette:
		return palette_active(app, w)
	case .Tab_Orientation:
		return tab_orientation_button_hit(w, x, y)
	case .Find:
		if !w.find.open {return false}
		l, _ := find_controls(w, focused_session(app, w))
		return ui.find_contains(l, x, y)
	case .Workspace_Button:
		toggle := tab_orientation_button_rect(w)
		return y >= 0 && y < ui.TITLE_BAR_HEIGHT * w.scale && x >= toggle.x + toggle.width &&
			x < workspace_button_width(w)
	case .Status_Pill:
		return status_rect_contains(status_pill_rect(app, w), x, y)
	case .Divider:
		_, over := divider_cursor(w, x, y)
		return over
	case .Status_Panel:
		return status_panel_contains(app, w, x, y)
	case .Tabs:
		return tab_interaction_hit(app, w, x, y, .Left).kind != .Outside
	case .Pane_Header:
		_, _, hit := pane_header_hit(w, x, y)
		return hit
	case .Scrollbar:
		return terminal_scrollbar_at(app, w, x, y) != 0
	case .Content:
		return true
	}
	return false
}

@(private)
rect_contains :: proc(r: render.Rect, x, y: f32) -> bool {
	return x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height
}
