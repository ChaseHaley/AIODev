package main

import "aio:ui"

AIO_BUILD_ID :: #config(AIO_BUILD_ID, "unknown")
// build.ps1 names every build it makes; a direct odin build, such as a test run, is development.
AIO_BUILD_KIND :: #config(AIO_BUILD_KIND, "development")
BUILD_INFO_TEXT :: "AIODev | Revision: " + AIO_BUILD_ID + " | Build: " + AIO_BUILD_KIND

// Shown as long as an error, long enough to read and copy the revision.
show_build_info :: proc(app: ^App) {
	ui.notices_put(&app.notices, u32(Notice_Key.Build_Info), .Info, BUILD_INFO_TEXT, ERROR_NOTICE_DURATION)
	mark_all_dirty(app)
}
