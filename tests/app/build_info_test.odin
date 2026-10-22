package app_test

import app "../../src"
import "aio:commands"
import "aio:ui"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
build_info_registry_dispatch_refreshes_one_owned_notice_without_a_session :: proc(t: ^testing.T) {
	state := app.App{registry = commands.create()}
	defer commands.destroy(&state.registry)
	ui.notices_init(&state.notices)
	defer ui.notices_destroy(&state.notices)
	if !testing.expect_value(t, app.register_actions(&state.registry), commands.Error.None) {return}
	command := commands.find(&state.registry, "app.build_info")
	if !testing.expect(t, command != nil) {return}
	testing.expect_value(t, command.title, "Show Build Info")
	w := app.Window{}
	app.run_action(&state, &w, app.Action(command.id))
	if !testing.expect_value(t, len(state.notices.items), 1) {return}
	notice := state.notices.items[0]
	testing.expect_value(t, notice.kind, ui.Notice_Kind.Info)
	testing.expect_value(t, notice.text, "AIODev | Revision: " + app.AIO_BUILD_ID + " | Build: " + app.AIO_BUILD_KIND)
	testing.expect(t, strings.contains(notice.text, app.AIO_BUILD_ID))
	testing.expect(t, !notice.sticky && time.tick_diff(time.tick_now(), notice.expires) > 0)
	app.run_action(&state, &w, app.Action(command.id))
	testing.expect_value(t, len(state.notices.items), 1)
	testing.expect_value(t, state.notices.items[0].key, notice.key)
	testing.expect(t, time.tick_diff(notice.expires, state.notices.items[0].expires) >= 0)
}
