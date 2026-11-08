package main

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

// Whether every field of `icon` names something drawable: a listed preset, an empty or valid emoji and a
// listed tint. Callers checking one part leave the others zero, which is always valid.
workspace_icon_valid_value :: proc(icon: Workspace_Icon) -> bool {
	if icon.preset < 0 || icon.preset >= len(WORKSPACE_ICONS) {return false}
	if icon.emoji != "" && !workspace_icon_valid(icon.emoji) {return false}
	return icon.tint >= 0 && icon.tint < len(WORKSPACE_ICON_COLORS)
}

@(require_results)
workspace_icon_set :: proc(app: ^App, workspace: ^Workspace, preset: int, emoji: string) -> bool {
	if !workspace_registered(app, workspace) {return false}
	if !workspace_icon_valid_value({preset = preset, emoji = emoji}) {return false}
	owned, err := strings.clone(emoji)
	if err != nil {return false}
	delete(workspace.icon.emoji)
	workspace.icon = {preset = preset, emoji = owned, tint = workspace.icon.tint}
	workspace_mutation_finish(app, workspace, {.Appearance})
	return true
}

workspace_icon_draw :: proc(
	w: ^Window,
	icon: Workspace_Icon,
	area: render.Rect,
	color: render.Color,
) -> render.Build_Status {
	if icon.emoji != "" {
		return ui.draw_cluster_centered(&w.ui_text, &w.list, icon.emoji, area, color, area.height)
	}
	tint := workspace_icon_tint(icon.tint, color)
	@(static, rodata)
	presets := WORKSPACE_ICONS
	preset := presets[clamp(icon.preset, 0, len(presets) - 1)]
	if !w.ui_text.has_icons {
		return ui.draw_glyph_centered(&w.ui_text, &w.list, '◇', area, tint)
	}
	// Segoe Fluent Icons draw a glyph as wide as its em, so a font as tall as the box makes the glyph
	// fill it like every other 16 DIP leading icon.
	return ui.draw_icon(&w.ui_text, &w.list, preset.glyph, area, tint, area.height)
}
