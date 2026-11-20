#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <dcomp.h>
#include "WebView2.h"

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

namespace {

template <typename T>
class Com_Ptr {
public:
    Com_Ptr() noexcept = default;
    ~Com_Ptr() noexcept { reset(); }
    Com_Ptr(const Com_Ptr &other) noexcept : ptr_(other.ptr_) {
        if (ptr_) ptr_->AddRef();
    }
    Com_Ptr(Com_Ptr &&other) noexcept : ptr_(other.ptr_) { other.ptr_ = nullptr; }
    Com_Ptr &operator=(const Com_Ptr &other) noexcept {
        if (this != &other) {
            reset();
            ptr_ = other.ptr_;
            if (ptr_) ptr_->AddRef();
        }
        return *this;
    }
    Com_Ptr &operator=(Com_Ptr &&other) noexcept {
        if (this != &other) {
            reset();
            ptr_ = other.ptr_;
            other.ptr_ = nullptr;
        }
        return *this;
    }
    void reset() noexcept {
        if (ptr_) {
            ptr_->Release();
            ptr_ = nullptr;
        }
    }
    T *get() const noexcept { return ptr_; }
    T *operator->() const noexcept { return ptr_; }
    explicit operator bool() const noexcept { return ptr_ != nullptr; }
    T **put() noexcept {
        reset();
        return &ptr_;
    }
    void **put_void() noexcept { return reinterpret_cast<void **>(put()); }

private:
    T *ptr_ = nullptr;
};

template <template <typename> class T, typename Fn>
static Com_Ptr<T<Fn>> make_handler(Fn &&fn) {
    Com_Ptr<T<Fn>> ptr;
    *ptr.put() = new T<Fn>(std::forward<Fn>(fn));
    return ptr;
}

// Concrete callback wrappers for the exact WebView2 handler interfaces we register.
#define DEFINE_WV2_HANDLER_2(Name, Iface, A1, A2)                                      \
    template <typename Fn>                                                             \
    class Name final : public Iface {                                                  \
    public:                                                                            \
        explicit Name(Fn fn) : fn_(std::move(fn)) {}                                   \
        HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **object) override {\
            if (!object) return E_POINTER;                                             \
            if (riid == IID_IUnknown || riid == __uuidof(Iface)) {                     \
                *object = static_cast<Iface *>(this);                                  \
                AddRef();                                                              \
                return S_OK;                                                           \
            }                                                                          \
            *object = nullptr;                                                         \
            return E_NOINTERFACE;                                                      \
        }                                                                              \
        ULONG STDMETHODCALLTYPE AddRef() override { return ++refs_; }                  \
        ULONG STDMETHODCALLTYPE Release() override {                                   \
            auto n = --refs_;                                                          \
            if (n == 0) delete this;                                                   \
            return n;                                                                  \
        }                                                                              \
        HRESULT STDMETHODCALLTYPE Invoke(A1 a1, A2 a2) override { return fn_(a1, a2); }\
    private:                                                                           \
        std::atomic<ULONG> refs_{1};                                                   \
        Fn fn_;                                                                        \
    };

DEFINE_WV2_HANDLER_2(Env_Completed_Handler, ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler,
                     HRESULT, ICoreWebView2Environment *)
DEFINE_WV2_HANDLER_2(Comp_Completed_Handler,
                     ICoreWebView2CreateCoreWebView2CompositionControllerCompletedHandler, HRESULT,
                     ICoreWebView2CompositionController *)
DEFINE_WV2_HANDLER_2(Nav_Starting_Handler, ICoreWebView2NavigationStartingEventHandler, ICoreWebView2 *,
                     ICoreWebView2NavigationStartingEventArgs *)
DEFINE_WV2_HANDLER_2(Nav_Completed_Handler, ICoreWebView2NavigationCompletedEventHandler, ICoreWebView2 *,
                     ICoreWebView2NavigationCompletedEventArgs *)
DEFINE_WV2_HANDLER_2(Source_Changed_Handler, ICoreWebView2SourceChangedEventHandler, ICoreWebView2 *,
                     ICoreWebView2SourceChangedEventArgs *)
DEFINE_WV2_HANDLER_2(History_Changed_Handler, ICoreWebView2HistoryChangedEventHandler, ICoreWebView2 *,
                     IUnknown *)
DEFINE_WV2_HANDLER_2(Title_Changed_Handler, ICoreWebView2DocumentTitleChangedEventHandler, ICoreWebView2 *,
                     IUnknown *)
DEFINE_WV2_HANDLER_2(New_Window_Handler, ICoreWebView2NewWindowRequestedEventHandler, ICoreWebView2 *,
                     ICoreWebView2NewWindowRequestedEventArgs *)
DEFINE_WV2_HANDLER_2(Cursor_Changed_Handler, ICoreWebView2CursorChangedEventHandler,
                     ICoreWebView2CompositionController *, IUnknown *)
DEFINE_WV2_HANDLER_2(Accel_Key_Handler, ICoreWebView2AcceleratorKeyPressedEventHandler,
                     ICoreWebView2Controller *, ICoreWebView2AcceleratorKeyPressedEventArgs *)
DEFINE_WV2_HANDLER_2(Focus_Changed_Handler, ICoreWebView2FocusChangedEventHandler,
                     ICoreWebView2Controller *, IUnknown *)

static std::string wide_to_utf8(const wchar_t *text) {
    if (!text || !text[0]) return {};
    int needed = WideCharToMultiByte(CP_UTF8, 0, text, -1, nullptr, 0, nullptr, nullptr);
    if (needed <= 1) return {};
    std::string out(static_cast<size_t>(needed - 1), '\0');
    WideCharToMultiByte(CP_UTF8, 0, text, -1, out.data(), needed, nullptr, nullptr);
    return out;
}

static bool url_allowed(const wchar_t *uri) {
    if (!uri) return false;
    return _wcsnicmp(uri, L"http://", 7) == 0 || _wcsnicmp(uri, L"https://", 8) == 0 ||
           _wcsicmp(uri, L"about:blank") == 0;
}

static COREWEBVIEW2_COLOR color_from_argb(uint32_t argb) {
    COREWEBVIEW2_COLOR c{};
    c.A = static_cast<BYTE>((argb >> 24) & 0xFF);
    c.R = static_cast<BYTE>((argb >> 16) & 0xFF);
    c.G = static_cast<BYTE>((argb >> 8) & 0xFF);
    c.B = static_cast<BYTE>(argb & 0xFF);
    return c;
}

struct Overlay_Layer {
    Com_Ptr<IDCompositionVisual> visual;
    Com_Ptr<IDXGISwapChain1> chain;
    Com_Ptr<ID3D11RenderTargetView> rtv;
    int width = 0;
    int height = 0;
    bool attached = false;
};

struct Aio_Webview_Host {
    HWND hwnd = nullptr;
    Com_Ptr<ID3D11Device> d3d;
    Com_Ptr<ID3D11DeviceContext> ctx;
    Com_Ptr<IDXGIFactory2> factory;
    Com_Ptr<IDCompositionDevice> dcomp;
    Com_Ptr<IDCompositionTarget> target;
    Com_Ptr<IDCompositionVisual> root;
    Com_Ptr<IDCompositionVisual> tiled_web_root;
    Com_Ptr<IDCompositionVisual> float_web_root;
    // 0: floats layer (above tiled web views, below floating web views)
    // 1: top overlay layer (above floating web views: palette, menus, tooltips, notices, drag)
    Overlay_Layer overlays[2];
};

using Accel_Callback = bool (*)(void *user, uint32_t pane_id, uint32_t vk, uint32_t kind, int32_t lparam);

struct Aio_Webview;

struct Aio_Webview_Env {
    Com_Ptr<ICoreWebView2Environment> env;
    Com_Ptr<ICoreWebView2Environment3> env3;
    HWND wake_hwnd = nullptr;
    UINT wake_msg = 0;
    Accel_Callback accel_cb = nullptr;
    void *accel_user = nullptr;
    bool ready = false;
    bool failed = false;
    HRESULT error_hr = S_OK;
    std::vector<Aio_Webview *> pending;
    std::shared_ptr<std::atomic_bool> alive = std::make_shared<std::atomic_bool>(true);

    void wake() const {
        if (wake_hwnd && wake_msg) PostMessageW(wake_hwnd, wake_msg, 0, 0);
    }
};

struct Aio_Webview {
    Aio_Webview_Env *env = nullptr;
    Aio_Webview_Host *host = nullptr;
    uint32_t pane_id = 0;
    std::shared_ptr<std::atomic_bool> alive = std::make_shared<std::atomic_bool>(true);

    Com_Ptr<ICoreWebView2CompositionController> comp;
    Com_Ptr<ICoreWebView2Controller> controller;
    Com_Ptr<ICoreWebView2Controller2> controller2;
    Com_Ptr<ICoreWebView2Controller3> controller3;
    Com_Ptr<ICoreWebView2> webview;
    Com_Ptr<IDCompositionVisual> visual;
    Com_Ptr<IDCompositionRectangleClip> clip;
    Aio_Webview_Host *visual_host = nullptr;
    bool visual_attached = false;
    bool visual_floating = false;

    bool visible = false;
    bool floating = false;
    int vis_x = 0, vis_y = 0, vis_w = 0, vis_h = 0;
    float clip_l = 0.0f, clip_t = 0.0f, clip_r = 0.0f, clip_b = 0.0f;
    int bounds_w = 0, bounds_h = 0;
    int applied_bounds_w = -1, applied_bounds_h = -1;
    float radius_bl = 0.0f, radius_br = 0.0f;
    float raster_scale = 1.0f;
    float applied_scale = 0.0f;
    COREWEBVIEW2_COLOR bg_color{255, 24, 24, 28};

    std::wstring pending_url;
    bool creating = false;
    bool ready = false;
    bool failed = false;
    bool loading = false;
    bool can_back = false;
    bool can_forward = false;
    bool focused = false;
    bool state_dirty = false;
    uint32_t cursor_id = 32512; // IDC_ARROW
    std::string url_utf8;
    std::string title_utf8;
    std::string new_window_url_utf8;
};

static void detach_visual(Aio_Webview *v) {
    if (!v->visual_attached || !v->visual_host || !v->visual) return;
    auto *parent = v->visual_floating ? v->visual_host->float_web_root.get()
                                      : v->visual_host->tiled_web_root.get();
    if (parent) parent->RemoveVisual(v->visual.get());
    v->visual_attached = false;
}

static void ensure_visual_for_host(Aio_Webview *v, Aio_Webview_Host *host) {
    if (!v || !host || !v->comp) return;
    if (v->visual_host != host) {
        auto *old_host = v->visual_host;
        detach_visual(v);
        v->comp->put_RootVisualTarget(nullptr);
        v->visual.reset();
        v->clip.reset();
        if (old_host && old_host->dcomp) old_host->dcomp->Commit();
        v->visual_host = host;
        // Force bounds and scale reapplication so Chromium commits a fresh frame to the new visual.
        v->applied_bounds_w = -1;
        v->applied_bounds_h = -1;
        v->applied_scale = 0.0f;
        if (v->controller) {
            v->controller->put_ParentWindow(host->hwnd);
            v->controller->NotifyParentWindowPositionChanged();
        }
        host->dcomp->CreateVisual(v->visual.put());
        host->dcomp->CreateRectangleClip(v->clip.put());
        if (v->visual) {
            if (v->clip) v->visual->SetClip(v->clip.get());
            v->comp->put_RootVisualTarget(v->visual.get());
        }
    }
}

static void apply_placement(Aio_Webview *v) {
    if (!v || !v->ready || !v->controller || !v->comp) return;
    if (!v->host || !v->visible || v->vis_w <= 0 || v->vis_h <= 0) {
        detach_visual(v);
        v->controller->put_IsVisible(FALSE);
        return;
    }
    ensure_visual_for_host(v, v->host);
    if (!v->visual) return;

    if (!v->visual_attached || v->visual_floating != v->floating) {
        detach_visual(v);
        auto *parent = v->floating ? v->host->float_web_root.get() : v->host->tiled_web_root.get();
        if (parent) {
            parent->AddVisual(v->visual.get(), TRUE, nullptr);
            v->visual_attached = true;
            v->visual_floating = v->floating;
        }
    }

    v->visual->SetOffsetX(static_cast<float>(v->vis_x));
    v->visual->SetOffsetY(static_cast<float>(v->vis_y));
    if (v->clip) {
        v->clip->SetLeft(v->clip_l);
        v->clip->SetTop(v->clip_t);
        v->clip->SetRight(v->clip_r);
        v->clip->SetBottom(v->clip_b);
        v->clip->SetTopLeftRadiusX(0.0f);
        v->clip->SetTopLeftRadiusY(0.0f);
        v->clip->SetTopRightRadiusX(0.0f);
        v->clip->SetTopRightRadiusY(0.0f);
        v->clip->SetBottomLeftRadiusX(v->radius_bl);
        v->clip->SetBottomLeftRadiusY(v->radius_bl);
        v->clip->SetBottomRightRadiusX(v->radius_br);
        v->clip->SetBottomRightRadiusY(v->radius_br);
    }

    if (v->controller3 && v->raster_scale > 0.0f && v->raster_scale != v->applied_scale) {
        v->controller3->put_RasterizationScale(static_cast<double>(v->raster_scale));
        v->applied_scale = v->raster_scale;
    }

    int bw = (v->bounds_w > 0) ? v->bounds_w : v->vis_w;
    int bh = (v->bounds_h > 0) ? v->bounds_h : v->vis_h;
    if (bw != v->applied_bounds_w || bh != v->applied_bounds_h) {
        RECT bounds{0, 0, bw, bh};
        v->controller->put_Bounds(bounds);
        v->applied_bounds_w = bw;
        v->applied_bounds_h = bh;
    }
    v->controller->put_IsVisible(TRUE);
}

static void refresh_webview_state(Aio_Webview *v) {
    if (!v || !v->webview) return;
    LPWSTR uri = nullptr;
    if (SUCCEEDED(v->webview->get_Source(&uri)) && uri) {
        v->url_utf8 = wide_to_utf8(uri);
        CoTaskMemFree(uri);
    }
    LPWSTR title = nullptr;
    if (SUCCEEDED(v->webview->get_DocumentTitle(&title)) && title) {
        v->title_utf8 = wide_to_utf8(title);
        CoTaskMemFree(title);
    }
    BOOL back = FALSE, fwd = FALSE;
    if (SUCCEEDED(v->webview->get_CanGoBack(&back))) v->can_back = (back != FALSE);
    if (SUCCEEDED(v->webview->get_CanGoForward(&fwd))) v->can_forward = (fwd != FALSE);
    v->state_dirty = true;
    if (v->env) v->env->wake();
}

static void start_controller_creation(Aio_Webview *v) {
    if (!v || !v->env || !v->env->ready || !v->env->env3 || !v->host || v->creating || v->ready) return;
    v->creating = true;
    auto alive = v->alive;
    auto env_alive = v->env->alive;

    Com_Ptr<ICoreWebView2CreateCoreWebView2CompositionControllerCompletedHandler> handler;
    *handler.put() = new Comp_Completed_Handler([v, alive, env_alive](
                                                    HRESULT hr,
                                                    ICoreWebView2CompositionController *comp) -> HRESULT {
        if (!alive->load() || !env_alive->load()) {
            if (comp) {
                Com_Ptr<ICoreWebView2Controller> ctrl;
                if (SUCCEEDED(comp->QueryInterface(IID_PPV_ARGS(ctrl.put()))) && ctrl) ctrl->Close();
            }
            return S_OK;
        }
        v->creating = false;
        if (FAILED(hr) || !comp) {
            v->failed = true;
            v->state_dirty = true;
            if (v->env) v->env->wake();
            return S_OK;
        }
        v->comp.reset();
        comp->AddRef();
        *v->comp.put() = comp;
        if (FAILED(comp->QueryInterface(IID_PPV_ARGS(v->controller.put()))) || !v->controller) {
            v->failed = true;
            v->state_dirty = true;
            if (v->env) v->env->wake();
            return S_OK;
        }
        v->controller->QueryInterface(IID_PPV_ARGS(v->controller2.put()));
        v->controller->QueryInterface(IID_PPV_ARGS(v->controller3.put()));
        if (FAILED(v->controller->get_CoreWebView2(v->webview.put())) || !v->webview) {
            v->failed = true;
            v->state_dirty = true;
            if (v->env) v->env->wake();
            return S_OK;
        }

        if (v->controller2) {
            v->controller2->put_DefaultBackgroundColor(v->bg_color);
        }
        if (v->controller3) {
            v->controller3->put_BoundsMode(COREWEBVIEW2_BOUNDS_MODE_USE_RAW_PIXELS);
            v->controller3->put_ShouldDetectMonitorScaleChanges(FALSE);
        }

        Com_Ptr<ICoreWebView2Settings> settings;
        if (SUCCEEDED(v->webview->get_Settings(settings.put())) && settings) {
            settings->put_AreHostObjectsAllowed(FALSE);
            settings->put_IsWebMessageEnabled(FALSE);
            settings->put_AreDefaultContextMenusEnabled(TRUE);
            settings->put_IsStatusBarEnabled(FALSE);
            settings->put_AreDevToolsEnabled(TRUE);
        }

        EventRegistrationToken tok{};
        v->webview->add_NavigationStarting(
            make_handler<Nav_Starting_Handler>([v, alive](
                ICoreWebView2 *, ICoreWebView2NavigationStartingEventArgs *args) -> HRESULT {
                if (!alive->load() || !args) return S_OK;
                LPWSTR uri = nullptr;
                if (SUCCEEDED(args->get_Uri(&uri)) && uri) {
                    if (!url_allowed(uri)) {
                        args->put_Cancel(TRUE);
                    } else {
                        v->loading = true;
                        v->url_utf8 = wide_to_utf8(uri);
                        v->state_dirty = true;
                        if (v->env) v->env->wake();
                    }
                    CoTaskMemFree(uri);
                }
                return S_OK;
            }).get(),
            &tok);

        v->webview->add_NavigationCompleted(
            make_handler<Nav_Completed_Handler>([v, alive](
                ICoreWebView2 *, ICoreWebView2NavigationCompletedEventArgs *) -> HRESULT {
                if (!alive->load()) return S_OK;
                v->loading = false;
                refresh_webview_state(v);
                return S_OK;
            }).get(),
            &tok);

        v->webview->add_SourceChanged(
            make_handler<Source_Changed_Handler>([v, alive](
                ICoreWebView2 *, ICoreWebView2SourceChangedEventArgs *) -> HRESULT {
                if (!alive->load()) return S_OK;
                refresh_webview_state(v);
                return S_OK;
            }).get(),
            &tok);

        v->webview->add_HistoryChanged(
            make_handler<History_Changed_Handler>([v, alive](ICoreWebView2 *, IUnknown *) -> HRESULT {
                if (!alive->load()) return S_OK;
                refresh_webview_state(v);
                return S_OK;
            }).get(),
            &tok);

        v->webview->add_DocumentTitleChanged(
            make_handler<Title_Changed_Handler>([v, alive](ICoreWebView2 *, IUnknown *) -> HRESULT {
                if (!alive->load()) return S_OK;
                refresh_webview_state(v);
                return S_OK;
            }).get(),
            &tok);

        v->webview->add_NewWindowRequested(
            make_handler<New_Window_Handler>([v, alive](
                ICoreWebView2 *, ICoreWebView2NewWindowRequestedEventArgs *args) -> HRESULT {
                if (!alive->load() || !args) return S_OK;
                args->put_Handled(TRUE);
                LPWSTR uri = nullptr;
                if (SUCCEEDED(args->get_Uri(&uri)) && uri) {
                    if (url_allowed(uri)) {
                        v->new_window_url_utf8 = wide_to_utf8(uri);
                        v->state_dirty = true;
                        if (v->env) v->env->wake();
                    }
                    CoTaskMemFree(uri);
                }
                return S_OK;
            }).get(),
            &tok);

        v->comp->add_CursorChanged(
            make_handler<Cursor_Changed_Handler>([v, alive](
                ICoreWebView2CompositionController *sender, IUnknown *) -> HRESULT {
                if (!alive->load() || !sender) return S_OK;
                UINT32 id = 32512;
                if (SUCCEEDED(sender->get_SystemCursorId(&id))) {
                    v->cursor_id = id;
                    v->state_dirty = true;
                    if (v->env) v->env->wake();
                }
                return S_OK;
            }).get(),
            &tok);

        v->controller->add_GotFocus(
            make_handler<Focus_Changed_Handler>([v, alive](ICoreWebView2Controller *, IUnknown *) -> HRESULT {
                if (!alive->load()) return S_OK;
                v->focused = true;
                v->state_dirty = true;
                if (v->env) v->env->wake();
                return S_OK;
            }).get(),
            &tok);

        v->controller->add_LostFocus(
            make_handler<Focus_Changed_Handler>([v, alive](ICoreWebView2Controller *, IUnknown *) -> HRESULT {
                if (!alive->load()) return S_OK;
                v->focused = false;
                v->state_dirty = true;
                if (v->env) v->env->wake();
                return S_OK;
            }).get(),
            &tok);

        v->controller->add_AcceleratorKeyPressed(
            make_handler<Accel_Key_Handler>([v, alive](
                ICoreWebView2Controller *, ICoreWebView2AcceleratorKeyPressedEventArgs *args) -> HRESULT {
                if (!alive->load() || !args || !v->env || !v->env->accel_cb) return S_OK;
                UINT vk = 0;
                COREWEBVIEW2_KEY_EVENT_KIND kind = COREWEBVIEW2_KEY_EVENT_KIND_KEY_DOWN;
                INT lparam = 0;
                args->get_VirtualKey(&vk);
                args->get_KeyEventKind(&kind);
                args->get_KeyEventLParam(&lparam);
                if (v->env->accel_cb(v->env->accel_user, v->pane_id, static_cast<uint32_t>(vk),
                                     static_cast<uint32_t>(kind), static_cast<int32_t>(lparam))) {
                    args->put_Handled(TRUE);
                }
                return S_OK;
            }).get(),
            &tok);

        v->ready = true;
        apply_placement(v);
        if (v->host) v->host->dcomp->Commit();
        if (!v->pending_url.empty()) {
            if (url_allowed(v->pending_url.c_str())) {
                v->webview->Navigate(v->pending_url.c_str());
            }
            v->pending_url.clear();
        }
        v->state_dirty = true;
        if (v->env) v->env->wake();
        return S_OK;
    });

    HRESULT hr = v->env->env3->CreateCoreWebView2CompositionController(v->host->hwnd, handler.get());
    if (FAILED(hr)) {
        v->creating = false;
        v->failed = true;
        v->state_dirty = true;
        v->env->wake();
    }
}

static bool overlay_ensure(Aio_Webview_Host *host, Overlay_Layer &layer, int width, int height) {
    if (width <= 0 || height <= 0) return false;
    if (layer.chain && layer.rtv && layer.width == width && layer.height == height) {
        if (!layer.attached && layer.visual) {
            layer.visual->SetContent(layer.chain.get());
            layer.attached = true;
        }
        return true;
    }
    if (!layer.chain) {
        DXGI_SWAP_CHAIN_DESC1 desc{};
        desc.Width = static_cast<UINT>(width);
        desc.Height = static_cast<UINT>(height);
        desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        desc.SampleDesc.Count = 1;
        desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
        desc.BufferCount = 2;
        desc.Scaling = DXGI_SCALING_STRETCH;
        desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
        desc.AlphaMode = DXGI_ALPHA_MODE_PREMULTIPLIED;
        HRESULT hr = host->factory->CreateSwapChainForComposition(host->d3d.get(), &desc, nullptr,
                                                                  layer.chain.put());
        if (FAILED(hr) || !layer.chain) return false;
        if (layer.visual) {
            layer.visual->SetContent(layer.chain.get());
            layer.attached = true;
        }
    } else {
        layer.rtv.reset();
        if (host->ctx) {
            host->ctx->ClearState();
            host->ctx->Flush();
        }
        HRESULT hr = layer.chain->ResizeBuffers(2, static_cast<UINT>(width), static_cast<UINT>(height),
                                                DXGI_FORMAT_B8G8R8A8_UNORM, 0);
        if (FAILED(hr)) return false;
        if (!layer.attached && layer.visual) {
            layer.visual->SetContent(layer.chain.get());
            layer.attached = true;
        }
    }
    Com_Ptr<ID3D11Texture2D> back;
    if (FAILED(layer.chain->GetBuffer(0, IID_PPV_ARGS(back.put()))) || !back) return false;
    if (FAILED(host->d3d->CreateRenderTargetView(back.get(), nullptr, layer.rtv.put()))) return false;
    layer.width = width;
    layer.height = height;
    return true;
}

} // namespace

struct Aio_Webview_Snapshot {
    const char *url;
    int url_len;
    const char *title;
    int title_len;
    const char *new_window_url;
    int new_window_url_len;
    uint32_t cursor_id;
    uint8_t ready;
    uint8_t failed;
    uint8_t loading;
    uint8_t can_back;
    uint8_t can_forward;
    uint8_t focused;
    uint8_t dirty;
};

extern "C" {

HRESULT aio_webview_host_create(HWND hwnd, ID3D11Device *d3d_device, IDXGIFactory2 *dxgi_factory,
                                void **out_host) noexcept {
    if (!hwnd || !d3d_device || !dxgi_factory || !out_host) return E_INVALIDARG;
    *out_host = nullptr;
    auto host = std::make_unique<Aio_Webview_Host>();
    host->hwnd = hwnd;
    d3d_device->AddRef();
    *host->d3d.put() = d3d_device;
    d3d_device->GetImmediateContext(host->ctx.put());
    dxgi_factory->AddRef();
    *host->factory.put() = dxgi_factory;

    Com_Ptr<IDXGIDevice> dxgi_device;
    HRESULT hr = d3d_device->QueryInterface(IID_PPV_ARGS(dxgi_device.put()));
    if (FAILED(hr)) return hr;
    hr = DCompositionCreateDevice(dxgi_device.get(), IID_PPV_ARGS(host->dcomp.put()));
    if (FAILED(hr)) return hr;
    hr = host->dcomp->CreateTargetForHwnd(hwnd, TRUE, host->target.put());
    if (FAILED(hr)) return hr;
    hr = host->dcomp->CreateVisual(host->root.put());
    if (FAILED(hr)) return hr;
    hr = host->target->SetRoot(host->root.get());
    if (FAILED(hr)) return hr;

    hr = host->dcomp->CreateVisual(host->tiled_web_root.put());
    if (FAILED(hr)) return hr;
    hr = host->dcomp->CreateVisual(host->overlays[0].visual.put());
    if (FAILED(hr)) return hr;
    hr = host->dcomp->CreateVisual(host->float_web_root.put());
    if (FAILED(hr)) return hr;
    hr = host->dcomp->CreateVisual(host->overlays[1].visual.put());
    if (FAILED(hr)) return hr;

    // Z-order from bottom to top above the HWND's main flip-model swap chain:
    // tiled_web_root -> overlays[0] (floats) -> float_web_root -> overlays[1] (top overlays)
    host->root->AddVisual(host->tiled_web_root.get(), TRUE, nullptr);
    host->root->AddVisual(host->overlays[0].visual.get(), TRUE, host->tiled_web_root.get());
    host->root->AddVisual(host->float_web_root.get(), TRUE, host->overlays[0].visual.get());
    host->root->AddVisual(host->overlays[1].visual.get(), TRUE, host->float_web_root.get());
    host->dcomp->Commit();

    *out_host = host.release();
    return S_OK;
}

void aio_webview_host_destroy(void *raw) noexcept {
    if (!raw) return;
    auto *host = static_cast<Aio_Webview_Host *>(raw);
    for (auto &layer : host->overlays) {
        if (layer.visual) layer.visual->SetContent(nullptr);
        layer.rtv.reset();
        layer.chain.reset();
    }
    if (host->dcomp) host->dcomp->Commit();
    delete host;
}

ID3D11RenderTargetView *aio_webview_host_overlay_begin(void *raw, int layer_index, int width,
                                                       int height) noexcept {
    if (!raw || layer_index < 0 || layer_index > 1) return nullptr;
    auto *host = static_cast<Aio_Webview_Host *>(raw);
    auto &layer = host->overlays[layer_index];
    if (!overlay_ensure(host, layer, width, height)) return nullptr;
    return layer.rtv.get();
}

void aio_webview_host_overlay_present(void *raw, int layer_index) noexcept {
    if (!raw || layer_index < 0 || layer_index > 1) return;
    auto *host = static_cast<Aio_Webview_Host *>(raw);
    auto &layer = host->overlays[layer_index];
    if (layer.chain) layer.chain->Present(0, 0);
}

void aio_webview_host_overlay_hide(void *raw, int layer_index) noexcept {
    if (!raw || layer_index < 0 || layer_index > 1) return;
    auto *host = static_cast<Aio_Webview_Host *>(raw);
    auto &layer = host->overlays[layer_index];
    if (layer.attached && layer.visual) {
        layer.visual->SetContent(nullptr);
        layer.attached = false;
    }
}

void aio_webview_host_commit(void *raw) noexcept {
    if (!raw) return;
    auto *host = static_cast<Aio_Webview_Host *>(raw);
    if (host->dcomp) host->dcomp->Commit();
}

HRESULT aio_webview_env_create(const wchar_t *user_data_dir, HWND wake_hwnd, UINT wake_msg,
                               Accel_Callback accel_cb, void *accel_user, void **out_env) noexcept {
    if (!out_env) return E_INVALIDARG;
    *out_env = nullptr;
    auto env = std::make_unique<Aio_Webview_Env>();
    env->wake_hwnd = wake_hwnd;
    env->wake_msg = wake_msg;
    env->accel_cb = accel_cb;
    env->accel_user = accel_user;

    auto *env_ptr = env.get();
    auto alive = env->alive;
    Com_Ptr<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler> handler;
    *handler.put() = new Env_Completed_Handler(
        [env_ptr, alive](HRESULT hr, ICoreWebView2Environment *created) -> HRESULT {
            if (!alive->load()) return S_OK;
            if (FAILED(hr) || !created) {
                env_ptr->failed = true;
                env_ptr->error_hr = hr;
                for (auto *v : env_ptr->pending) {
                    v->failed = true;
                    v->state_dirty = true;
                }
                env_ptr->pending.clear();
                env_ptr->wake();
                return S_OK;
            }
            created->AddRef();
            *env_ptr->env.put() = created;
            if (FAILED(created->QueryInterface(IID_PPV_ARGS(env_ptr->env3.put()))) || !env_ptr->env3) {
                env_ptr->failed = true;
                env_ptr->error_hr = E_NOINTERFACE;
                for (auto *v : env_ptr->pending) {
                    v->failed = true;
                    v->state_dirty = true;
                }
                env_ptr->pending.clear();
                env_ptr->wake();
                return S_OK;
            }
            env_ptr->ready = true;
            auto queued = std::move(env_ptr->pending);
            env_ptr->pending.clear();
            for (auto *v : queued) start_controller_creation(v);
            env_ptr->wake();
            return S_OK;
        });

    HRESULT hr = CreateCoreWebView2EnvironmentWithOptions(nullptr, user_data_dir, nullptr, handler.get());
    if (FAILED(hr)) {
        env->alive->store(false);
        return hr;
    }
    *out_env = env.release();
    return S_OK;
}

void aio_webview_env_destroy(void *raw) noexcept {
    if (!raw) return;
    auto *env = static_cast<Aio_Webview_Env *>(raw);
    env->alive->store(false);
    env->pending.clear();
    delete env;
}

void *aio_webview_create(void *raw_env, void *raw_host, uint32_t pane_id, const wchar_t *initial_url,
                         uint32_t bg_argb) noexcept {
    if (!raw_env || !raw_host) return nullptr;
    auto *env = static_cast<Aio_Webview_Env *>(raw_env);
    auto *host = static_cast<Aio_Webview_Host *>(raw_host);
    auto v = std::make_unique<Aio_Webview>();
    v->env = env;
    v->host = host;
    v->pane_id = pane_id;
    v->bg_color = color_from_argb(bg_argb);
    if (initial_url && initial_url[0]) {
        v->pending_url = initial_url;
        v->url_utf8 = wide_to_utf8(initial_url);
    }
    auto *ptr = v.release();
    if (env->failed) {
        ptr->failed = true;
        ptr->state_dirty = true;
    } else if (env->ready) {
        start_controller_creation(ptr);
    } else {
        env->pending.push_back(ptr);
    }
    return ptr;
}

void aio_webview_destroy(void *raw) noexcept {
    if (!raw) return;
    auto *v = static_cast<Aio_Webview *>(raw);
    v->alive->store(false);
    if (v->env) {
        auto &p = v->env->pending;
        p.erase(std::remove(p.begin(), p.end(), v), p.end());
    }
    detach_visual(v);
    auto *host = v->visual_host ? v->visual_host : v->host;
    if (v->comp) v->comp->put_RootVisualTarget(nullptr);
    if (v->controller) v->controller->Close();
    v->clip.reset();
    v->visual.reset();
    if (host && host->dcomp) host->dcomp->Commit();
    delete v;
}

void aio_webview_detach_host(void *raw, HWND fallback_hwnd) noexcept {
    if (!raw) return;
    auto *v = static_cast<Aio_Webview *>(raw);
    auto *old_host = v->visual_host;
    detach_visual(v);
    if (v->comp) v->comp->put_RootVisualTarget(nullptr);
    v->clip.reset();
    v->visual.reset();
    v->visual_host = nullptr;
    v->host = nullptr;
    v->visible = false;
    v->applied_bounds_w = -1;
    v->applied_bounds_h = -1;
    v->applied_scale = 0.0f;
    if (v->controller) {
        v->controller->put_IsVisible(FALSE);
        if (fallback_hwnd) {
            v->controller->put_ParentWindow(fallback_hwnd);
        }
    }
    if (old_host && old_host->dcomp) old_host->dcomp->Commit();
}

void aio_webview_set_placement(void *raw, void *raw_host, int visible, int floating, int vis_x, int vis_y,
                               int vis_w, int vis_h, float clip_l, float clip_t, float clip_r, float clip_b,
                               int bounds_w, int bounds_h, float radius_bl, float radius_br,
                               float raster_scale) noexcept {
    if (!raw) return;
    auto *v = static_cast<Aio_Webview *>(raw);
    auto *host = static_cast<Aio_Webview_Host *>(raw_host);
    bool host_changed = (v->host != host);
    v->host = host;
    v->visible = (visible != 0);
    v->floating = (floating != 0);
    v->vis_x = vis_x;
    v->vis_y = vis_y;
    v->vis_w = vis_w;
    v->vis_h = vis_h;
    v->clip_l = clip_l;
    v->clip_t = clip_t;
    v->clip_r = clip_r;
    v->clip_b = clip_b;
    v->bounds_w = bounds_w;
    v->bounds_h = bounds_h;
    v->radius_bl = radius_bl;
    v->radius_br = radius_br;
    v->raster_scale = raster_scale;
    if (!v->ready && v->env && v->env->ready && v->host && !v->creating && !v->failed) {
        start_controller_creation(v);
        return;
    }
    if (host_changed && !host) {
        detach_visual(v);
    }
    apply_placement(v);
}

void aio_webview_set_bg(void *raw, uint32_t bg_argb) noexcept {
    if (!raw) return;
    auto *v = static_cast<Aio_Webview *>(raw);
    v->bg_color = color_from_argb(bg_argb);
    if (v->controller2) v->controller2->put_DefaultBackgroundColor(v->bg_color);
}

void aio_webview_navigate(void *raw, const wchar_t *url) noexcept {
    if (!raw || !url || !url_allowed(url)) return;
    auto *v = static_cast<Aio_Webview *>(raw);
    if (v->webview) {
        v->webview->Navigate(url);
    } else {
        v->pending_url = url;
        v->url_utf8 = wide_to_utf8(url);
    }
}

void aio_webview_go_back(void *raw) noexcept {
    if (!raw) return;
    auto *v = static_cast<Aio_Webview *>(raw);
    if (v->webview) v->webview->GoBack();
}

void aio_webview_go_forward(void *raw) noexcept {
    if (!raw) return;
    auto *v = static_cast<Aio_Webview *>(raw);
    if (v->webview) v->webview->GoForward();
}

void aio_webview_reload(void *raw) noexcept {
    if (!raw) return;
    auto *v = static_cast<Aio_Webview *>(raw);
    if (v->webview) v->webview->Reload();
}

void aio_webview_stop(void *raw) noexcept {
    if (!raw) return;
    auto *v = static_cast<Aio_Webview *>(raw);
    if (v->webview) v->webview->Stop();
}

void aio_webview_mouse(void *raw, int kind, uint32_t virtual_keys, uint32_t mouse_data, int local_x,
                       int local_y) noexcept {
    if (!raw) return;
    auto *v = static_cast<Aio_Webview *>(raw);
    if (!v->comp || !v->ready) return;
    POINT pt{local_x, local_y};
    v->comp->SendMouseInput(static_cast<COREWEBVIEW2_MOUSE_EVENT_KIND>(kind),
                            static_cast<COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS>(virtual_keys), mouse_data, pt);
}

void aio_webview_focus(void *raw) noexcept {
    if (!raw) return;
    auto *v = static_cast<Aio_Webview *>(raw);
    if (v->controller && v->ready) {
        v->controller->MoveFocus(COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC);
    }
}

void aio_webview_parent_moved(void *raw) noexcept {
    if (!raw) return;
    auto *v = static_cast<Aio_Webview *>(raw);
    if (v->controller && v->ready) {
        v->controller->NotifyParentWindowPositionChanged();
    }
}

void aio_webview_poll(void *raw, Aio_Webview_Snapshot *out) noexcept {
    if (!out) return;
    std::memset(out, 0, sizeof(*out));
    if (!raw) return;
    auto *v = static_cast<Aio_Webview *>(raw);
    out->url = v->url_utf8.c_str();
    out->url_len = static_cast<int>(v->url_utf8.size());
    out->title = v->title_utf8.c_str();
    out->title_len = static_cast<int>(v->title_utf8.size());
    out->new_window_url = v->new_window_url_utf8.c_str();
    out->new_window_url_len = static_cast<int>(v->new_window_url_utf8.size());
    out->cursor_id = v->cursor_id;
    out->ready = v->ready ? 1 : 0;
    out->failed = v->failed ? 1 : 0;
    out->loading = v->loading ? 1 : 0;
    out->can_back = v->can_back ? 1 : 0;
    out->can_forward = v->can_forward ? 1 : 0;
    out->focused = v->focused ? 1 : 0;
    out->dirty = v->state_dirty ? 1 : 0;
    v->state_dirty = false;
}

void aio_webview_clear_new_window(void *raw) noexcept {
    if (!raw) return;
    static_cast<Aio_Webview *>(raw)->new_window_url_utf8.clear();
}

} // extern "C"
