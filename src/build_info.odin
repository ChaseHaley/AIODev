package main

import "aio:ui"
import "core:time"

AIO_BUILD_ID :: #config(AIO_BUILD_ID, "unknown")
AIO_BUILD_KIND :: #config(AIO_BUILD_KIND, "development")
BUILD_INFO_TEXT :: "AIODev | Revision: " + AIO_BUILD_ID + " | Build: " + AIO_BUILD_KIND

show_build_info :: proc(app: ^App) {
	key := u32(Notice_Key.Build_Info)
	duration := 12 * time.Second
	ui.notices_put(&app.notices, key, .Info, BUILD_INFO_TEXT, duration, app.animations, time.tick_now())
	mark_all_dirty(app)
}
