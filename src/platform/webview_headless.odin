package platform

@(require) import "aio:input"

when AIO_HEADLESS {
	webview_supported :: proc() -> bool {
		return false
	}

	window_reclaim_focus :: proc(p: ^Platform, id: input.Window_Id) {}

	@(require_results)
	webview_host_create :: proc(
		p: ^Platform,
		id: input.Window_Id,
		d3d_device, dxgi_factory: rawptr,
	) -> (
		Webview_Host,
		bool,
	) {
		return nil, false
	}

	webview_host_destroy :: proc(host: Webview_Host) {}

	@(require_results)
	webview_host_overlay_begin :: proc(host: Webview_Host, layer, width, height: i32) -> rawptr {
		return nil
	}

	webview_host_overlay_present :: proc(host: Webview_Host, layer: i32) {}
	webview_host_overlay_hide :: proc(host: Webview_Host, layer: i32) {}
	webview_host_commit :: proc(host: Webview_Host) {}

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
		return nil, false
	}

	webview_env_destroy :: proc(env: Webview_Env) {}

	@(require_results)
	webview_create :: proc(
		env: Webview_Env,
		host: Webview_Host,
		pane_id: u32,
		initial_url: string,
		bg_argb: u32,
	) -> Webview {
		return nil
	}

	webview_destroy :: proc(view: Webview) {}
	webview_detach_host :: proc(p: ^Platform, view: Webview) {}

	webview_set_placement :: proc(
		view: Webview,
		host: Webview_Host,
		visible, floating: bool,
		vis_x, vis_y, vis_w, vis_h: i32,
		clip_l, clip_t, clip_r, clip_b: f32,
		bounds_w, bounds_h: i32,
		radius_bl, radius_br, raster_scale: f32,
	) {}

	webview_set_bg :: proc(view: Webview, bg_argb: u32) {}
	webview_navigate :: proc(view: Webview, url: string) {}
	webview_go_back :: proc(view: Webview) {}
	webview_go_forward :: proc(view: Webview) {}
	webview_reload :: proc(view: Webview) {}
	webview_stop :: proc(view: Webview) {}

	webview_mouse :: proc(
		view: Webview,
		kind: Webview_Mouse_Kind,
		buttons: input.Mouse_Buttons,
		modifiers: input.Modifiers,
		mouse_data: u32,
		local_x, local_y: i32,
	) {}

	webview_focus :: proc(view: Webview) {}
	webview_parent_moved :: proc(view: Webview) {}

	@(require_results)
	webview_poll :: proc(view: Webview) -> Webview_Snapshot {
		return {}
	}

	webview_clear_new_window :: proc(view: Webview) {}

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
		return {}, false
	}
}
