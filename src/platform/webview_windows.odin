package platform

@(require) import "aio:input"
@(require) import "core:log"
@(require) import w "core:sys/windows"

when !AIO_HEADLESS {
	foreign import webview_native {
		"../../build/native/webview.lib",
		"../../.deps/webview2/pkg/build/native/x64/WebView2LoaderStatic.lib",
		"system:dcomp.lib",
		"system:version.lib",
		"system:advapi32.lib",
		"system:shell32.lib",
		"system:user32.lib",
	}

	@(private = "file")
	C_Webview_Snapshot :: struct {
		url:                [^]u8,
		url_len:            i32,
		title:              [^]u8,
		title_len:          i32,
		new_window_url:     [^]u8,
		new_window_url_len: i32,
		cursor_id:          u32,
		ready:              u8,
		failed:             u8,
		loading:            u8,
		can_back:           u8,
		can_forward:        u8,
		focused:            u8,
		dirty:              u8,
	}

	@(default_calling_convention = "c")
	foreign webview_native {
		aio_webview_host_create :: proc(
			hwnd: w.HWND, d3d_device, dxgi_factory: rawptr, out_host: ^rawptr,
		) -> i32 ---
		aio_webview_host_destroy :: proc(host: rawptr) ---
		aio_webview_host_overlay_begin :: proc(host: rawptr, layer, width, height: i32) -> rawptr ---
		aio_webview_host_overlay_present :: proc(host: rawptr, layer: i32) ---
		aio_webview_host_overlay_hide :: proc(host: rawptr, layer: i32) ---
		aio_webview_host_commit :: proc(host: rawptr) ---

		aio_webview_env_create :: proc(
			user_data_dir: cstring16,
			wake_hwnd: w.HWND,
			wake_msg: u32,
			accel_cb: Webview_Accel_Proc,
			accel_user: rawptr,
			out_env: ^rawptr,
		) -> i32 ---
		aio_webview_env_destroy :: proc(env: rawptr) ---

		aio_webview_create :: proc(
			env, host: rawptr,
			pane_id: u32,
			initial_url: cstring16,
			bg_argb: u32,
		) -> rawptr ---
		aio_webview_destroy :: proc(view: rawptr) ---
		aio_webview_detach_host :: proc(view: rawptr, fallback_hwnd: w.HWND) ---
		aio_webview_set_placement :: proc(
			view, host: rawptr,
			visible, floating: i32,
			vis_x, vis_y, vis_w, vis_h: i32,
			clip_l, clip_t, clip_r, clip_b: f32,
			bounds_w, bounds_h: i32,
			radius_bl, radius_br, raster_scale: f32,
		) ---
		aio_webview_set_bg :: proc(view: rawptr, bg_argb: u32) ---
		aio_webview_navigate :: proc(view: rawptr, url: cstring16) ---
		aio_webview_go_back :: proc(view: rawptr) ---
		aio_webview_go_forward :: proc(view: rawptr) ---
		aio_webview_reload :: proc(view: rawptr) ---
		aio_webview_stop :: proc(view: rawptr) ---
		aio_webview_mouse :: proc(
			view: rawptr,
			kind: i32,
			virtual_keys, mouse_data: u32,
			local_x, local_y: i32,
		) ---
		aio_webview_focus :: proc(view: rawptr) ---
		aio_webview_parent_moved :: proc(view: rawptr) ---
		aio_webview_poll :: proc(view: rawptr, out: ^C_Webview_Snapshot) ---
		aio_webview_clear_new_window :: proc(view: rawptr) ---
	}

	webview_supported :: proc() -> bool {
		return true
	}

	// Returns Win32 keyboard focus to `id`'s top-level window when an embedded webview holds it.
	window_reclaim_focus :: proc(p: ^Platform, id: input.Window_Id) {
		window := find_window(p, id)
		if window == nil || window.hwnd == nil {return}
		if window.child_focused {
			window.child_focused = false
			w.SetFocus(window.hwnd)
		}
	}

	@(require_results)
	webview_host_create :: proc(
		p: ^Platform,
		id: input.Window_Id,
		d3d_device, dxgi_factory: rawptr,
	) -> (
		Webview_Host,
		bool,
	) {
		window := find_window(p, id)
		if window == nil || window.hwnd == nil {return nil, false}
		host: rawptr
		hr := aio_webview_host_create(window.hwnd, d3d_device, dxgi_factory, &host)
		if hr < 0 || host == nil {
			log.errorf("webview: creating DirectComposition host failed: HRESULT 0x%x", u32(hr))
			return nil, false
		}
		return Webview_Host(host), true
	}

	webview_host_destroy :: proc(host: Webview_Host) {
		if host != nil {aio_webview_host_destroy(rawptr(host))}
	}

	@(require_results)
	webview_host_overlay_begin :: proc(host: Webview_Host, layer, width, height: i32) -> rawptr {
		if host == nil {return nil}
		return aio_webview_host_overlay_begin(rawptr(host), layer, width, height)
	}

	webview_host_overlay_present :: proc(host: Webview_Host, layer: i32) {
		if host != nil {aio_webview_host_overlay_present(rawptr(host), layer)}
	}

	webview_host_overlay_hide :: proc(host: Webview_Host, layer: i32) {
		if host != nil {aio_webview_host_overlay_hide(rawptr(host), layer)}
	}

	webview_host_commit :: proc(host: Webview_Host) {
		if host != nil {aio_webview_host_commit(rawptr(host))}
	}

	@(require_results)
	webview_env_create :: proc(
		p: ^Platform,
		user_data_dir: string,
		accel_cb: Webview_Accel_Proc,
		accel_user: rawptr,
	) -> (
		Webview_Env,
		bool,
	) {
		if p == nil || p.host.hwnd == nil {return nil, false}
		dir_w: cstring16
		if user_data_dir != "" {
			dir_w = w.utf8_to_wstring(user_data_dir, context.temp_allocator)
		}
		env: rawptr
		hr := aio_webview_env_create(dir_w, p.host.hwnd, WEBVIEW_MESSAGE, accel_cb, accel_user, &env)
		if hr < 0 || env == nil {
			log.errorf("webview: creating WebView2 environment failed: HRESULT 0x%x", u32(hr))
			return nil, false
		}
		return Webview_Env(env), true
	}

	webview_env_destroy :: proc(env: Webview_Env) {
		if env != nil {aio_webview_env_destroy(rawptr(env))}
	}

	@(require_results)
	webview_create :: proc(
		env: Webview_Env,
		host: Webview_Host,
		pane_id: u32,
		initial_url: string,
		bg_argb: u32,
	) -> Webview {
		if env == nil || host == nil {return nil}
		url_w := initial_url != "" ? w.utf8_to_wstring(initial_url, context.temp_allocator) : nil
		return Webview(aio_webview_create(rawptr(env), rawptr(host), pane_id, url_w, bg_argb))
	}

	webview_destroy :: proc(view: Webview) {
		if view != nil {aio_webview_destroy(rawptr(view))}
	}

	// Parks `view` on the app's persistent host HWND before its current window is destroyed,
	// keeping the WebView2 controller and page state alive across linked-window returns.
	webview_detach_host :: proc(p: ^Platform, view: Webview) {
		if view == nil {return}
		fallback := p != nil ? p.host.hwnd : nil
		aio_webview_detach_host(rawptr(view), fallback)
	}

	webview_set_placement :: proc(
		view: Webview,
		host: Webview_Host,
		visible, floating: bool,
		vis_x, vis_y, vis_w, vis_h: i32,
		clip_l, clip_t, clip_r, clip_b: f32,
		bounds_w, bounds_h: i32,
		radius_bl, radius_br, raster_scale: f32,
	) {
		if view == nil {return}
		aio_webview_set_placement(
			rawptr(view),
			rawptr(host),
			visible ? 1 : 0,
			floating ? 1 : 0,
			vis_x,
			vis_y,
			vis_w,
			vis_h,
			clip_l,
			clip_t,
			clip_r,
			clip_b,
			bounds_w,
			bounds_h,
			radius_bl,
			radius_br,
			raster_scale,
		)
	}

	webview_set_bg :: proc(view: Webview, bg_argb: u32) {
		if view != nil {aio_webview_set_bg(rawptr(view), bg_argb)}
	}

	webview_navigate :: proc(view: Webview, url: string) {
		if view == nil || url == "" {return}
		if url_w := w.utf8_to_wstring(url, context.temp_allocator); url_w != nil {
			aio_webview_navigate(rawptr(view), url_w)
		}
	}

	webview_go_back :: proc(view: Webview) {
		if view != nil {aio_webview_go_back(rawptr(view))}
	}

	webview_go_forward :: proc(view: Webview) {
		if view != nil {aio_webview_go_forward(rawptr(view))}
	}

	webview_reload :: proc(view: Webview) {
		if view != nil {aio_webview_reload(rawptr(view))}
	}

	webview_stop :: proc(view: Webview) {
		if view != nil {aio_webview_stop(rawptr(view))}
	}

	webview_mouse :: proc(
		view: Webview,
		kind: Webview_Mouse_Kind,
		buttons: input.Mouse_Buttons,
		modifiers: input.Modifiers,
		mouse_data: u32,
		local_x, local_y: i32,
	) {
		if view == nil {return}
		vkeys: u32
		if .Left in buttons {vkeys |= 0x0001}
		if .Right in buttons {vkeys |= 0x0002}
		if .Shift in modifiers {vkeys |= 0x0004}
		if .Control in modifiers {vkeys |= 0x0008}
		if .Middle in buttons {vkeys |= 0x0010}
		aio_webview_mouse(rawptr(view), i32(kind), vkeys, mouse_data, local_x, local_y)
	}

	webview_focus :: proc(view: Webview) {
		if view != nil {aio_webview_focus(rawptr(view))}
	}

	webview_parent_moved :: proc(view: Webview) {
		if view != nil {aio_webview_parent_moved(rawptr(view))}
	}

	@(require_results)
	webview_poll :: proc(view: Webview) -> Webview_Snapshot {
		if view == nil {return {}}
		raw: C_Webview_Snapshot
		aio_webview_poll(rawptr(view), &raw)
		new_window_url := ""
		if raw.new_window_url != nil && raw.new_window_url_len > 0 {
			new_window_url = string(raw.new_window_url[:raw.new_window_url_len])
		}
		return {
			url            = raw.url != nil && raw.url_len > 0 ? string(raw.url[:raw.url_len]) : "",
			title          = raw.title != nil && raw.title_len > 0 ? string(raw.title[:raw.title_len]) : "",
			new_window_url = new_window_url,
			cursor         = cursor_from_system_id(raw.cursor_id),
			ready          = raw.ready != 0,
			failed         = raw.failed != 0,
			loading        = raw.loading != 0,
			can_back       = raw.can_back != 0,
			can_forward    = raw.can_forward != 0,
			focused        = raw.focused != 0,
			dirty          = raw.dirty != 0,
		}
	}

	webview_clear_new_window :: proc(view: Webview) {
		if view != nil {aio_webview_clear_new_window(rawptr(view))}
	}

	@(private = "file")
	cursor_from_system_id :: proc(id: u32) -> Cursor_Shape {
		switch id {
		case 32513: // IDC_IBEAM
			return .Text
		case 32649: // IDC_HAND
			return .Hand
		case 32644: // IDC_SIZEWE
			return .Resize_Horizontal
		case 32645: // IDC_SIZENS
			return .Resize_Vertical
		case 32642: // IDC_SIZENWSE
			return .Resize_Northwest_Southeast
		case 32643: // IDC_SIZENESW
			return .Resize_Northeast_Southwest
		case 32646: // IDC_SIZEALL
			return .Resize_All
		}
		return .Arrow
	}

	// Translates a Windows virtual key + lparam from WebView2 AcceleratorKeyPressed into an AIODev Key_Event.
	webview_accel_key_event :: proc(
		p: ^Platform,
		window_id: input.Window_Id,
		vk: u32,
		kind: u32,
		lparam: i32,
	) -> (
		event: input.Key_Event,
		ok: bool,
	) {
		_ = p
		pressed := kind == 0 || kind == 2
		bits := u32(lparam)
		scan := u16((bits >> 16) & 0xff)
		extended := bits & (1 << 24) != 0
		key := key_from_scan_code(scan, extended)
		if key == {} {return {}, false}
		state: [256]u8
		_ = w.GetKeyboardState(cast(^w.BYTE)&state[0])
		unshifted: rune
		if pressed {
			if layout, layout_ok := keyboard_layout(); layout_ok {
				unshifted = unshifted_rune(vk, scan, layout)
			}
		}
		return input.Key_Event {
			window    = window_id,
			key       = key,
			modifiers = modifiers_from_state(state),
			pressed   = pressed,
			repeat    = pressed && (bits & (1 << 30)) != 0,
			unshifted = unshifted,
			native    = {
				vk                = u16(vk),
				scan_code         = scan,
				repeat_count      = u16(bits & 0xffff),
				control_key_state = control_key_state(state, extended),
			},
		}, true
	}
}
