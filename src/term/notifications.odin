package term

import "aio:ghostty"
import "core:strings"
import "core:sync"

Notification :: struct {
	title, body: string,
}

// This frozen libghostty ABI carries strings borrowed only for the duration of its callback.
@(private)
Notification_Wire :: struct {
	title, body: ghostty.String,
}

@(private)
on_notification :: proc "c" (terminal: ghostty.Terminal, userdata: rawptr, notification: ^Notification_Wire) {
	s := (^Session)(userdata)
	if !sync.atomic_load(&s.notifications_wanted) {return}
	context = s.callback_context
	title, title_error := strings.clone(string(notification.title.ptr[:notification.title.len]), s.allocator)
	if title_error != nil {return}
	body, body_error := strings.clone(string(notification.body.ptr[:notification.body.len]), s.allocator)
	if body_error != nil {delete(title, s.allocator); return}
	if _, err := append(&s.notifications, Notification{title, body}); err != nil {
		delete(title, s.allocator)
		delete(body, s.allocator)
		return
	}
	sync.atomic_store(&s.notifications_ready, true)
}

// Interest is atomic because the terminal reader can receive OSCs between app ticks.
notifications_interest :: proc(s: ^Session, wanted: bool) {
	sync.atomic_store(&s.notifications_wanted, wanted)
}

// Transfers the arrived notifications to the caller; destroy_notifications releases their storage.
take_notifications :: proc(s: ^Session) -> [dynamic]Notification {
	if !sync.atomic_load(&s.notifications_ready) {return nil}
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	result := s.notifications
	s.notifications = make([dynamic]Notification, s.allocator)
	sync.atomic_store(&s.notifications_ready, false)
	return result
}

destroy_notifications :: proc(list: [dynamic]Notification) {
	for item in list {
		delete(item.title, list.allocator)
		delete(item.body, list.allocator)
	}
	delete(list)
}
