package main

import "aio:glyphs"
import "aio:render"
import "aio:ui"
import "core:strings"
import "core:unicode/utf8"

Workspace_Icon :: struct {
	preset: int,
	emoji:  string,
	tint:   int,
}

Workspace_Icon_Preset :: struct {
	name:  string,
	glyph: rune,
}

WORKSPACE_ICONS :: [?]Workspace_Icon_Preset {
	{"Workspace", '\ue81e'},
	{"Home", '\ue80f'},
	{"Folder", '\ue8b7'},
	{"Work", '\ue821'},
	{"Code", '\ue943'},
	{"Terminal", '\ue756'},
	{"Globe", '\ue774'},
	{"Favorite", '\ue734'},
	{"Music", '\ue8d6'},
	{"Games", '\ue7fc'},
}

workspace_icon_valid :: proc(value: string) -> bool {
	if value == "" || !utf8.valid_string(value) {return false}
	count := 0
	for r in value {
		if r <= ' ' || r == 0x7f {return false}
		count += 1
		if count > 32 {return false}
	}
	return true
}

@(require_results)
workspace_icon_set :: proc(app: ^App, workspace: ^Workspace, preset: int, emoji: string) -> bool {
	if !workspace_registered(app, workspace) {return false}
	if preset < 0 || preset >= len(WORKSPACE_ICONS) {return false}
	if emoji != "" && !workspace_icon_valid(emoji) {return false}
	owned, err := strings.clone(emoji)
	if err != nil {return false}
	delete(workspace.icon.emoji)
	workspace.icon = {preset = preset, emoji = owned, tint = workspace.icon.tint}
	mark_all_dirty(app)
	return true
}

workspace_icon_draw :: proc(
	w: ^Window,
	icon: Workspace_Icon,
	area: render.Rect,
	color: render.Color,
) -> glyphs.Result {
	if icon.emoji != "" {
		return ui.draw_cluster_centered(&w.ui_text, &w.list, icon.emoji, area, color, 18 * w.scale)
	}
	tint := workspace_icon_tint(icon.tint, color)
	@(static, rodata)
	presets := WORKSPACE_ICONS
	preset := presets[clamp(icon.preset, 0, len(presets) - 1)]
	if !w.ui_text.has_icons {
		return ui.draw_glyph_centered(&w.ui_text, &w.list, '◇', area, tint)
	}
	return ui.draw_icon(&w.ui_text, &w.list, preset.glyph, area, tint, 0.9)
}
