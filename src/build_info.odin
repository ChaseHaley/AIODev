package main

import "aio:ui"
import "core:time"

AIO_BUILD_ID :: #config(AIO_BUILD_ID, "unknown")
AIO_BUILD_KIND :: #config(AIO_BUILD_KIND, "development")
BUILD_INFO_TEXT :: "AIODev | Revision: " + AIO_BUILD_ID + " | Build: " + AIO_BUILD_KIND

show_build_info :: proc(app: ^App) {
	ui.notices_put(&app.notices, u32(Notice_Key.Build_Info), .Info, BUILD_INFO_TEXT, 12 * time.Second)
	mark_all_dirty(app)
}
