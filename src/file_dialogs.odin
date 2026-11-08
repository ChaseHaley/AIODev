package main

import "aio:input"
import "aio:layout"
import "aio:platform"

// A file dialog the app is waiting on, and the window it was opened from. The app holds one or none
// per purpose. The tick acts on a dialog's answer and closes it as soon as it is finished.
File_Dialog :: struct {
	pick:   ^platform.File_Pick,
	window: input.Window_Id,
}

// Add File and Add Folder choose for the document scope of `content`.
Document_Pick :: struct {
	using dialog: File_Dialog,
	content:      layout.Content,
}

// The open dialogs: Open Markdown File, and Add File/Add Folder with the pane it is choosing for.
File_Dialogs :: struct {
	markdown: Maybe(File_Dialog),
	document: Maybe(Document_Pick),
}

// Acts on each dialog that has finished: Markdown first, then the document pick.
file_dialogs_tick :: proc(app: ^App) {
	markdown_dialog_tick(app)
	document_dialog_tick(app)
}

file_dialogs_destroy :: proc(app: ^App) {
	markdown_dialog_close(app)
	document_dialog_close(app)
}

// A dialog's answer is for the window it was opened from, so closing that window closes the dialog
// unanswered instead of leaving it on screen without its owner.
file_dialogs_window_closed :: proc(app: ^App, id: input.Window_Id) {
	if dialog, open := app.dialogs.markdown.?; open && dialog.window == id {markdown_dialog_close(app)}
	if dialog, open := app.dialogs.document.?; open && dialog.window == id {document_dialog_close(app)}
}

// Opens what the dialog chose once it closes.
@(private = "file")
markdown_dialog_tick :: proc(app: ^App) {
	dialog, open := app.dialogs.markdown.?
	if !open {return}
	path, finished := platform.file_pick_finished(dialog.pick)
	if !finished {return}
	if w := window_find(app, dialog.window); w != nil && path != "" {
		target_open(app, w, File_Target{path})
	}
	markdown_dialog_close(app)
}

// Collects what the dialog chose once it closes. The pane may have gone in the meantime.
@(private = "file")
document_dialog_tick :: proc(app: ^App) {
	dialog, open := app.dialogs.document.?
	if !open {return}
	path, finished := platform.file_pick_finished(dialog.pick)
	if !finished {return}
	if w := window_find(app, dialog.window); w != nil && path != "" {
		document_pick_chosen(app, w, dialog.content, path)
	}
	document_dialog_close(app)
}

@(private = "file")
markdown_dialog_close :: proc(app: ^App) {
	if dialog, open := app.dialogs.markdown.?; open {platform.file_pick_destroy(dialog.pick)}
	app.dialogs.markdown = nil
}

@(private = "file")
document_dialog_close :: proc(app: ^App) {
	if dialog, open := app.dialogs.document.?; open {platform.file_pick_destroy(dialog.pick)}
	app.dialogs.document = nil
}
