package main

import "aio:cli_protocol"
import "aio:ui"
import "core:fmt"

AIO_BUILD_ID :: cli_protocol.BUILD_ID
AIO_BUILD_KIND :: cli_protocol.BUILD_KIND
BUILD_INFO_TEXT :: "AIODev | Revision: " + AIO_BUILD_ID + " | Build: " + AIO_BUILD_KIND

// Shown as long as an error notice.
show_build_info :: proc(app: ^App) {
	key := u32(Notice_Key.Build_Info)
	duration := ERROR_NOTICE_DURATION
	ui.notices_put(&app.notices, key, .Info, BUILD_INFO_TEXT, duration, app.animations, clock_now(&app.clock))
	mark_all_dirty(app)
}

// AIODev's reply to aio version, such as `AIODev 0.10.0 (4dc71c8, release)`. The text is temporary.
@(require_results)
version_outcome :: proc() -> Outcome {
	build := cli_protocol.build_text(
		cli_protocol.BUILD_VERSION, AIO_BUILD_ID, AIO_BUILD_KIND, context.temp_allocator,
	)
	return {payload = Outcome_Text(fmt.tprintf("%s %s", cli_protocol.APP_NAME, build))}
}
