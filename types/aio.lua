---@meta
-- The aio API for lua-language-server: AIODev's commands, events and replies.
-- Generated: regenerate it with `aio types` rather than editing it.

-- Where a function works is stated on it: Config is init.lua inside AIODev, Script is `aio exec`,
-- and the declaration functions work only while init.lua loads.

---The AIODev scripting API. `aio.<namespace>.<name>(fields)` runs the command `<namespace>.<name>`.
---@class aio
aio = {}

---Where a callback's work came from: how a command was run, or `event` and `timer` for handlers and
---timers.
---@alias aio.Origin "key"|"palette"|"menu"|"button"|"cli"|"script"|"config"|"event"|"timer"

---What a callback receives as ctx. An action, a key and a command run from a window name the window,
---workspace and tab they act on; event handlers and timers carry only pane and origin.
---@class aio.Ctx
---@field pane integer The pane the work acts on; 0 when there is none.
---@field origin aio.Origin
---@field tab? integer The tab's id.
---@field workspace? integer The workspace's id.
---@field window? integer The window's id.
---@field key? string The key sequence pressed, for a function bound with aio.bind.

-- Running commands ----------------------------------------------------------------------------

---Runs a command or an init.lua action by name with its fields. Returns the reply without ok, status
---and error, or nil, the message and the CLI exit status. Refused while init.lua loads.
---Config and Script.
---@overload fun(name: "app.build_info", fields?: aio.fields.app.build_info): aio.Reply?, string?, integer?
---@overload fun(name: "app.command_palette", fields?: aio.fields.app.command_palette): aio.Reply?, string?, integer?
---@overload fun(name: "app.commands", fields?: aio.fields.app.commands): aio.Reply?, string?, integer?
---@overload fun(name: "app.events", fields?: aio.fields.app.events): aio.Reply?, string?, integer?
---@overload fun(name: "app.hide_to_tray", fields?: aio.fields.app.hide_to_tray): aio.Reply?, string?, integer?
---@overload fun(name: "app.input", fields: aio.fields.app.input): aio.Reply?, string?, integer?
---@overload fun(name: "app.install_agent_hooks", fields?: aio.fields.app.install_agent_hooks): aio.Reply?, string?, integer?
---@overload fun(name: "app.install_turn_hooks", fields?: aio.fields.app.install_turn_hooks): aio.Reply?, string?, integer?
---@overload fun(name: "app.lua_types", fields?: aio.fields.app.lua_types): aio.Reply?, string?, integer?
---@overload fun(name: "app.notify", fields: aio.fields.app.notify): aio.Reply?, string?, integer?
---@overload fun(name: "app.palette_commands", fields?: aio.fields.app.palette_commands): aio.Reply?, string?, integer?
---@overload fun(name: "app.palette_settings", fields?: aio.fields.app.palette_settings): aio.Reply?, string?, integer?
---@overload fun(name: "app.palette_tabs", fields?: aio.fields.app.palette_tabs): aio.Reply?, string?, integer?
---@overload fun(name: "app.palette_workspaces", fields?: aio.fields.app.palette_workspaces): aio.Reply?, string?, integer?
---@overload fun(name: "app.quit", fields?: aio.fields.app.quit): aio.Reply?, string?, integer?
---@overload fun(name: "app.restart", fields?: aio.fields.app.restart): aio.Reply?, string?, integer?
---@overload fun(name: "app.select", fields: aio.fields.app.select): aio.Reply?, string?, integer?
---@overload fun(name: "app.update", fields?: aio.fields.app.update): aio.Reply?, string?, integer?
---@overload fun(name: "app.version", fields?: aio.fields.app.version): aio.Reply?, string?, integer?
---@overload fun(name: "app.view", fields?: aio.fields.app.view): aio.Reply?, string?, integer?
---@overload fun(name: "edit.clipboard_read", fields?: aio.fields.edit.clipboard_read): aio.Reply?, string?, integer?
---@overload fun(name: "edit.clipboard_write", fields: aio.fields.edit.clipboard_write): aio.Reply?, string?, integer?
---@overload fun(name: "edit.copy", fields?: aio.fields.edit.copy): aio.Reply?, string?, integer?
---@overload fun(name: "edit.paste", fields?: aio.fields.edit.paste): aio.Reply?, string?, integer?
---@overload fun(name: "edit.select_all", fields?: aio.fields.edit.select_all): aio.Reply?, string?, integer?
---@overload fun(name: "float.dock", fields?: aio.fields.float.dock): aio.Reply?, string?, integer?
---@overload fun(name: "float.lower", fields?: aio.fields.float.lower): aio.Reply?, string?, integer?
---@overload fun(name: "float.minimize", fields?: aio.fields.float.minimize): aio.Reply?, string?, integer?
---@overload fun(name: "float.raise", fields?: aio.fields.float.raise): aio.Reply?, string?, integer?
---@overload fun(name: "float.restore", fields?: aio.fields.float.restore): aio.Reply?, string?, integer?
---@overload fun(name: "float.set_bounds", fields: aio.fields.float.set_bounds): aio.Reply?, string?, integer?
---@overload fun(name: "layout.apply", fields?: aio.fields.layout.apply): aio.Reply?, string?, integer?
---@overload fun(name: "mode.enter", fields: aio.fields.mode.enter): aio.Reply?, string?, integer?
---@overload fun(name: "mode.exit", fields?: aio.fields.mode.exit): aio.Reply?, string?, integer?
---@overload fun(name: "mode.exit_all", fields?: aio.fields.mode.exit_all): aio.Reply?, string?, integer?
---@overload fun(name: "pane.agent_changes", fields?: aio.fields.pane.agent_changes): aio.Reply?, string?, integer?
---@overload fun(name: "pane.arrange", fields?: aio.fields.pane.arrange): aio.Reply?, string?, integer?
---@overload fun(name: "pane.balance", fields?: aio.fields.pane.balance): aio.Reply?, string?, integer?
---@overload fun(name: "pane.change_shell", fields?: aio.fields.pane.change_shell): aio.Reply?, string?, integer?
---@overload fun(name: "pane.close", fields?: aio.fields.pane.close): aio.Reply?, string?, integer?
---@overload fun(name: "pane.commands", fields?: aio.fields.pane.commands): aio.Reply?, string?, integer?
---@overload fun(name: "pane.dock_down", fields?: aio.fields.pane.dock_down): aio.Reply?, string?, integer?
---@overload fun(name: "pane.dock_left", fields?: aio.fields.pane.dock_left): aio.Reply?, string?, integer?
---@overload fun(name: "pane.dock_right", fields?: aio.fields.pane.dock_right): aio.Reply?, string?, integer?
---@overload fun(name: "pane.dock_up", fields?: aio.fields.pane.dock_up): aio.Reply?, string?, integer?
---@overload fun(name: "pane.edit_markdown", fields?: aio.fields.pane.edit_markdown): aio.Reply?, string?, integer?
---@overload fun(name: "pane.fill_window", fields?: aio.fields.pane.fill_window): aio.Reply?, string?, integer?
---@overload fun(name: "pane.float", fields?: aio.fields.pane.float): aio.Reply?, string?, integer?
---@overload fun(name: "pane.focus", fields?: aio.fields.pane.focus): aio.Reply?, string?, integer?
---@overload fun(name: "pane.focus_back", fields?: aio.fields.pane.focus_back): aio.Reply?, string?, integer?
---@overload fun(name: "pane.focus_down", fields?: aio.fields.pane.focus_down): aio.Reply?, string?, integer?
---@overload fun(name: "pane.focus_forward", fields?: aio.fields.pane.focus_forward): aio.Reply?, string?, integer?
---@overload fun(name: "pane.focus_left", fields?: aio.fields.pane.focus_left): aio.Reply?, string?, integer?
---@overload fun(name: "pane.focus_next", fields?: aio.fields.pane.focus_next): aio.Reply?, string?, integer?
---@overload fun(name: "pane.focus_previous", fields?: aio.fields.pane.focus_previous): aio.Reply?, string?, integer?
---@overload fun(name: "pane.focus_right", fields?: aio.fields.pane.focus_right): aio.Reply?, string?, integer?
---@overload fun(name: "pane.focus_up", fields?: aio.fields.pane.focus_up): aio.Reply?, string?, integer?
---@overload fun(name: "pane.fullscreen", fields?: aio.fields.pane.fullscreen): aio.Reply?, string?, integer?
---@overload fun(name: "pane.keep_open", fields?: aio.fields.pane.keep_open): aio.Reply?, string?, integer?
---@overload fun(name: "pane.linked_window", fields?: aio.fields.pane.linked_window): aio.Reply?, string?, integer?
---@overload fun(name: "pane.links", fields?: aio.fields.pane.links): aio.Reply?, string?, integer?
---@overload fun(name: "pane.list", fields?: aio.fields.pane.list): aio.Reply?, string?, integer?
---@overload fun(name: "pane.minimize_all_floating", fields?: aio.fields.pane.minimize_all_floating): aio.Reply?, string?, integer?
---@overload fun(name: "pane.minimize_floating", fields?: aio.fields.pane.minimize_floating): aio.Reply?, string?, integer?
---@overload fun(name: "pane.move", fields: aio.fields.pane.move): aio.Reply?, string?, integer?
---@overload fun(name: "pane.move_down", fields?: aio.fields.pane.move_down): aio.Reply?, string?, integer?
---@overload fun(name: "pane.move_left", fields?: aio.fields.pane.move_left): aio.Reply?, string?, integer?
---@overload fun(name: "pane.move_new_tab", fields?: aio.fields.pane.move_new_tab): aio.Reply?, string?, integer?
---@overload fun(name: "pane.move_new_window", fields?: aio.fields.pane.move_new_window): aio.Reply?, string?, integer?
---@overload fun(name: "pane.move_new_workspace", fields?: aio.fields.pane.move_new_workspace): aio.Reply?, string?, integer?
---@overload fun(name: "pane.move_right", fields?: aio.fields.pane.move_right): aio.Reply?, string?, integer?
---@overload fun(name: "pane.move_tab_1", fields?: aio.fields.pane.move_tab_1): aio.Reply?, string?, integer?
---@overload fun(name: "pane.move_tab_2", fields?: aio.fields.pane.move_tab_2): aio.Reply?, string?, integer?
---@overload fun(name: "pane.move_tab_3", fields?: aio.fields.pane.move_tab_3): aio.Reply?, string?, integer?
---@overload fun(name: "pane.move_tab_4", fields?: aio.fields.pane.move_tab_4): aio.Reply?, string?, integer?
---@overload fun(name: "pane.move_tab_5", fields?: aio.fields.pane.move_tab_5): aio.Reply?, string?, integer?
---@overload fun(name: "pane.move_tab_6", fields?: aio.fields.pane.move_tab_6): aio.Reply?, string?, integer?
---@overload fun(name: "pane.move_tab_7", fields?: aio.fields.pane.move_tab_7): aio.Reply?, string?, integer?
---@overload fun(name: "pane.move_tab_8", fields?: aio.fields.pane.move_tab_8): aio.Reply?, string?, integer?
---@overload fun(name: "pane.move_tab_9", fields?: aio.fields.pane.move_tab_9): aio.Reply?, string?, integer?
---@overload fun(name: "pane.move_up", fields?: aio.fields.pane.move_up): aio.Reply?, string?, integer?
---@overload fun(name: "pane.move_workspace", fields?: aio.fields.pane.move_workspace): aio.Reply?, string?, integer?
---@overload fun(name: "pane.new_floating", fields?: aio.fields.pane.new_floating): aio.Reply?, string?, integer?
---@overload fun(name: "pane.open_markdown", fields?: aio.fields.pane.open_markdown): aio.Reply?, string?, integer?
---@overload fun(name: "pane.open_markdown_default_app", fields?: aio.fields.pane.open_markdown_default_app): aio.Reply?, string?, integer?
---@overload fun(name: "pane.open_web", fields?: aio.fields.pane.open_web): aio.Reply?, string?, integer?
---@overload fun(name: "pane.process", fields?: aio.fields.pane.process): aio.Reply?, string?, integer?
---@overload fun(name: "pane.read", fields?: aio.fields.pane.read): aio.Reply?, string?, integer?
---@overload fun(name: "pane.rename", fields?: aio.fields.pane.rename): aio.Reply?, string?, integer?
---@overload fun(name: "pane.reopen_closed", fields?: aio.fields.pane.reopen_closed): aio.Reply?, string?, integer?
---@overload fun(name: "pane.resize", fields: aio.fields.pane.resize): aio.Reply?, string?, integer?
---@overload fun(name: "pane.resize_down", fields?: aio.fields.pane.resize_down): aio.Reply?, string?, integer?
---@overload fun(name: "pane.resize_down_large", fields?: aio.fields.pane.resize_down_large): aio.Reply?, string?, integer?
---@overload fun(name: "pane.resize_left", fields?: aio.fields.pane.resize_left): aio.Reply?, string?, integer?
---@overload fun(name: "pane.resize_left_large", fields?: aio.fields.pane.resize_left_large): aio.Reply?, string?, integer?
---@overload fun(name: "pane.resize_right", fields?: aio.fields.pane.resize_right): aio.Reply?, string?, integer?
---@overload fun(name: "pane.resize_right_large", fields?: aio.fields.pane.resize_right_large): aio.Reply?, string?, integer?
---@overload fun(name: "pane.resize_up", fields?: aio.fields.pane.resize_up): aio.Reply?, string?, integer?
---@overload fun(name: "pane.resize_up_large", fields?: aio.fields.pane.resize_up_large): aio.Reply?, string?, integer?
---@overload fun(name: "pane.restart", fields?: aio.fields.pane.restart): aio.Reply?, string?, integer?
---@overload fun(name: "pane.rotate_split", fields?: aio.fields.pane.rotate_split): aio.Reply?, string?, integer?
---@overload fun(name: "pane.send", fields?: aio.fields.pane.send): aio.Reply?, string?, integer?
---@overload fun(name: "pane.send_keys", fields: aio.fields.pane.send_keys): aio.Reply?, string?, integer?
---@overload fun(name: "pane.set_ratio", fields: aio.fields.pane.set_ratio): aio.Reply?, string?, integer?
---@overload fun(name: "pane.split", fields?: aio.fields.pane.split): aio.Reply?, string?, integer?
---@overload fun(name: "pane.split_down", fields?: aio.fields.pane.split_down): aio.Reply?, string?, integer?
---@overload fun(name: "pane.split_left", fields?: aio.fields.pane.split_left): aio.Reply?, string?, integer?
---@overload fun(name: "pane.split_right", fields?: aio.fields.pane.split_right): aio.Reply?, string?, integer?
---@overload fun(name: "pane.split_up", fields?: aio.fields.pane.split_up): aio.Reply?, string?, integer?
---@overload fun(name: "pane.status", fields?: aio.fields.pane.status): aio.Reply?, string?, integer?
---@overload fun(name: "pane.swap_down", fields?: aio.fields.pane.swap_down): aio.Reply?, string?, integer?
---@overload fun(name: "pane.swap_left", fields?: aio.fields.pane.swap_left): aio.Reply?, string?, integer?
---@overload fun(name: "pane.swap_next", fields?: aio.fields.pane.swap_next): aio.Reply?, string?, integer?
---@overload fun(name: "pane.swap_previous", fields?: aio.fields.pane.swap_previous): aio.Reply?, string?, integer?
---@overload fun(name: "pane.swap_right", fields?: aio.fields.pane.swap_right): aio.Reply?, string?, integer?
---@overload fun(name: "pane.swap_up", fields?: aio.fields.pane.swap_up): aio.Reply?, string?, integer?
---@overload fun(name: "pane.toggle_web_navigator", fields?: aio.fields.pane.toggle_web_navigator): aio.Reply?, string?, integer?
---@overload fun(name: "pane.zoom", fields?: aio.fields.pane.zoom): aio.Reply?, string?, integer?
---@overload fun(name: "profile.open_1", fields?: aio.fields.profile.open_1): aio.Reply?, string?, integer?
---@overload fun(name: "profile.open_2", fields?: aio.fields.profile.open_2): aio.Reply?, string?, integer?
---@overload fun(name: "profile.open_3", fields?: aio.fields.profile.open_3): aio.Reply?, string?, integer?
---@overload fun(name: "profile.open_4", fields?: aio.fields.profile.open_4): aio.Reply?, string?, integer?
---@overload fun(name: "profile.open_5", fields?: aio.fields.profile.open_5): aio.Reply?, string?, integer?
---@overload fun(name: "profile.open_6", fields?: aio.fields.profile.open_6): aio.Reply?, string?, integer?
---@overload fun(name: "profile.open_7", fields?: aio.fields.profile.open_7): aio.Reply?, string?, integer?
---@overload fun(name: "profile.open_8", fields?: aio.fields.profile.open_8): aio.Reply?, string?, integer?
---@overload fun(name: "profile.open_9", fields?: aio.fields.profile.open_9): aio.Reply?, string?, integer?
---@overload fun(name: "settings.change_shortcut", fields?: aio.fields.settings.change_shortcut): aio.Reply?, string?, integer?
---@overload fun(name: "settings.check_lua", fields?: aio.fields.settings.check_lua): aio.Reply?, string?, integer?
---@overload fun(name: "settings.customize_colors", fields?: aio.fields.settings.customize_colors): aio.Reply?, string?, integer?
---@overload fun(name: "settings.get", fields: aio.fields.settings.get): aio.Reply?, string?, integer?
---@overload fun(name: "settings.lua_path", fields?: aio.fields.settings.lua_path): aio.Reply?, string?, integer?
---@overload fun(name: "settings.open", fields?: aio.fields.settings.open): aio.Reply?, string?, integer?
---@overload fun(name: "settings.open_file", fields?: aio.fields.settings.open_file): aio.Reply?, string?, integer?
---@overload fun(name: "settings.reload", fields?: aio.fields.settings.reload): aio.Reply?, string?, integer?
---@overload fun(name: "settings.set", fields: aio.fields.settings.set): aio.Reply?, string?, integer?
---@overload fun(name: "status.dismiss_finished", fields?: aio.fields.status.dismiss_finished): aio.Reply?, string?, integer?
---@overload fun(name: "status.inbox", fields?: aio.fields.status.inbox): aio.Reply?, string?, integer?
---@overload fun(name: "status.next", fields?: aio.fields.status.next): aio.Reply?, string?, integer?
---@overload fun(name: "status.panel", fields?: aio.fields.status.panel): aio.Reply?, string?, integer?
---@overload fun(name: "status.panel_next", fields?: aio.fields.status.panel_next): aio.Reply?, string?, integer?
---@overload fun(name: "status.panel_previous", fields?: aio.fields.status.panel_previous): aio.Reply?, string?, integer?
---@overload fun(name: "tab.close", fields?: aio.fields.tab.close): aio.Reply?, string?, integer?
---@overload fun(name: "tab.close_others", fields?: aio.fields.tab.close_others): aio.Reply?, string?, integer?
---@overload fun(name: "tab.close_right", fields?: aio.fields.tab.close_right): aio.Reply?, string?, integer?
---@overload fun(name: "tab.context_menu", fields?: aio.fields.tab.context_menu): aio.Reply?, string?, integer?
---@overload fun(name: "tab.duplicate", fields?: aio.fields.tab.duplicate): aio.Reply?, string?, integer?
---@overload fun(name: "tab.group_add", fields: aio.fields.tab.group_add): aio.Reply?, string?, integer?
---@overload fun(name: "tab.group_close", fields?: aio.fields.tab.group_close): aio.Reply?, string?, integer?
---@overload fun(name: "tab.group_color", fields: aio.fields.tab.group_color): aio.Reply?, string?, integer?
---@overload fun(name: "tab.group_fold", fields?: aio.fields.tab.group_fold): aio.Reply?, string?, integer?
---@overload fun(name: "tab.group_move_workspace", fields?: aio.fields.tab.group_move_workspace): aio.Reply?, string?, integer?
---@overload fun(name: "tab.group_new", fields?: aio.fields.tab.group_new): aio.Reply?, string?, integer?
---@overload fun(name: "tab.group_new_tab", fields?: aio.fields.tab.group_new_tab): aio.Reply?, string?, integer?
---@overload fun(name: "tab.group_remove", fields?: aio.fields.tab.group_remove): aio.Reply?, string?, integer?
---@overload fun(name: "tab.group_rename", fields?: aio.fields.tab.group_rename): aio.Reply?, string?, integer?
---@overload fun(name: "tab.group_ungroup", fields?: aio.fields.tab.group_ungroup): aio.Reply?, string?, integer?
---@overload fun(name: "tab.last", fields?: aio.fields.tab.last): aio.Reply?, string?, integer?
---@overload fun(name: "tab.list", fields?: aio.fields.tab.list): aio.Reply?, string?, integer?
---@overload fun(name: "tab.move_end", fields?: aio.fields.tab.move_end): aio.Reply?, string?, integer?
---@overload fun(name: "tab.move_left", fields?: aio.fields.tab.move_left): aio.Reply?, string?, integer?
---@overload fun(name: "tab.move_new_workspace", fields?: aio.fields.tab.move_new_workspace): aio.Reply?, string?, integer?
---@overload fun(name: "tab.move_right", fields?: aio.fields.tab.move_right): aio.Reply?, string?, integer?
---@overload fun(name: "tab.move_start", fields?: aio.fields.tab.move_start): aio.Reply?, string?, integer?
---@overload fun(name: "tab.move_workspace", fields?: aio.fields.tab.move_workspace): aio.Reply?, string?, integer?
---@overload fun(name: "tab.new", fields?: aio.fields.tab.new): aio.Reply?, string?, integer?
---@overload fun(name: "tab.next", fields?: aio.fields.tab.next): aio.Reply?, string?, integer?
---@overload fun(name: "tab.previous", fields?: aio.fields.tab.previous): aio.Reply?, string?, integer?
---@overload fun(name: "tab.rename", fields?: aio.fields.tab.rename): aio.Reply?, string?, integer?
---@overload fun(name: "tab.select_1", fields?: aio.fields.tab.select_1): aio.Reply?, string?, integer?
---@overload fun(name: "tab.select_2", fields?: aio.fields.tab.select_2): aio.Reply?, string?, integer?
---@overload fun(name: "tab.select_3", fields?: aio.fields.tab.select_3): aio.Reply?, string?, integer?
---@overload fun(name: "tab.select_4", fields?: aio.fields.tab.select_4): aio.Reply?, string?, integer?
---@overload fun(name: "tab.select_5", fields?: aio.fields.tab.select_5): aio.Reply?, string?, integer?
---@overload fun(name: "tab.select_6", fields?: aio.fields.tab.select_6): aio.Reply?, string?, integer?
---@overload fun(name: "tab.select_7", fields?: aio.fields.tab.select_7): aio.Reply?, string?, integer?
---@overload fun(name: "tab.select_8", fields?: aio.fields.tab.select_8): aio.Reply?, string?, integer?
---@overload fun(name: "tab.select_9", fields?: aio.fields.tab.select_9): aio.Reply?, string?, integer?
---@overload fun(name: "tab.settings", fields?: aio.fields.tab.settings): aio.Reply?, string?, integer?
---@overload fun(name: "terminal.clear_scrollback", fields?: aio.fields.terminal.clear_scrollback): aio.Reply?, string?, integer?
---@overload fun(name: "terminal.find", fields?: aio.fields.terminal.find): aio.Reply?, string?, integer?
---@overload fun(name: "terminal.restart_shell", fields?: aio.fields.terminal.restart_shell): aio.Reply?, string?, integer?
---@overload fun(name: "terminal.scroll_page_down", fields?: aio.fields.terminal.scroll_page_down): aio.Reply?, string?, integer?
---@overload fun(name: "terminal.scroll_page_up", fields?: aio.fields.terminal.scroll_page_up): aio.Reply?, string?, integer?
---@overload fun(name: "terminal.scroll_partial_down", fields?: aio.fields.terminal.scroll_partial_down): aio.Reply?, string?, integer?
---@overload fun(name: "terminal.scroll_partial_up", fields?: aio.fields.terminal.scroll_partial_up): aio.Reply?, string?, integer?
---@overload fun(name: "view.font_size_decrease", fields?: aio.fields.view.font_size_decrease): aio.Reply?, string?, integer?
---@overload fun(name: "view.font_size_increase", fields?: aio.fields.view.font_size_increase): aio.Reply?, string?, integer?
---@overload fun(name: "view.font_size_reset", fields?: aio.fields.view.font_size_reset): aio.Reply?, string?, integer?
---@overload fun(name: "view.tabs_orientation", fields?: aio.fields.view.tabs_orientation): aio.Reply?, string?, integer?
---@overload fun(name: "view.tabs_rail", fields?: aio.fields.view.tabs_rail): aio.Reply?, string?, integer?
---@overload fun(name: "window.new", fields?: aio.fields.window.new): aio.Reply?, string?, integer?
---@overload fun(name: "workspace.change", fields?: aio.fields.workspace.change): aio.Reply?, string?, integer?
---@overload fun(name: "workspace.change_icon", fields?: aio.fields.workspace.change_icon): aio.Reply?, string?, integer?
---@overload fun(name: "workspace.delete", fields?: aio.fields.workspace.delete): aio.Reply?, string?, integer?
---@overload fun(name: "workspace.list", fields?: aio.fields.workspace.list): aio.Reply?, string?, integer?
---@overload fun(name: "workspace.new", fields?: aio.fields.workspace.new): aio.Reply?, string?, integer?
---@overload fun(name: "workspace.next", fields?: aio.fields.workspace.next): aio.Reply?, string?, integer?
---@overload fun(name: "workspace.previous", fields?: aio.fields.workspace.previous): aio.Reply?, string?, integer?
---@overload fun(name: "workspace.rename", fields?: aio.fields.workspace.rename): aio.Reply?, string?, integer?
---@overload fun(name: "workspace.select_1", fields?: aio.fields.workspace.select_1): aio.Reply?, string?, integer?
---@overload fun(name: "workspace.select_2", fields?: aio.fields.workspace.select_2): aio.Reply?, string?, integer?
---@overload fun(name: "workspace.select_3", fields?: aio.fields.workspace.select_3): aio.Reply?, string?, integer?
---@overload fun(name: "workspace.select_4", fields?: aio.fields.workspace.select_4): aio.Reply?, string?, integer?
---@overload fun(name: "workspace.select_5", fields?: aio.fields.workspace.select_5): aio.Reply?, string?, integer?
---@overload fun(name: "workspace.select_6", fields?: aio.fields.workspace.select_6): aio.Reply?, string?, integer?
---@overload fun(name: "workspace.select_7", fields?: aio.fields.workspace.select_7): aio.Reply?, string?, integer?
---@overload fun(name: "workspace.select_8", fields?: aio.fields.workspace.select_8): aio.Reply?, string?, integer?
---@overload fun(name: "workspace.select_9", fields?: aio.fields.workspace.select_9): aio.Reply?, string?, integer?
---@param name string A command name such as `pane.split`, or an action's name.
---@param fields? table The command's arguments, as `aio help <command>` lists them.
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.run(name, fields) end

---Runs a command or action and returns only its reply's `result`: what an init.lua action returned.
---Config and Script.
---@param name string
---@param args? table
---@return any result
---@return string? message
---@return integer? status
function aio.invoke(name, args) end

---Every window, workspace, tab and pane, with each tab's tiled tree and floats nested.
---Config and Script.
---@return aio.View? view
---@return string? message
---@return integer? status
function aio.view() end

---What aio.view() returns: app.view's document with nested trees instead of a flat nodes list.
---@class aio.View
---@field revision integer The layout revision; layout.changed reports the same number.
---@field windows aio.ViewWindowReport[]
---@field workspaces aio.ViewWorkspace[]
---@field panes aio.PaneReport[]

---@class aio.ViewWorkspace
---@field id integer
---@field name string
---@field selected boolean Whether the focused-or-primary window shows this workspace.
---@field tabs aio.ViewTab[]

---@class aio.ViewTab
---@field id integer The tab's id, which events carry.
---@field index integer The tab's position in its workspace, from 1, as pane.list's `tab`.
---@field name string
---@field title string
---@field group integer
---@field selected boolean
---@field focused_pane integer
---@field view "split"|"zoom"|"fill"|"fullscreen"
---@field root? aio.ViewNode The tiled tree; nil when every pane floats or the tab shows none.
---@field floats aio.ViewFloat[]

---A leaf holds pane; a split holds split, ratio, first and second.
---@class aio.ViewNode
---@field pane? integer
---@field split? "right"|"down"
---@field ratio? number The first child's share.
---@field first? aio.ViewNode
---@field second? aio.ViewNode

---@class aio.ViewFloat
---@field bounds number[] x, y, width and height as shares of the window's floating work area.
---@field cells? integer[] The same rectangle in terminal cells, when a window shows the tab.
---@field stack integer
---@field minimized boolean
---@field root? aio.ViewNode

---@class aio.NotifyOptions
---@field title? string
---@field body string

---Shows an Info notice, or a system notification when no window is visible. Config and Script.
---@param opts aio.NotifyOptions
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.notify(opts) end

aio.clipboard = {}

---The clipboard's text. Config and Script.
---@return string? text
---@return string? message
---@return integer? status
function aio.clipboard.get() end

---Puts text on the clipboard. Config and Script.
---@param text string
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.clipboard.set(text) end

aio.settings = {}

---A setting's current value as settings.ini writes it, such as `aio.settings.get('font.size')`.
---Config and Script.
---@param key string
---@return string? value
---@return string? message
---@return integer? status
function aio.settings.get(key) end

---Checks, applies and saves a setting as the Settings page does. Config and Script.
---@param key string
---@param value any Written with tostring.
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.settings.set(key, value) end

---@alias aio.LogLevel "debug"|"trace"|"info"|"warn"|"warning"|"error"

---Writes to the app log; in init.lua, warn and error also show a notice. Config and Script.
---@param level aio.LogLevel
---@param message any
---@overload fun(message: any)
function aio.log(level, message) end

---JSON with Lua tables: a table with only positive integer keys is an array; null decodes as nil.
aio.json = {}

---@class aio.JsonOptions
---@field indent? integer|string Spaces (up to 16) or the text to indent each level with.

---@param value any
---@param opts? aio.JsonOptions
---@return string? text
---@return string? message
function aio.json.encode(value, opts) end

---@param text string
---@return any value
---@return string? message
function aio.json.decode(text) end

-- Layout --------------------------------------------------------------------------------------

---Builds layout.apply's nested tree in Lua.
aio.layout = {}

---@class aio.LayoutPane
---@field name? string
---@field command? string[] The program, then its arguments.
---@field cwd? string
---@field profile? string

---@class aio.LayoutSplit
---@field split "right"|"down"
---@field ratio number The first child's share, between 0 and 1.
---@field first aio.LayoutNode
---@field second aio.LayoutNode

---@alias aio.LayoutNode aio.LayoutPane|aio.LayoutSplit

---@class aio.LayoutFloat
---@field bounds number[] x, y, width and height.
---@field unit? "share"|"cells"
---@field pane? aio.LayoutPane

---@class aio.Layout
---@field tab? string The new tab's name.
---@field cwd? string The directory relative pane directories start from.
---@field root aio.LayoutNode
---@field floats? aio.LayoutFloat[]

---A leaf of the tree. Config and Script.
---@param opts aio.LayoutPane
---@return aio.LayoutPane? pane
---@return string? message
function aio.layout.pane(opts) end

---A split of two nodes. Config and Script.
---@param direction "right"|"down"
---@param ratio number
---@param first aio.LayoutNode
---@param second aio.LayoutNode
---@return aio.LayoutSplit? split
---@return string? message
function aio.layout.split(direction, ratio, first, second) end

---A floating pane. Config and Script.
---@param opts aio.LayoutFloat
---@return aio.LayoutFloat? float
---@return string? message
function aio.layout.float(opts) end

---Opens a tab laid out as the tree describes, through the layout.apply command. Config and Script.
---@param opts aio.Layout
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.layout.apply(opts) end

-- Events and timers ---------------------------------------------------------------------------

---Any event: its name in `type` and the fields its aio.event class lists.
---@class aio.Event
---@field type aio.EventName
---@field [string] any

---Calls fn(ctx, ev) for every event of that name, after the tick that caused it. Returns fn. An
---unknown name raises an error. Config and Script.
---@overload fun(name: "pane.created", fn: (fun(ctx: aio.Ctx, ev: aio.event.PaneCreated))): (fun(ctx: aio.Ctx, ev: aio.event.PaneCreated))
---@overload fun(name: "pane.closed", fn: (fun(ctx: aio.Ctx, ev: aio.event.PaneClosed))): (fun(ctx: aio.Ctx, ev: aio.event.PaneClosed))
---@overload fun(name: "pane.exited", fn: (fun(ctx: aio.Ctx, ev: aio.event.PaneExited))): (fun(ctx: aio.Ctx, ev: aio.event.PaneExited))
---@overload fun(name: "pane.focused", fn: (fun(ctx: aio.Ctx, ev: aio.event.PaneFocused))): (fun(ctx: aio.Ctx, ev: aio.event.PaneFocused))
---@overload fun(name: "pane.title_changed", fn: (fun(ctx: aio.Ctx, ev: aio.event.PaneTitleChanged))): (fun(ctx: aio.Ctx, ev: aio.event.PaneTitleChanged))
---@overload fun(name: "pane.cwd_changed", fn: (fun(ctx: aio.Ctx, ev: aio.event.PaneCwdChanged))): (fun(ctx: aio.Ctx, ev: aio.event.PaneCwdChanged))
---@overload fun(name: "pane.bell", fn: (fun(ctx: aio.Ctx, ev: aio.event.PaneBell))): (fun(ctx: aio.Ctx, ev: aio.event.PaneBell))
---@overload fun(name: "pane.status_changed", fn: (fun(ctx: aio.Ctx, ev: aio.event.PaneStatusChanged))): (fun(ctx: aio.Ctx, ev: aio.event.PaneStatusChanged))
---@overload fun(name: "pane.notification", fn: (fun(ctx: aio.Ctx, ev: aio.event.PaneNotification))): (fun(ctx: aio.Ctx, ev: aio.event.PaneNotification))
---@overload fun(name: "pane.resized", fn: (fun(ctx: aio.Ctx, ev: aio.event.PaneResized))): (fun(ctx: aio.Ctx, ev: aio.event.PaneResized))
---@overload fun(name: "pane.process_changed", fn: (fun(ctx: aio.Ctx, ev: aio.event.PaneProcessChanged))): (fun(ctx: aio.Ctx, ev: aio.event.PaneProcessChanged))
---@overload fun(name: "tab.created", fn: (fun(ctx: aio.Ctx, ev: aio.event.TabCreated))): (fun(ctx: aio.Ctx, ev: aio.event.TabCreated))
---@overload fun(name: "tab.closed", fn: (fun(ctx: aio.Ctx, ev: aio.event.TabClosed))): (fun(ctx: aio.Ctx, ev: aio.event.TabClosed))
---@overload fun(name: "tab.selected", fn: (fun(ctx: aio.Ctx, ev: aio.event.TabSelected))): (fun(ctx: aio.Ctx, ev: aio.event.TabSelected))
---@overload fun(name: "tab.renamed", fn: (fun(ctx: aio.Ctx, ev: aio.event.TabRenamed))): (fun(ctx: aio.Ctx, ev: aio.event.TabRenamed))
---@overload fun(name: "workspace.created", fn: (fun(ctx: aio.Ctx, ev: aio.event.WorkspaceCreated))): (fun(ctx: aio.Ctx, ev: aio.event.WorkspaceCreated))
---@overload fun(name: "workspace.deleted", fn: (fun(ctx: aio.Ctx, ev: aio.event.WorkspaceDeleted))): (fun(ctx: aio.Ctx, ev: aio.event.WorkspaceDeleted))
---@overload fun(name: "workspace.selected", fn: (fun(ctx: aio.Ctx, ev: aio.event.WorkspaceSelected))): (fun(ctx: aio.Ctx, ev: aio.event.WorkspaceSelected))
---@overload fun(name: "workspace.renamed", fn: (fun(ctx: aio.Ctx, ev: aio.event.WorkspaceRenamed))): (fun(ctx: aio.Ctx, ev: aio.event.WorkspaceRenamed))
---@overload fun(name: "window.created", fn: (fun(ctx: aio.Ctx, ev: aio.event.WindowCreated))): (fun(ctx: aio.Ctx, ev: aio.event.WindowCreated))
---@overload fun(name: "window.closed", fn: (fun(ctx: aio.Ctx, ev: aio.event.WindowClosed))): (fun(ctx: aio.Ctx, ev: aio.event.WindowClosed))
---@overload fun(name: "window.focused", fn: (fun(ctx: aio.Ctx, ev: aio.event.WindowFocused))): (fun(ctx: aio.Ctx, ev: aio.event.WindowFocused))
---@overload fun(name: "layout.changed", fn: (fun(ctx: aio.Ctx, ev: aio.event.LayoutChanged))): (fun(ctx: aio.Ctx, ev: aio.event.LayoutChanged))
---@overload fun(name: "settings.reloaded", fn: (fun(ctx: aio.Ctx, ev: aio.event.SettingsReloaded))): (fun(ctx: aio.Ctx, ev: aio.event.SettingsReloaded))
---@overload fun(name: "settings.changed", fn: (fun(ctx: aio.Ctx, ev: aio.event.SettingsChanged))): (fun(ctx: aio.Ctx, ev: aio.event.SettingsChanged))
---@overload fun(name: "prompt.closed", fn: (fun(ctx: aio.Ctx, ev: aio.event.PromptClosed))): (fun(ctx: aio.Ctx, ev: aio.event.PromptClosed))
---@overload fun(name: "app.quitting", fn: (fun(ctx: aio.Ctx, ev: aio.event.AppQuitting))): (fun(ctx: aio.Ctx, ev: aio.event.AppQuitting))
---@param name aio.EventName
---@param fn fun(ctx: aio.Ctx, ev: aio.Event)
---@return fun(ctx: aio.Ctx, ev: aio.Event) fn
function aio.on(name, fn) end

---Suspends the calling entry point until an event of that name matches the filter: a table of field
---values, or a function returning true. Returns the event, or nil and 'timeout' after timeout
---seconds. Cannot run while init.lua loads. Config and Script.
---@overload fun(name: "pane.created", filter?: table|(fun(ev: aio.event.PaneCreated): boolean), timeout?: number): aio.event.PaneCreated?, string?
---@overload fun(name: "pane.closed", filter?: table|(fun(ev: aio.event.PaneClosed): boolean), timeout?: number): aio.event.PaneClosed?, string?
---@overload fun(name: "pane.exited", filter?: table|(fun(ev: aio.event.PaneExited): boolean), timeout?: number): aio.event.PaneExited?, string?
---@overload fun(name: "pane.focused", filter?: table|(fun(ev: aio.event.PaneFocused): boolean), timeout?: number): aio.event.PaneFocused?, string?
---@overload fun(name: "pane.title_changed", filter?: table|(fun(ev: aio.event.PaneTitleChanged): boolean), timeout?: number): aio.event.PaneTitleChanged?, string?
---@overload fun(name: "pane.cwd_changed", filter?: table|(fun(ev: aio.event.PaneCwdChanged): boolean), timeout?: number): aio.event.PaneCwdChanged?, string?
---@overload fun(name: "pane.bell", filter?: table|(fun(ev: aio.event.PaneBell): boolean), timeout?: number): aio.event.PaneBell?, string?
---@overload fun(name: "pane.status_changed", filter?: table|(fun(ev: aio.event.PaneStatusChanged): boolean), timeout?: number): aio.event.PaneStatusChanged?, string?
---@overload fun(name: "pane.notification", filter?: table|(fun(ev: aio.event.PaneNotification): boolean), timeout?: number): aio.event.PaneNotification?, string?
---@overload fun(name: "pane.resized", filter?: table|(fun(ev: aio.event.PaneResized): boolean), timeout?: number): aio.event.PaneResized?, string?
---@overload fun(name: "pane.process_changed", filter?: table|(fun(ev: aio.event.PaneProcessChanged): boolean), timeout?: number): aio.event.PaneProcessChanged?, string?
---@overload fun(name: "tab.created", filter?: table|(fun(ev: aio.event.TabCreated): boolean), timeout?: number): aio.event.TabCreated?, string?
---@overload fun(name: "tab.closed", filter?: table|(fun(ev: aio.event.TabClosed): boolean), timeout?: number): aio.event.TabClosed?, string?
---@overload fun(name: "tab.selected", filter?: table|(fun(ev: aio.event.TabSelected): boolean), timeout?: number): aio.event.TabSelected?, string?
---@overload fun(name: "tab.renamed", filter?: table|(fun(ev: aio.event.TabRenamed): boolean), timeout?: number): aio.event.TabRenamed?, string?
---@overload fun(name: "workspace.created", filter?: table|(fun(ev: aio.event.WorkspaceCreated): boolean), timeout?: number): aio.event.WorkspaceCreated?, string?
---@overload fun(name: "workspace.deleted", filter?: table|(fun(ev: aio.event.WorkspaceDeleted): boolean), timeout?: number): aio.event.WorkspaceDeleted?, string?
---@overload fun(name: "workspace.selected", filter?: table|(fun(ev: aio.event.WorkspaceSelected): boolean), timeout?: number): aio.event.WorkspaceSelected?, string?
---@overload fun(name: "workspace.renamed", filter?: table|(fun(ev: aio.event.WorkspaceRenamed): boolean), timeout?: number): aio.event.WorkspaceRenamed?, string?
---@overload fun(name: "window.created", filter?: table|(fun(ev: aio.event.WindowCreated): boolean), timeout?: number): aio.event.WindowCreated?, string?
---@overload fun(name: "window.closed", filter?: table|(fun(ev: aio.event.WindowClosed): boolean), timeout?: number): aio.event.WindowClosed?, string?
---@overload fun(name: "window.focused", filter?: table|(fun(ev: aio.event.WindowFocused): boolean), timeout?: number): aio.event.WindowFocused?, string?
---@overload fun(name: "layout.changed", filter?: table|(fun(ev: aio.event.LayoutChanged): boolean), timeout?: number): aio.event.LayoutChanged?, string?
---@overload fun(name: "settings.reloaded", filter?: table|(fun(ev: aio.event.SettingsReloaded): boolean), timeout?: number): aio.event.SettingsReloaded?, string?
---@overload fun(name: "settings.changed", filter?: table|(fun(ev: aio.event.SettingsChanged): boolean), timeout?: number): aio.event.SettingsChanged?, string?
---@overload fun(name: "prompt.closed", filter?: table|(fun(ev: aio.event.PromptClosed): boolean), timeout?: number): aio.event.PromptClosed?, string?
---@overload fun(name: "app.quitting", filter?: table|(fun(ev: aio.event.AppQuitting): boolean), timeout?: number): aio.event.AppQuitting?, string?
---@param name aio.EventName
---@param filter? table|(fun(ev: aio.Event): boolean)
---@param timeout? number
---@return aio.Event? ev
---@return string? message
function aio.wait(name, filter, timeout) end

---Suspends the calling entry point for seconds. Cannot run while init.lua loads. Config and Script.
---@param seconds number
---@return true? done
---@return string? message
function aio.sleep(seconds) end

---A timer from aio.after or aio.every. At most 1024 are live at once.
---@class aio.Timer
local Timer = {}

---Stops the timer; a running callback finishes.
function Timer:cancel() end

---Whether the timer will still fire.
---@return boolean
function Timer:active() end

---Calls fn(ctx) once, after seconds. Config and Script.
---@param seconds number
---@param fn fun(ctx: aio.Ctx)
---@return aio.Timer? timer
---@return string? message
function aio.after(seconds, fn) end

---Calls fn(ctx) every seconds; a run still suspended skips its turn. Config and Script.
---@param seconds number Positive.
---@param fn fun(ctx: aio.Ctx)
---@return aio.Timer? timer
---@return string? message
function aio.every(seconds, fn) end

-- Prompts -------------------------------------------------------------------------------------

aio.ui = {}

---@class aio.SelectOptions
---@field prompt? string The list's title.
---@field format_item? (fun(item: any): string) Each item's label; tostring by default.

---Opens a filtered list of items, in the shape of vim.ui.select. Without on_choice it suspends the
---entry point and returns the chosen item and its index, or nil when dismissed; with it, it returns
---the prompt id and calls on_choice later. Config and Script.
---@generic T
---@param items T[]
---@param opts? aio.SelectOptions
---@param on_choice? fun(item: T?, index: integer?)
---@return T|integer|nil item The chosen item, or the prompt id when on_choice is given.
---@return integer|string|nil index The index, or the failure message.
function aio.ui.select(items, opts, on_choice) end

---@class aio.InputOptions
---@field prompt? string The dialog's title.
---@field default? string The text the dialog starts with, selected.

---Opens a single-line text dialog, in the shape of vim.ui.input. Without on_confirm it suspends the
---entry point and returns the text, or nil when dismissed; with it, it returns the prompt id and
---calls on_confirm later. Config and Script.
---@param opts? aio.InputOptions
---@param on_confirm? fun(text: string?)
---@return string|integer|nil text The text, or the prompt id when on_confirm is given.
---@return string? message
function aio.ui.input(opts, on_confirm) end

-- Processes -----------------------------------------------------------------------------------

---@class aio.SystemOptions
---@field cwd? string
---@field env? table<string, string|false> Variables to set; false removes one.
---@field clear_env? boolean Start from an empty environment.
---@field stdin? string|true Text to write, or true to keep stdin open for write.
---@field text? boolean false keeps CRLF line endings.
---@field stdout? false|(fun(err: nil, data: string)) false discards; a function streams each chunk.
---@field stderr? false|(fun(err: nil, data: string)) false discards; a function streams each chunk.
---@field timeout? number Seconds before the process tree is killed.
---@field detach? boolean Outlive the callback that started it.

---@class aio.SystemResult
---@field code integer
---@field stdout string
---@field stderr string
---@field ok boolean Exit code 0 and no timeout.
---@field timed_out boolean

---A program aio.system started.
---@class aio.SystemHandle
---@field pid integer
local SystemHandle = {}

---Waits for the program to exit. In a coroutine it suspends; in a Script host's top level it blocks;
---in init.lua's top level it raises an error.
---@param timeout? number
---@return aio.SystemResult? result
---@return string? message 'timeout' or why it cannot wait.
function SystemHandle:wait(timeout) end

---@param data string
---@return true? ok
---@return string? message
function SystemHandle:write(data) end

---@return true? ok
---@return string? message
function SystemHandle:close_stdin() end

---Kills the whole process tree.
---@return true? ok
---@return string? message
function SystemHandle:kill() end

---@return boolean
function SystemHandle:is_closing() end

---Starts a program without a shell, in the shape of vim.system; only .exe and .com programs start.
---on_exit receives the result. A program that is not detached is killed when the callback that
---started it ends. Config and Script.
---@param argv string[] The program, then its arguments.
---@param opts? aio.SystemOptions
---@param on_exit? fun(result: aio.SystemResult)
---@return aio.SystemHandle? handle
---@return string? message
---@overload fun(argv: string[], on_exit: (fun(result: aio.SystemResult))): aio.SystemHandle?, string?
function aio.system(argv, opts, on_exit) end

-- Declarations --------------------------------------------------------------------------------

---A type word for an action argument; a trailing ? makes it optional.
---@alias aio.ArgType
---| "string" | "number" | "integer" | "boolean" | "object" | "array" | "any"
---| "string?" | "number?" | "integer?" | "boolean?" | "object?" | "array?" | "any?"

---@class aio.ActionSpec
---@field name string Lowercase letters, digits and _; the command's name.
---@field title string What the palette and Settings show.
---@field run (fun(ctx: aio.Ctx, args: table?): any) Its return value is the reply's result.
---@field description? string
---@field category? string The palette category; Actions by default.
---@field keywords? string|string[] More words the palette matches.
---@field args? table<string, aio.ArgType|table>|table Type words by name, checked before run starts, or a JSON Schema (a table with a type key), kept but not checked.
---@field repeats? boolean

---Declares a user action: a command the palette, Settings, keys and `aio exec` reach. A later action
---of the same name replaces it. Config only, while init.lua loads.
---@param spec aio.ActionSpec
---@return true? ok
---@return string? message
function aio.action(spec) end

---Binds a key, such as `Ctrl+Alt+H`, a sequence `Ctrl+B>C` or `mode/Key`, to a command or action by
---name with args as its fields, or to a function called as fn(ctx); a function returning false passes
---the key on. Config only, while init.lua loads.
---@param key string
---@param target string|(fun(ctx: aio.Ctx): boolean?)
---@param args? table Fields for a named target.
---@return true? ok
---@return string? message
function aio.bind(key, target, args) end

---Removes a key's binding, to target only when given. Config only, while init.lua loads.
---@param key string
---@param target? string|(fun(ctx: aio.Ctx): boolean?)
---@return true? ok
---@return string? message
function aio.unbind(key, target) end

---@class aio.ModeOptions
---@field exclusive? boolean Keys without a binding in the mode do nothing.

---Declares a key mode; `mode/Key` binds inside it and mode.enter enters it. Config only, while
---init.lua loads.
---@param name string Lowercase letters, digits, _ and -.
---@param opts? aio.ModeOptions
---@return true? ok
---@return string? message
function aio.mode(name, opts) end

---@class aio.BindingFilter
---@field key? string
---@field mode? string
---@field action? string

---@class aio.Binding
---@field op "bind"|"unbind"
---@field key string
---@field mode? string
---@field action? string The command or action name.
---@field fn? function The function target.
---@field args? table
---@field source string Where it was declared, as `file:line`.

---The key operations init.lua declared so far that match the filter. Config only, while init.lua
---loads.
---@param filter? aio.BindingFilter
---@return aio.Binding[]? bindings
---@return string? message
function aio.bindings(filter) end

-- Script host ---------------------------------------------------------------------------------

---Ends the script with code, 0 by default. Script only.
---@param code? integer
---@return nil
---@return string? message
function aio.stop(code) end

---The script's arguments, from `key=value` words or `--args`. Script only.
---@type table<string, any>
aio.args = {}

---The pane `aio exec` ran in, 0 outside AIODev. Script only.
---@type integer
aio.pane_id = 0

-- Replies -------------------------------------------------------------------------------------

---A command's reply: the fields the command filled. aio.run removes ok, status and error.
---@class aio.Reply
---@field pane? integer
---@field text? string
---@field result? any
---@field panes? aio.PaneReport[]
---@field commands? aio.CommandReport[]
---@field tabs? aio.TabReport[]
---@field workspaces? aio.WorkspaceReport[]
---@field process? aio.ProcessReport
---@field prompt? integer
---@field view? aio.ViewReport

---@class aio.PaneReport
---@field id integer
---@field name? string
---@field title? string
---@field process? string
---@field workspace integer
---@field workspace_name? string
---@field tab integer
---@field focused boolean
---@field status string
---@field exit_code integer
---@field directory? string
---@field pid? integer
---@field tab_name? string
---@field rect? aio.Rect
---@field grid? aio.Grid

---@class aio.CommandReport
---@field name string
---@field title string
---@field usage string
---@field summary string
---@field options aio.OptionReport[]

---@class aio.TabReport
---@field workspace integer
---@field workspace_name? string
---@field tab integer
---@field name? string
---@field panes integer
---@field selected boolean
---@field focused boolean

---@class aio.WorkspaceReport
---@field id integer
---@field name? string
---@field window boolean
---@field visible boolean
---@field tabs integer
---@field focused boolean

---@class aio.ProcessReport
---@field name string
---@field pid integer
---@field path? string
---@field directory? string
---@field ancestors aio.ProcessAncestor[]

---@class aio.ViewReport
---@field revision integer
---@field windows aio.ViewWindowReport[]
---@field workspaces aio.ViewWorkspaceReport[]
---@field panes aio.PaneReport[]

---@class aio.Rect
---@field x integer
---@field y integer
---@field width integer
---@field height integer

---@class aio.Grid
---@field columns integer
---@field rows integer

---@class aio.OptionReport
---@field option string
---@field description string
---@field default string
---@field example string
---@field required boolean

---@class aio.ProcessAncestor
---@field name string
---@field pid integer

---@class aio.ViewWindowReport
---@field id integer
---@field focused boolean
---@field workspace integer
---@field linked boolean

---@class aio.ViewWorkspaceReport
---@field id integer
---@field name string
---@field selected boolean
---@field tabs aio.ViewTabReport[]

---@class aio.ViewTabReport
---@field id integer
---@field index integer
---@field name string
---@field title string
---@field group integer
---@field selected boolean
---@field focused_pane integer
---@field view string
---@field nodes aio.ViewNodeReport[]
---@field root integer
---@field floats aio.ViewFloatReport[]

---@class aio.ViewNodeReport
---@field pane integer
---@field split? string
---@field ratio number
---@field first integer
---@field second integer

---@class aio.ViewFloatReport
---@field bounds number[]
---@field cells? integer[]
---@field stack integer
---@field minimized boolean
---@field root integer

-- Event fields --------------------------------------------------------------------------------

---The name of an event aio.on and aio.wait take.
---@alias aio.EventName
---| "pane.created"
---| "pane.closed"
---| "pane.exited"
---| "pane.focused"
---| "pane.title_changed"
---| "pane.cwd_changed"
---| "pane.bell"
---| "pane.status_changed"
---| "pane.notification"
---| "pane.resized"
---| "pane.process_changed"
---| "tab.created"
---| "tab.closed"
---| "tab.selected"
---| "tab.renamed"
---| "workspace.created"
---| "workspace.deleted"
---| "workspace.selected"
---| "workspace.renamed"
---| "window.created"
---| "window.closed"
---| "window.focused"
---| "layout.changed"
---| "settings.reloaded"
---| "settings.changed"
---| "prompt.closed"
---| "app.quitting"

---The fields of pane.created.
---@class aio.event.PaneCreated
---@field type "pane.created"
---@field pane integer
---@field tab integer
---@field workspace integer

---The fields of pane.closed.
---@class aio.event.PaneClosed
---@field type "pane.closed"
---@field pane integer
---@field exit_code? integer

---The fields of pane.exited.
---@class aio.event.PaneExited
---@field type "pane.exited"
---@field pane integer
---@field exit_code integer

---The fields of pane.focused.
---@class aio.event.PaneFocused
---@field type "pane.focused"
---@field pane integer
---@field previous integer

---The fields of pane.title_changed.
---@class aio.event.PaneTitleChanged
---@field type "pane.title_changed"
---@field pane integer
---@field title string

---The fields of pane.cwd_changed.
---@class aio.event.PaneCwdChanged
---@field type "pane.cwd_changed"
---@field pane integer
---@field cwd string

---The fields of pane.bell.
---@class aio.event.PaneBell
---@field type "pane.bell"
---@field pane integer

---The fields of pane.status_changed.
---@class aio.event.PaneStatusChanged
---@field type "pane.status_changed"
---@field pane integer
---@field status string
---@field program string

---The fields of pane.notification.
---@class aio.event.PaneNotification
---@field type "pane.notification"
---@field pane integer
---@field title string
---@field body string

---The fields of pane.resized.
---@class aio.event.PaneResized
---@field type "pane.resized"
---@field pane integer
---@field cols integer
---@field rows integer

---The fields of pane.process_changed.
---@class aio.event.PaneProcessChanged
---@field type "pane.process_changed"
---@field pane integer
---@field process string
---@field pid integer

---The fields of tab.created.
---@class aio.event.TabCreated
---@field type "tab.created"
---@field tab integer
---@field workspace integer

---The fields of tab.closed.
---@class aio.event.TabClosed
---@field type "tab.closed"
---@field tab integer
---@field workspace integer

---The fields of tab.selected.
---@class aio.event.TabSelected
---@field type "tab.selected"
---@field tab integer
---@field workspace integer

---The fields of tab.renamed.
---@class aio.event.TabRenamed
---@field type "tab.renamed"
---@field tab integer
---@field workspace integer
---@field name string

---The fields of workspace.created.
---@class aio.event.WorkspaceCreated
---@field type "workspace.created"
---@field workspace integer

---The fields of workspace.deleted.
---@class aio.event.WorkspaceDeleted
---@field type "workspace.deleted"
---@field workspace integer

---The fields of workspace.selected.
---@class aio.event.WorkspaceSelected
---@field type "workspace.selected"
---@field workspace integer

---The fields of workspace.renamed.
---@class aio.event.WorkspaceRenamed
---@field type "workspace.renamed"
---@field workspace integer
---@field name string

---The fields of window.created.
---@class aio.event.WindowCreated
---@field type "window.created"
---@field window integer

---The fields of window.closed.
---@class aio.event.WindowClosed
---@field type "window.closed"
---@field window integer

---The fields of window.focused.
---@class aio.event.WindowFocused
---@field type "window.focused"
---@field window integer

---The fields of layout.changed.
---@class aio.event.LayoutChanged
---@field type "layout.changed"
---@field revision integer

---The fields of settings.reloaded.
---@class aio.event.SettingsReloaded
---@field type "settings.reloaded"

---The fields of settings.changed.
---@class aio.event.SettingsChanged
---@field type "settings.changed"
---@field key string
---@field value string

---The fields of prompt.closed.
---@class aio.event.PromptClosed
---@field type "prompt.closed"
---@field prompt integer
---@field cancelled boolean
---@field index? integer
---@field text? string

---The fields of app.quitting.
---@class aio.event.AppQuitting
---@field type "app.quitting"

-- Command functions ---------------------------------------------------------------------------

---The app.* commands.
aio.app = {}

---The fields of app.build_info.
---@class aio.fields.app.build_info
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Show build info
---@param fields? aio.fields.app.build_info
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.app.build_info(fields) end

---The fields of app.command_palette.
---@class aio.fields.app.command_palette
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Show everything palette
---@param fields? aio.fields.app.command_palette
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.app.command_palette(fields) end

---The fields of app.commands.
---@class aio.fields.app.commands
---@field text? string a command to describe; default: none (lists every command)

---List commands
---
---Lists every command, or describes one; aio commands and aio help ask it.
---@param fields? aio.fields.app.commands
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.app.commands(fields) end

---The fields of app.events.
---@class aio.fields.app.events
---@field text? string space-separated event names; default: all events

---Subscribe to application events
---
---Streams application events on this control connection until it closes; aio events subscribes.
---@param fields? aio.fields.app.events
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.app.events(fields) end

---The fields of app.hide_to_tray.
---@class aio.fields.app.hide_to_tray
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Hide to tray
---@param fields? aio.fields.app.hide_to_tray
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.app.hide_to_tray(fields) end

---The fields of app.input.
---@class aio.fields.app.input
---@field text? string the command's text; default: none
---@field title string the notification's title; required

---Ask for text
---
---Opens a single-line text dialog with the optional default selected and returns a prompt id immediately. The prompt.closed event reports text (including empty text), or cancelled.
---@param fields aio.fields.app.input
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.app.input(fields) end

---The fields of app.install_agent_hooks.
---@class aio.fields.app.install_agent_hooks
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Install agent session hooks
---@param fields? aio.fields.app.install_agent_hooks
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.app.install_agent_hooks(fields) end

---The fields of app.install_turn_hooks.
---@class aio.fields.app.install_turn_hooks
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Install agent turn hooks
---
---Adds AIODev's turn hooks to Claude Code and Codex so Agent changes knows exactly when turns start and which files agent tools edit.
---@param fields? aio.fields.app.install_turn_hooks
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.app.install_turn_hooks(fields) end

---The fields of app.lua_types.
---@class aio.fields.app.lua_types

---Show Lua type definitions
---
---Prints the aio API's LuaCATS definitions for lua-language-server: the built-in commands, events and replies, and the actions init.lua declares; aio types writes them beside init.lua.
---@param fields? aio.fields.app.lua_types
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.app.lua_types(fields) end

---The fields of app.notify.
---@class aio.fields.app.notify
---@field text string the command's text; required
---@field title? string the notification's title; default: AIODev

---Show notification
---
---Shows an Info notice; with no visible window, also uses the notification preferences for done programs.
---@param fields aio.fields.app.notify
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.app.notify(fields) end

---The fields of app.palette_commands.
---@class aio.fields.app.palette_commands
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Show palette: commands
---@param fields? aio.fields.app.palette_commands
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.app.palette_commands(fields) end

---The fields of app.palette_settings.
---@class aio.fields.app.palette_settings
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Show palette: settings
---@param fields? aio.fields.app.palette_settings
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.app.palette_settings(fields) end

---The fields of app.palette_tabs.
---@class aio.fields.app.palette_tabs
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Show palette: tabs
---@param fields? aio.fields.app.palette_tabs
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.app.palette_tabs(fields) end

---The fields of app.palette_workspaces.
---@class aio.fields.app.palette_workspaces
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Show palette: workspaces
---@param fields? aio.fields.app.palette_workspaces
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.app.palette_workspaces(fields) end

---The fields of app.quit.
---@class aio.fields.app.quit
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Quit AIODev
---@param fields? aio.fields.app.quit
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.app.quit(fields) end

---The fields of app.restart.
---@class aio.fields.app.restart

---Restart AIODev
---@param fields? aio.fields.app.restart
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.app.restart(fields) end

---The fields of app.select.
---@class aio.fields.app.select
---@field title string the notification's title; required
---@field items string[]|string the selectable strings as a JSON array; required
---@field details? string[]|string secondary text for each item as a JSON array of strings; default: none

---Ask for a selection
---
---Opens a filtered list and returns a prompt id immediately. The prompt.closed event reports the original 1-based index, or cancelled when dismissed. Details must have one string per item.
---@param fields aio.fields.app.select
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.app.select(fields) end

---The fields of app.update.
---@class aio.fields.app.update
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Update AIODev
---@param fields? aio.fields.app.update
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.app.update(fields) end

---The fields of app.version.
---@class aio.fields.app.version

---Show AIODev's build
---
---Prints AIODev's build; aio version shows it beside aio's own.
---@param fields? aio.fields.app.version
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.app.version(fields) end

---The fields of app.view.
---@class aio.fields.app.view

---Show layout view
---
---Prints one JSON document describing all windows, workspaces, tab trees, floats and panes.
---@param fields? aio.fields.app.view
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.app.view(fields) end

---The edit.* commands.
aio.edit = {}

---The fields of edit.clipboard_read.
---@class aio.fields.edit.clipboard_read

---Read clipboard
---
---Returns the clipboard's text.
---@param fields? aio.fields.edit.clipboard_read
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.edit.clipboard_read(fields) end

---The fields of edit.clipboard_write.
---@class aio.fields.edit.clipboard_write
---@field text string the command's text; required

---Write clipboard
---
---Replaces the clipboard's text; empty text clears it.
---@param fields aio.fields.edit.clipboard_write
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.edit.clipboard_write(fields) end

---The fields of edit.copy.
---@class aio.fields.edit.copy
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Copy
---@param fields? aio.fields.edit.copy
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.edit.copy(fields) end

---The fields of edit.paste.
---@class aio.fields.edit.paste
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Paste
---@param fields? aio.fields.edit.paste
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.edit.paste(fields) end

---The fields of edit.select_all.
---@class aio.fields.edit.select_all
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Select all
---@param fields? aio.fields.edit.select_all
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.edit.select_all(fields) end

---The float.* commands.
aio.float = {}

---The fields of float.dock.
---@class aio.fields.float.dock
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev
---@field focus? boolean moves focus to the new pane; default: off (focus stays where it is)

---Dock float
---
---Returns the named float to its tiled slot without changing focus unless --focus.
---@param fields? aio.fields.float.dock
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.float.dock(fields) end

---The fields of float.lower.
---@class aio.fields.float.lower
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev
---@field focus? boolean moves focus to the new pane; default: off (focus stays where it is)

---Lower float
---
---Lowers the named float beneath every other float without changing focus unless --focus.
---@param fields? aio.fields.float.lower
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.float.lower(fields) end

---The fields of float.minimize.
---@class aio.fields.float.minimize
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev
---@field focus? boolean moves focus to the new pane; default: off (focus stays where it is)

---Minimize float
---
---Minimizes the named float; its program keeps running.
---@param fields? aio.fields.float.minimize
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.float.minimize(fields) end

---The fields of float.raise.
---@class aio.fields.float.raise
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev
---@field focus? boolean moves focus to the new pane; default: off (focus stays where it is)

---Raise float
---
---Raises the named float above every other float without changing focus unless --focus.
---@param fields? aio.fields.float.raise
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.float.raise(fields) end

---The fields of float.restore.
---@class aio.fields.float.restore
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev
---@field focus? boolean moves focus to the new pane; default: off (focus stays where it is)

---Restore float
---
---Restores the named float without changing focus unless --focus.
---@param fields? aio.fields.float.restore
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.float.restore(fields) end

---The fields of float.set_bounds.
---@class aio.fields.float.set_bounds
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev
---@field focus? boolean moves focus to the new pane; default: off (focus stays where it is)
---@field bounds number[] the float's position and size in the chosen unit; required
---@field unit? "share"|"cells" the bounds' unit, fractions of the float area or terminal cells; default: share

---Set float bounds
---
---Sets the named float's clamped bounds without changing focus unless --focus.
---@param fields aio.fields.float.set_bounds
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.float.set_bounds(fields) end

---The fields of layout.apply.
---@class aio.fields.layout.apply
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev
---@field focus? boolean shows the new tab and focuses its first pane; default: off (focus stays where it is)
---@field file? string the JSON layout: tab, cwd and either columns or a root split tree, plus optional floats; panes take name, command (an argument array), cwd and profile; at most 1 MiB and 16 panes; a relative path is from aio's working directory; required unless layout is given
---@field layout? table|string the inline JSON layout instead of a file, at most 1 MiB and 16 panes; default: none (give a file or --layout)

---The fields of mode.enter.
---@class aio.fields.mode.enter
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev
---@field name string the declared key mode; required
---@field once? boolean leaves the mode after one completed binding; default: off

---The fields of mode.exit.
---@class aio.fields.mode.exit
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---The fields of mode.exit_all.
---@class aio.fields.mode.exit_all
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---The pane.* commands.
aio.pane = {}

---The fields of pane.agent_changes.
---@class aio.fields.pane.agent_changes
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev
---@field float? boolean opens a separate float; cannot be combined with --direction or --ratio; default: the command's usual placement

---Open agent changes
---
---Opens Agent changes beside the focused pane, for that pane's agent. Each run opens another pane.
---@param fields? aio.fields.pane.agent_changes
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.agent_changes(fields) end

---The fields of pane.arrange.
---@class aio.fields.pane.arrange
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Arrange panes
---@param fields? aio.fields.pane.arrange
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.arrange(fields) end

---The fields of pane.balance.
---@class aio.fields.pane.balance
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Balance all splits
---@param fields? aio.fields.pane.balance
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.balance(fields) end

---The fields of pane.change_shell.
---@class aio.fields.pane.change_shell
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Change pane shell…
---@param fields? aio.fields.pane.change_shell
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.change_shell(fields) end

---The fields of pane.close.
---@class aio.fields.pane.close
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Close pane
---@param fields? aio.fields.pane.close
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.close(fields) end

---The fields of pane.commands.
---@class aio.fields.pane.commands
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Show saved commands
---@param fields? aio.fields.pane.commands
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.commands(fields) end

---The fields of pane.dock_down.
---@class aio.fields.pane.dock_down
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Dock pane to bottom edge
---@param fields? aio.fields.pane.dock_down
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.dock_down(fields) end

---The fields of pane.dock_left.
---@class aio.fields.pane.dock_left
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Dock pane to left edge
---@param fields? aio.fields.pane.dock_left
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.dock_left(fields) end

---The fields of pane.dock_right.
---@class aio.fields.pane.dock_right
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Dock pane to right edge
---@param fields? aio.fields.pane.dock_right
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.dock_right(fields) end

---The fields of pane.dock_up.
---@class aio.fields.pane.dock_up
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Dock pane to top edge
---@param fields? aio.fields.pane.dock_up
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.dock_up(fields) end

---The fields of pane.edit_markdown.
---@class aio.fields.pane.edit_markdown
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Toggle Markdown editing
---
---Edits the focused Markdown pane's file in place, every line but the caret's shown rendered; edits save a moment after typing stops. Run again to read it.
---@param fields? aio.fields.pane.edit_markdown
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.edit_markdown(fields) end

---The fields of pane.fill_window.
---@class aio.fields.pane.fill_window
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Fill window
---@param fields? aio.fields.pane.fill_window
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.fill_window(fields) end

---The fields of pane.float.
---@class aio.fields.pane.float
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Float or dock pane
---@param fields? aio.fields.pane.float
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.float(fields) end

---The fields of pane.focus.
---@class aio.fields.pane.focus
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Focus pane
---
---Focuses the pane and brings its window forward.
---@param fields? aio.fields.pane.focus
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.focus(fields) end

---The fields of pane.focus_back.
---@class aio.fields.pane.focus_back
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Back in pane history
---@param fields? aio.fields.pane.focus_back
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.focus_back(fields) end

---The fields of pane.focus_down.
---@class aio.fields.pane.focus_down
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Focus down
---@param fields? aio.fields.pane.focus_down
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.focus_down(fields) end

---The fields of pane.focus_forward.
---@class aio.fields.pane.focus_forward
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Forward in pane history
---@param fields? aio.fields.pane.focus_forward
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.focus_forward(fields) end

---The fields of pane.focus_left.
---@class aio.fields.pane.focus_left
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Focus left
---@param fields? aio.fields.pane.focus_left
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.focus_left(fields) end

---The fields of pane.focus_next.
---@class aio.fields.pane.focus_next
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Next pane
---@param fields? aio.fields.pane.focus_next
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.focus_next(fields) end

---The fields of pane.focus_previous.
---@class aio.fields.pane.focus_previous
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Previous pane
---@param fields? aio.fields.pane.focus_previous
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.focus_previous(fields) end

---The fields of pane.focus_right.
---@class aio.fields.pane.focus_right
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Focus right
---@param fields? aio.fields.pane.focus_right
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.focus_right(fields) end

---The fields of pane.focus_up.
---@class aio.fields.pane.focus_up
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Focus up
---@param fields? aio.fields.pane.focus_up
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.focus_up(fields) end

---The fields of pane.fullscreen.
---@class aio.fields.pane.fullscreen
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Fullscreen
---@param fields? aio.fields.pane.fullscreen
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.fullscreen(fields) end

---The fields of pane.keep_open.
---@class aio.fields.pane.keep_open
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Toggle keep pane open after exit
---@param fields? aio.fields.pane.keep_open
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.keep_open(fields) end

---The fields of pane.linked_window.
---@class aio.fields.pane.linked_window
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Toggle pane in linked window
---@param fields? aio.fields.pane.linked_window
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.linked_window(fields) end

---The fields of pane.links.
---@class aio.fields.pane.links
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Show links
---@param fields? aio.fields.pane.links
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.links(fields) end

---The fields of pane.list.
---@class aio.fields.pane.list

---List panes
---
---Prints a header row, then a tab-separated line per pane: id, focused, workspace, tab, status, process, title, directory, pid, tab name and grid; empty fields print as -; --json adds each pane's rect.
---@param fields? aio.fields.pane.list
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.list(fields) end

---The fields of pane.minimize_all_floating.
---@class aio.fields.pane.minimize_all_floating
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Minimize or restore all floats
---@param fields? aio.fields.pane.minimize_all_floating
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.minimize_all_floating(fields) end

---The fields of pane.minimize_floating.
---@class aio.fields.pane.minimize_floating
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Minimize or restore float
---@param fields? aio.fields.pane.minimize_floating
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.minimize_floating(fields) end

---The fields of pane.move.
---@class aio.fields.pane.move
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev
---@field direction "left"|"right"|"up"|"down" the side of --beside on which the pane is placed; required
---@field focus? boolean moves focus to the new pane; default: off (focus stays where it is)
---@field beside string|integer the pane beside which to move, in the same tab; required

---Move pane beside another
---
---Moves the named pane beside another pane in the same tab without changing focus unless --focus.
---@param fields aio.fields.pane.move
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.move(fields) end

---The fields of pane.move_down.
---@class aio.fields.pane.move_down
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Move pane down
---@param fields? aio.fields.pane.move_down
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.move_down(fields) end

---The fields of pane.move_left.
---@class aio.fields.pane.move_left
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Move pane left
---@param fields? aio.fields.pane.move_left
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.move_left(fields) end

---The fields of pane.move_new_tab.
---@class aio.fields.pane.move_new_tab
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Move pane to new tab
---@param fields? aio.fields.pane.move_new_tab
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.move_new_tab(fields) end

---The fields of pane.move_new_window.
---@class aio.fields.pane.move_new_window
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Move pane to new window
---@param fields? aio.fields.pane.move_new_window
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.move_new_window(fields) end

---The fields of pane.move_new_workspace.
---@class aio.fields.pane.move_new_workspace
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Move pane to new workspace
---@param fields? aio.fields.pane.move_new_workspace
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.move_new_workspace(fields) end

---The fields of pane.move_right.
---@class aio.fields.pane.move_right
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Move pane right
---@param fields? aio.fields.pane.move_right
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.move_right(fields) end

---The fields of pane.move_tab_1.
---@class aio.fields.pane.move_tab_1
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Move pane to tab 1
---@param fields? aio.fields.pane.move_tab_1
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.move_tab_1(fields) end

---The fields of pane.move_tab_2.
---@class aio.fields.pane.move_tab_2
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Move pane to tab 2
---@param fields? aio.fields.pane.move_tab_2
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.move_tab_2(fields) end

---The fields of pane.move_tab_3.
---@class aio.fields.pane.move_tab_3
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Move pane to tab 3
---@param fields? aio.fields.pane.move_tab_3
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.move_tab_3(fields) end

---The fields of pane.move_tab_4.
---@class aio.fields.pane.move_tab_4
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Move pane to tab 4
---@param fields? aio.fields.pane.move_tab_4
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.move_tab_4(fields) end

---The fields of pane.move_tab_5.
---@class aio.fields.pane.move_tab_5
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Move pane to tab 5
---@param fields? aio.fields.pane.move_tab_5
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.move_tab_5(fields) end

---The fields of pane.move_tab_6.
---@class aio.fields.pane.move_tab_6
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Move pane to tab 6
---@param fields? aio.fields.pane.move_tab_6
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.move_tab_6(fields) end

---The fields of pane.move_tab_7.
---@class aio.fields.pane.move_tab_7
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Move pane to tab 7
---@param fields? aio.fields.pane.move_tab_7
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.move_tab_7(fields) end

---The fields of pane.move_tab_8.
---@class aio.fields.pane.move_tab_8
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Move pane to tab 8
---@param fields? aio.fields.pane.move_tab_8
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.move_tab_8(fields) end

---The fields of pane.move_tab_9.
---@class aio.fields.pane.move_tab_9
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Move pane to tab 9
---@param fields? aio.fields.pane.move_tab_9
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.move_tab_9(fields) end

---The fields of pane.move_up.
---@class aio.fields.pane.move_up
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Move pane up
---@param fields? aio.fields.pane.move_up
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.move_up(fields) end

---The fields of pane.move_workspace.
---@class aio.fields.pane.move_workspace
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev
---@field workspace? string|integer the workspace to act on, by id or exact name; digits are always an id; default: none (the command opens its dialog)

---Move pane to workspace…
---
---Moves the pane to the workspace --workspace names.
---@param fields? aio.fields.pane.move_workspace
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.move_workspace(fields) end

---The fields of pane.new_floating.
---@class aio.fields.pane.new_floating
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---New shell float
---
---Opens a shell float from the keyboard or palette. In scripts use pane.split --float.
---@param fields? aio.fields.pane.new_floating
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.new_floating(fields) end

---The fields of pane.open_markdown.
---@class aio.fields.pane.open_markdown
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev
---@field direction? "left"|"right"|"up"|"down" the side of the pane the new pane opens on; default: right, or a float when pane.markdown_floating is on
---@field ratio? number the new pane's share of the split pane's width (left, right) or height (up, down); default: 0.5 (half)
---@field focus? boolean moves focus to the new pane; default: off (focus stays where it is)
---@field file? string the file to open (a relative path is from aio's working directory); default: none (required)
---@field float? boolean opens a separate float; cannot be combined with --direction or --ratio; default: the command's usual placement

---Open Markdown file…
---
---Shows a Markdown file beside the pane and updates it when the file changes.
---@param fields? aio.fields.pane.open_markdown
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.open_markdown(fields) end

---The fields of pane.open_markdown_default_app.
---@class aio.fields.pane.open_markdown_default_app
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Open Markdown in default app
---
---Opens the focused Markdown pane's file in the program Windows opens Markdown files with.
---@param fields? aio.fields.pane.open_markdown_default_app
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.open_markdown_default_app(fields) end

---The fields of pane.open_web.
---@class aio.fields.pane.open_web
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev
---@field direction? "left"|"right"|"up"|"down" the side of the pane the new pane opens on; default: right, or a float when pane.web_floating is on
---@field ratio? number the new pane's share of the split pane's width (left, right) or height (up, down); default: 0.5 (half)
---@field focus? boolean moves focus to the new pane; default: off (focus stays where it is)
---@field text? string the HTTP, HTTPS, or local file:/// address to open; default: a blank pane
---@field float? boolean opens a separate float; cannot be combined with --direction or --ratio; default: the command's usual placement

---Open web pane
---
---Opens a new embedded web pane beside the pane; with an address it loads it (https is assumed when no scheme is given), else the URL bar is ready for one.
---@param fields? aio.fields.pane.open_web
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.open_web(fields) end

---The fields of pane.process.
---@class aio.fields.pane.process
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Show pane process
---
---Reports the pane's current program, its executable path and directory when available, and its ancestors from nearest parent back to the pane's shell.
---@param fields? aio.fields.pane.process
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.process(fields) end

---The fields of pane.read.
---@class aio.fields.pane.read
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev
---@field lines? integer keeps only the last rows (joined lines with --unwrap), 1 to 10000; default: every row read
---@field scrollback? boolean adds the history above the screen, up to the last 10000 rows; a read over about 1 MiB keeps its last whole lines; default: off (the visible screen only)
---@field unwrap? boolean joins rows the terminal soft-wrapped into one line; default: off (one line per row)

---Read pane screen
---
---Prints the pane's visible text; --scrollback adds the history above it and --unwrap joins rows the terminal wrapped.
---@param fields? aio.fields.pane.read
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.read(fields) end

---The fields of pane.rename.
---@class aio.fields.pane.rename
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev
---@field text? string the pane's new name (an empty name returns it to its program's title); default: none (opens the rename box)

---Rename pane…
---
---Names the pane; without text it opens the rename box on the pane.
---@param fields? aio.fields.pane.rename
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.rename(fields) end

---The fields of pane.reopen_closed.
---@class aio.fields.pane.reopen_closed
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Reopen closed pane or tab
---@param fields? aio.fields.pane.reopen_closed
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.reopen_closed(fields) end

---The fields of pane.resize.
---@class aio.fields.pane.resize
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev
---@field direction "left"|"right"|"up"|"down" the direction in which the border moves; required
---@field focus? boolean moves focus to the new pane; default: off (focus stays where it is)
---@field cells integer the number of terminal cells to move the border; required

---Resize pane by cells
---
---Moves the pane's nearest border along the given direction by terminal cells.
---@param fields aio.fields.pane.resize
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.resize(fields) end

---The fields of pane.resize_down.
---@class aio.fields.pane.resize_down
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Resize down
---@param fields? aio.fields.pane.resize_down
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.resize_down(fields) end

---The fields of pane.resize_down_large.
---@class aio.fields.pane.resize_down_large
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Resize down by 50 pixels
---@param fields? aio.fields.pane.resize_down_large
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.resize_down_large(fields) end

---The fields of pane.resize_left.
---@class aio.fields.pane.resize_left
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Resize left
---@param fields? aio.fields.pane.resize_left
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.resize_left(fields) end

---The fields of pane.resize_left_large.
---@class aio.fields.pane.resize_left_large
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Resize left by 50 pixels
---@param fields? aio.fields.pane.resize_left_large
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.resize_left_large(fields) end

---The fields of pane.resize_right.
---@class aio.fields.pane.resize_right
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Resize right
---@param fields? aio.fields.pane.resize_right
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.resize_right(fields) end

---The fields of pane.resize_right_large.
---@class aio.fields.pane.resize_right_large
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Resize right by 50 pixels
---@param fields? aio.fields.pane.resize_right_large
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.resize_right_large(fields) end

---The fields of pane.resize_up.
---@class aio.fields.pane.resize_up
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Resize up
---@param fields? aio.fields.pane.resize_up
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.resize_up(fields) end

---The fields of pane.resize_up_large.
---@class aio.fields.pane.resize_up_large
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Resize up by 50 pixels
---@param fields? aio.fields.pane.resize_up_large
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.resize_up_large(fields) end

---The fields of pane.restart.
---@class aio.fields.pane.restart
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Restart stopped pane
---@param fields? aio.fields.pane.restart
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.restart(fields) end

---The fields of pane.rotate_split.
---@class aio.fields.pane.rotate_split
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Rotate split
---@param fields? aio.fields.pane.rotate_split
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.rotate_split(fields) end

---The fields of pane.send.
---@class aio.fields.pane.send
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev
---@field text? string the text to type; required unless file is given
---@field enter? boolean presses Enter after the text; default: off
---@field file? string types a UTF-8 file's text exactly instead of <text>; one leading BOM is dropped, CR acts as Enter; at most 1 MiB, relative to aio's working directory; default: none (give <text> or --file)

---Send text to pane
---
---Types text into the pane's program as a person at the keyboard would.
---@param fields? aio.fields.pane.send
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.send(fields) end

---The fields of pane.send_keys.
---@class aio.fields.pane.send_keys
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev
---@field keys string|string[] space-separated shortcut chords, or a JSON array of chord strings; required

---Send keys to pane
---
---Sends each chord through the pane's negotiated keyboard protocol. Invalid chords send nothing.
---@param fields aio.fields.pane.send_keys
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.send_keys(fields) end

---The fields of pane.set_ratio.
---@class aio.fields.pane.set_ratio
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev
---@field ratio number the named pane's share of its parent split; required
---@field focus? boolean moves focus to the new pane; default: off (focus stays where it is)

---Set pane share
---
---Sets the pane's share of its parent split.
---@param fields aio.fields.pane.set_ratio
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.set_ratio(fields) end

---The fields of pane.split.
---@class aio.fields.pane.split
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev
---@field direction? "left"|"right"|"up"|"down" the side of the pane the new pane opens on; default: right
---@field ratio? number the new pane's share of the split pane's width (left, right) or height (up, down); default: 0.5 (half)
---@field focus? boolean moves focus to the new pane; default: off (focus stays where it is)
---@field cwd? string the directory the new pane starts in (a relative path is from aio's working directory); default: aio's working directory
---@field name? string names the new pane, not its tab (--pane then accepts the name); default: none (the pane shows its program's title)
---@field profile? string the shell profile the new pane runs, by id; default: the default profile (shell.default_profile)
---@field command? string[] runs this program in the new pane instead of the profile's shell (only .exe names resolve: run .cmd and .ps1 through a shell); default: the profile's shell
---@field command_file? string reads the program and its arguments from a UTF-8 JSON array of strings, program first, so no shell quotes them; at most 64 KiB, relative to aio's working directory; not with --; default: none (the profile's shell)
---@field bounds? number[] the float's position and size in the chosen unit; default: a centered float
---@field unit? "share"|"cells" the bounds' unit, fractions of the float area or terminal cells; default: share
---@field float? boolean opens a separate float; cannot be combined with --direction or --ratio; default: the command's usual placement

---Split pane
---
---Runs a shell or program in a split, or above the tab with --float, and prints its pane id; focus stays where it is unless --focus.
---@param fields? aio.fields.pane.split
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.split(fields) end

---The fields of pane.split_down.
---@class aio.fields.pane.split_down
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Split down
---@param fields? aio.fields.pane.split_down
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.split_down(fields) end

---The fields of pane.split_left.
---@class aio.fields.pane.split_left
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Split left
---@param fields? aio.fields.pane.split_left
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.split_left(fields) end

---The fields of pane.split_right.
---@class aio.fields.pane.split_right
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Split right
---@param fields? aio.fields.pane.split_right
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.split_right(fields) end

---The fields of pane.split_up.
---@class aio.fields.pane.split_up
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Split up
---@param fields? aio.fields.pane.split_up
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.split_up(fields) end

---The fields of pane.status.
---@class aio.fields.pane.status

---Show pane status
---
---Prints the pane's line as pane.list does, without the header; a recently closed pane reports how it ended.
---@param fields? aio.fields.pane.status
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.status(fields) end

---The fields of pane.swap_down.
---@class aio.fields.pane.swap_down
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Swap pane down
---@param fields? aio.fields.pane.swap_down
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.swap_down(fields) end

---The fields of pane.swap_left.
---@class aio.fields.pane.swap_left
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Swap pane left
---@param fields? aio.fields.pane.swap_left
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.swap_left(fields) end

---The fields of pane.swap_next.
---@class aio.fields.pane.swap_next
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Swap with next pane
---@param fields? aio.fields.pane.swap_next
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.swap_next(fields) end

---The fields of pane.swap_previous.
---@class aio.fields.pane.swap_previous
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Swap with previous pane
---@param fields? aio.fields.pane.swap_previous
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.swap_previous(fields) end

---The fields of pane.swap_right.
---@class aio.fields.pane.swap_right
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Swap pane right
---@param fields? aio.fields.pane.swap_right
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.swap_right(fields) end

---The fields of pane.swap_up.
---@class aio.fields.pane.swap_up
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Swap pane up
---@param fields? aio.fields.pane.swap_up
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.swap_up(fields) end

---The fields of pane.toggle_web_navigator.
---@class aio.fields.pane.toggle_web_navigator
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Toggle web pane URL bar
---
---Shows or hides the URL navigator bar below the focused web pane's header.
---@param fields? aio.fields.pane.toggle_web_navigator
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.toggle_web_navigator(fields) end

---The fields of pane.zoom.
---@class aio.fields.pane.zoom
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Zoom pane
---@param fields? aio.fields.pane.zoom
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.pane.zoom(fields) end

---The profile.* commands.
aio.profile = {}

---The fields of profile.open_1.
---@class aio.fields.profile.open_1
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---New tab with profile 1
---@param fields? aio.fields.profile.open_1
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.profile.open_1(fields) end

---The fields of profile.open_2.
---@class aio.fields.profile.open_2
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---New tab with profile 2
---@param fields? aio.fields.profile.open_2
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.profile.open_2(fields) end

---The fields of profile.open_3.
---@class aio.fields.profile.open_3
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---New tab with profile 3
---@param fields? aio.fields.profile.open_3
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.profile.open_3(fields) end

---The fields of profile.open_4.
---@class aio.fields.profile.open_4
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---New tab with profile 4
---@param fields? aio.fields.profile.open_4
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.profile.open_4(fields) end

---The fields of profile.open_5.
---@class aio.fields.profile.open_5
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---New tab with profile 5
---@param fields? aio.fields.profile.open_5
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.profile.open_5(fields) end

---The fields of profile.open_6.
---@class aio.fields.profile.open_6
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---New tab with profile 6
---@param fields? aio.fields.profile.open_6
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.profile.open_6(fields) end

---The fields of profile.open_7.
---@class aio.fields.profile.open_7
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---New tab with profile 7
---@param fields? aio.fields.profile.open_7
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.profile.open_7(fields) end

---The fields of profile.open_8.
---@class aio.fields.profile.open_8
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---New tab with profile 8
---@param fields? aio.fields.profile.open_8
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.profile.open_8(fields) end

---The fields of profile.open_9.
---@class aio.fields.profile.open_9
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---New tab with profile 9
---@param fields? aio.fields.profile.open_9
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.profile.open_9(fields) end

---The fields of settings.change_shortcut.
---@class aio.fields.settings.change_shortcut
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Change shortcut…
---@param fields? aio.fields.settings.change_shortcut
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.settings.change_shortcut(fields) end

---The fields of settings.check_lua.
---@class aio.fields.settings.check_lua
---@field file? string the Lua file to check; default: init.lua beside settings.ini

---Check init.lua
---
---Loads a Lua config file without running any command and prints its path, how many actions, keys and modes it declares, and each problem as file:line: message; fails when there is a problem.
---@param fields? aio.fields.settings.check_lua
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.settings.check_lua(fields) end

---The fields of settings.customize_colors.
---@class aio.fields.settings.customize_colors
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Customize colors…
---@param fields? aio.fields.settings.customize_colors
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.settings.customize_colors(fields) end

---The fields of settings.get.
---@class aio.fields.settings.get
---@field name string the schema setting's key; required

---The fields of settings.lua_path.
---@class aio.fields.settings.lua_path

---Show init.lua path
---
---Prints the absolute path of the init.lua AIODev loads, beside settings.ini, whether or not the file exists; aio types and aio config check ask it for the folder.
---@param fields? aio.fields.settings.lua_path
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.settings.lua_path(fields) end

---The fields of settings.open.
---@class aio.fields.settings.open
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev
---@field float? boolean opens a separate float; cannot be combined with --direction or --ratio; default: the command's usual placement

---Settings
---@param fields? aio.fields.settings.open
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.settings.open(fields) end

---The fields of settings.open_file.
---@class aio.fields.settings.open_file
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Open settings file
---@param fields? aio.fields.settings.open_file
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.settings.open_file(fields) end

---The fields of settings.reload.
---@class aio.fields.settings.reload
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Reload settings
---@param fields? aio.fields.settings.reload
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.settings.reload(fields) end

---The fields of settings.set.
---@class aio.fields.settings.set
---@field name string the schema setting's key; required
---@field text string the command's text; required

---The status.* commands.
aio.status = {}

---The fields of status.dismiss_finished.
---@class aio.fields.status.dismiss_finished
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Dismiss finished Activity items
---@param fields? aio.fields.status.dismiss_finished
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.status.dismiss_finished(fields) end

---The fields of status.inbox.
---@class aio.fields.status.inbox
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Show the Activity inbox
---@param fields? aio.fields.status.inbox
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.status.inbox(fields) end

---The fields of status.next.
---@class aio.fields.status.next
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Next program that needs you
---@param fields? aio.fields.status.next
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.status.next(fields) end

---The fields of status.panel.
---@class aio.fields.status.panel
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Show or hide the Activity panel
---@param fields? aio.fields.status.panel
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.status.panel(fields) end

---The fields of status.panel_next.
---@class aio.fields.status.panel_next
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Next Activity item
---@param fields? aio.fields.status.panel_next
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.status.panel_next(fields) end

---The fields of status.panel_previous.
---@class aio.fields.status.panel_previous
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Previous Activity item
---@param fields? aio.fields.status.panel_previous
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.status.panel_previous(fields) end

---The tab.* commands.
aio.tab = {}

---The fields of tab.close.
---@class aio.fields.tab.close
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Close selected tabs
---@param fields? aio.fields.tab.close
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.tab.close(fields) end

---The fields of tab.close_others.
---@class aio.fields.tab.close_others
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Close other tabs
---@param fields? aio.fields.tab.close_others
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.tab.close_others(fields) end

---The fields of tab.close_right.
---@class aio.fields.tab.close_right
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Close tabs to the right
---@param fields? aio.fields.tab.close_right
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.tab.close_right(fields) end

---The fields of tab.context_menu.
---@class aio.fields.tab.context_menu
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Show tab menu
---@param fields? aio.fields.tab.context_menu
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.tab.context_menu(fields) end

---The fields of tab.duplicate.
---@class aio.fields.tab.duplicate
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Duplicate tab
---@param fields? aio.fields.tab.duplicate
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.tab.duplicate(fields) end

---The fields of tab.group_add.
---@class aio.fields.tab.group_add
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev
---@field text string the command's text; required

---Add tab to group
---@param fields aio.fields.tab.group_add
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.tab.group_add(fields) end

---The fields of tab.group_close.
---@class aio.fields.tab.group_close
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Close tab group
---@param fields? aio.fields.tab.group_close
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.tab.group_close(fields) end

---The fields of tab.group_color.
---@class aio.fields.tab.group_color
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev
---@field text string the command's text; required

---Change tab group color
---@param fields aio.fields.tab.group_color
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.tab.group_color(fields) end

---The fields of tab.group_fold.
---@class aio.fields.tab.group_fold
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Fold or unfold tab group
---@param fields? aio.fields.tab.group_fold
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.tab.group_fold(fields) end

---The fields of tab.group_move_workspace.
---@class aio.fields.tab.group_move_workspace
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev
---@field workspace? string|integer the workspace to act on, by id or exact name; digits are always an id; default: none (the command opens its dialog)

---Move tab group to workspace…
---@param fields? aio.fields.tab.group_move_workspace
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.tab.group_move_workspace(fields) end

---The fields of tab.group_new.
---@class aio.fields.tab.group_new
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev
---@field text? string the command's text; default: none

---Add tab to new group
---@param fields? aio.fields.tab.group_new
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.tab.group_new(fields) end

---The fields of tab.group_new_tab.
---@class aio.fields.tab.group_new_tab
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---New tab in group
---@param fields? aio.fields.tab.group_new_tab
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.tab.group_new_tab(fields) end

---The fields of tab.group_remove.
---@class aio.fields.tab.group_remove
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Remove tab from group
---@param fields? aio.fields.tab.group_remove
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.tab.group_remove(fields) end

---The fields of tab.group_rename.
---@class aio.fields.tab.group_rename
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev
---@field text? string the command's text; default: none

---Rename tab group…
---@param fields? aio.fields.tab.group_rename
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.tab.group_rename(fields) end

---The fields of tab.group_ungroup.
---@class aio.fields.tab.group_ungroup
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Ungroup tabs
---@param fields? aio.fields.tab.group_ungroup
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.tab.group_ungroup(fields) end

---The fields of tab.last.
---@class aio.fields.tab.last
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Select last tab
---@param fields? aio.fields.tab.last
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.tab.last(fields) end

---The fields of tab.list.
---@class aio.fields.tab.list

---List tabs
---
---Prints a header row, then a line per tab in every workspace.
---@param fields? aio.fields.tab.list
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.tab.list(fields) end

---The fields of tab.move_end.
---@class aio.fields.tab.move_end
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Move selected tabs to end
---@param fields? aio.fields.tab.move_end
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.tab.move_end(fields) end

---The fields of tab.move_left.
---@class aio.fields.tab.move_left
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Move tab left
---@param fields? aio.fields.tab.move_left
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.tab.move_left(fields) end

---The fields of tab.move_new_workspace.
---@class aio.fields.tab.move_new_workspace
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Move tab to new workspace
---@param fields? aio.fields.tab.move_new_workspace
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.tab.move_new_workspace(fields) end

---The fields of tab.move_right.
---@class aio.fields.tab.move_right
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Move tab right
---@param fields? aio.fields.tab.move_right
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.tab.move_right(fields) end

---The fields of tab.move_start.
---@class aio.fields.tab.move_start
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Move selected tabs to start
---@param fields? aio.fields.tab.move_start
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.tab.move_start(fields) end

---The fields of tab.move_workspace.
---@class aio.fields.tab.move_workspace
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev
---@field workspace? string|integer the workspace to act on, by id or exact name; digits are always an id; default: none (the command opens its dialog)

---Move tab to workspace…
---
---Moves the pane's tab to the workspace --workspace names.
---@param fields? aio.fields.tab.move_workspace
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.tab.move_workspace(fields) end

---The fields of tab.new.
---@class aio.fields.tab.new
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev
---@field focus? boolean moves focus to the new pane; default: off (focus stays where it is)
---@field cwd? string the directory the new pane starts in (a relative path is from aio's working directory); default: aio's working directory
---@field name? string names the new pane, not its tab (--pane then accepts the name); default: none (the pane shows its program's title)
---@field profile? string the shell profile the new pane runs, by id; default: the default profile (shell.default_profile)
---@field command? string[] runs this program in the new pane instead of the profile's shell (only .exe names resolve: run .cmd and .ps1 through a shell); default: the profile's shell
---@field tab_name? string names the new tab (--name names its pane); default: none (the tab shows its pane's title)
---@field command_file? string reads the program and its arguments from a UTF-8 JSON array of strings, program first, so no shell quotes them; at most 64 KiB, relative to aio's working directory; not with --; default: none (the profile's shell)

---New tab
---
---Opens a tab in the pane's workspace running the profile's shell or a program and prints the new pane's id; focus stays where it is unless --focus.
---@param fields? aio.fields.tab.new
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.tab.new(fields) end

---The fields of tab.next.
---@class aio.fields.tab.next
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Next tab
---@param fields? aio.fields.tab.next
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.tab.next(fields) end

---The fields of tab.previous.
---@class aio.fields.tab.previous
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Previous tab
---@param fields? aio.fields.tab.previous
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.tab.previous(fields) end

---The fields of tab.rename.
---@class aio.fields.tab.rename
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev
---@field text? string the tab's new name (an empty name returns it to its pane's title); default: none (opens the rename box)

---Rename tab…
---
---Names the pane's tab; without text it opens the rename box.
---@param fields? aio.fields.tab.rename
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.tab.rename(fields) end

---The fields of tab.select_1.
---@class aio.fields.tab.select_1
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Select tab 1
---@param fields? aio.fields.tab.select_1
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.tab.select_1(fields) end

---The fields of tab.select_2.
---@class aio.fields.tab.select_2
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Select tab 2
---@param fields? aio.fields.tab.select_2
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.tab.select_2(fields) end

---The fields of tab.select_3.
---@class aio.fields.tab.select_3
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Select tab 3
---@param fields? aio.fields.tab.select_3
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.tab.select_3(fields) end

---The fields of tab.select_4.
---@class aio.fields.tab.select_4
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Select tab 4
---@param fields? aio.fields.tab.select_4
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.tab.select_4(fields) end

---The fields of tab.select_5.
---@class aio.fields.tab.select_5
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Select tab 5
---@param fields? aio.fields.tab.select_5
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.tab.select_5(fields) end

---The fields of tab.select_6.
---@class aio.fields.tab.select_6
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Select tab 6
---@param fields? aio.fields.tab.select_6
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.tab.select_6(fields) end

---The fields of tab.select_7.
---@class aio.fields.tab.select_7
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Select tab 7
---@param fields? aio.fields.tab.select_7
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.tab.select_7(fields) end

---The fields of tab.select_8.
---@class aio.fields.tab.select_8
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Select tab 8
---@param fields? aio.fields.tab.select_8
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.tab.select_8(fields) end

---The fields of tab.select_9.
---@class aio.fields.tab.select_9
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Select tab 9
---@param fields? aio.fields.tab.select_9
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.tab.select_9(fields) end

---The fields of tab.settings.
---@class aio.fields.tab.settings
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Tab settings
---@param fields? aio.fields.tab.settings
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.tab.settings(fields) end

---The terminal.* commands.
aio.terminal = {}

---The fields of terminal.clear_scrollback.
---@class aio.fields.terminal.clear_scrollback
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Clear scrollback
---@param fields? aio.fields.terminal.clear_scrollback
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.terminal.clear_scrollback(fields) end

---The fields of terminal.find.
---@class aio.fields.terminal.find
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Find
---@param fields? aio.fields.terminal.find
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.terminal.find(fields) end

---The fields of terminal.restart_shell.
---@class aio.fields.terminal.restart_shell
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Restart shell
---@param fields? aio.fields.terminal.restart_shell
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.terminal.restart_shell(fields) end

---The fields of terminal.scroll_page_down.
---@class aio.fields.terminal.scroll_page_down
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Scroll down one page
---@param fields? aio.fields.terminal.scroll_page_down
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.terminal.scroll_page_down(fields) end

---The fields of terminal.scroll_page_up.
---@class aio.fields.terminal.scroll_page_up
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Scroll up one page
---@param fields? aio.fields.terminal.scroll_page_up
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.terminal.scroll_page_up(fields) end

---The fields of terminal.scroll_partial_down.
---@class aio.fields.terminal.scroll_partial_down
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Scroll down configured page length
---@param fields? aio.fields.terminal.scroll_partial_down
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.terminal.scroll_partial_down(fields) end

---The fields of terminal.scroll_partial_up.
---@class aio.fields.terminal.scroll_partial_up
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Scroll up configured page length
---@param fields? aio.fields.terminal.scroll_partial_up
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.terminal.scroll_partial_up(fields) end

---The fields of view.font_size_decrease.
---@class aio.fields.view.font_size_decrease
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---The fields of view.font_size_increase.
---@class aio.fields.view.font_size_increase
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---The fields of view.font_size_reset.
---@class aio.fields.view.font_size_reset
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---The fields of view.tabs_orientation.
---@class aio.fields.view.tabs_orientation
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---The fields of view.tabs_rail.
---@class aio.fields.view.tabs_rail
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---The window.* commands.
aio.window = {}

---The fields of window.new.
---@class aio.fields.window.new
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---New window
---@param fields? aio.fields.window.new
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.window.new(fields) end

---The workspace.* commands.
aio.workspace = {}

---The fields of workspace.change.
---@class aio.fields.workspace.change
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev
---@field workspace? string|integer the workspace to act on, by id or exact name; digits are always an id; default: none (the command opens its dialog)

---Change workspace…
---
---Shows the workspace --workspace names in the pane's window.
---@param fields? aio.fields.workspace.change
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.workspace.change(fields) end

---The fields of workspace.change_icon.
---@class aio.fields.workspace.change_icon
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Change workspace icon…
---@param fields? aio.fields.workspace.change_icon
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.workspace.change_icon(fields) end

---The fields of workspace.delete.
---@class aio.fields.workspace.delete
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Delete workspace…
---@param fields? aio.fields.workspace.delete
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.workspace.delete(fields) end

---The fields of workspace.list.
---@class aio.fields.workspace.list

---List workspaces
---
---Prints a header row, then a line per workspace with its window state, tab count and focus.
---@param fields? aio.fields.workspace.list
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.workspace.list(fields) end

---The fields of workspace.new.
---@class aio.fields.workspace.new
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev
---@field focus? boolean shows the new workspace in the pane's window; default: off (it stays in the background)
---@field cwd? string the directory the new pane starts in (a relative path is from aio's working directory); default: aio's working directory
---@field name? string names the new workspace; default: a generated name
---@field profile? string the shell profile the new pane runs, by id; default: the default profile (shell.default_profile)
---@field command? string[] runs this program in the new pane instead of the profile's shell (only .exe names resolve: run .cmd and .ps1 through a shell); default: the profile's shell
---@field command_file? string reads the program and its arguments from a UTF-8 JSON array of strings, program first, so no shell quotes them; at most 64 KiB, relative to aio's working directory; not with --; default: none (the profile's shell)

---New workspace
---
---Creates a workspace in the background whose tab runs the profile's shell or a program and prints the new pane's id; --focus shows it in the pane's window.
---@param fields? aio.fields.workspace.new
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.workspace.new(fields) end

---The fields of workspace.next.
---@class aio.fields.workspace.next
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Next workspace
---@param fields? aio.fields.workspace.next
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.workspace.next(fields) end

---The fields of workspace.previous.
---@class aio.fields.workspace.previous
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Previous workspace
---@param fields? aio.fields.workspace.previous
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.workspace.previous(fields) end

---The fields of workspace.rename.
---@class aio.fields.workspace.rename
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev
---@field text? string the workspace's new name; default: none (opens the name field; required with --workspace)
---@field workspace? string|integer the workspace to act on, by id or exact name; digits are always an id; default: the pane's workspace

---Rename workspace…
---
---Renames the pane's workspace, or the one --workspace names; without a name it opens the pane's workspace's name field, so --workspace needs a name.
---@param fields? aio.fields.workspace.rename
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.workspace.rename(fields) end

---The fields of workspace.select_1.
---@class aio.fields.workspace.select_1
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Select workspace 1
---@param fields? aio.fields.workspace.select_1
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.workspace.select_1(fields) end

---The fields of workspace.select_2.
---@class aio.fields.workspace.select_2
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Select workspace 2
---@param fields? aio.fields.workspace.select_2
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.workspace.select_2(fields) end

---The fields of workspace.select_3.
---@class aio.fields.workspace.select_3
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Select workspace 3
---@param fields? aio.fields.workspace.select_3
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.workspace.select_3(fields) end

---The fields of workspace.select_4.
---@class aio.fields.workspace.select_4
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Select workspace 4
---@param fields? aio.fields.workspace.select_4
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.workspace.select_4(fields) end

---The fields of workspace.select_5.
---@class aio.fields.workspace.select_5
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Select workspace 5
---@param fields? aio.fields.workspace.select_5
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.workspace.select_5(fields) end

---The fields of workspace.select_6.
---@class aio.fields.workspace.select_6
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Select workspace 6
---@param fields? aio.fields.workspace.select_6
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.workspace.select_6(fields) end

---The fields of workspace.select_7.
---@class aio.fields.workspace.select_7
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Select workspace 7
---@param fields? aio.fields.workspace.select_7
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.workspace.select_7(fields) end

---The fields of workspace.select_8.
---@class aio.fields.workspace.select_8
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Select workspace 8
---@param fields? aio.fields.workspace.select_8
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.workspace.select_8(fields) end

---The fields of workspace.select_9.
---@class aio.fields.workspace.select_9
---@field pane? string|integer the pane to act on: a pane id, a pane name, here or focused; default: here (the pane aio runs in), or the focused pane outside AIODev

---Select workspace 9
---@param fields? aio.fields.workspace.select_9
---@return aio.Reply? reply
---@return string? message
---@return integer? status
function aio.workspace.select_9(fields) end
