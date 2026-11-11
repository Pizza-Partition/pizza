//! Native window lifecycle and WebUI callbacks. Application behavior is injected.
const std = @import("std");
const webui = @import("webui");
pub const Options = struct { mode: enum { desktop, browser }, port: u16 };

pub fn run(a: std.mem.Allocator, io: std.Io, options: Options, service: anytype) !u8 {
    if (comptime @import("builtin").os.tag == .linux) {
        if (options.mode == .desktop and Linux.prepare())
            std.log.info("Using NVIDIA Wayland implicit synchronization (WebKit DMA-BUF allowed).", .{});
    }
    const App = @TypeOf(service.*);
    const Binding = struct {
        // WebUI callbacks have no context argument. Scope this one-window binding
        // to run(); workers and application services never use this global bridge.
        var app: ?*App = null;
        var close_requested: std.atomic.Value(bool) = .init(false);
        fn close(_: usize) bool {
            // Leave GTK's delete-event before shutting down on the next loop tick.
            close_requested.store(true, .release);
            return true;
        }
        fn request(e: *webui.Event) void {
            const current = app orelse return;
            var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
            defer arena.deinit();
            const allocator = arena.allocator();
            const response = current.respond(allocator, e.getString(), .local);
            e.returnString(allocator.dupeSentinel(u8, response, 0) catch {
                e.returnString("{\"error\":\"OutOfMemory\",\"message\":\"Cannot allocate the response\"}");
                return;
            });
        }
        fn plan(e: *webui.Event) void {
            const current = app orelse return;
            var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
            defer arena.deinit();
            const allocator = arena.allocator();
            const response = current.plan(allocator, e.getString()) catch |err| current.replyError(allocator, err);
            e.returnString(allocator.dupeSentinel(u8, response, 0) catch {
                e.returnString("{\"error\":\"OutOfMemory\",\"message\":\"Cannot allocate the response\"}");
                return;
            });
        }
        fn session(e: *webui.Event) void {
            const current = app orelse return;
            var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
            defer arena.deinit();
            const allocator = arena.allocator();
            const response = current.metadata(allocator) catch |err| current.replyError(allocator, err);
            e.returnString(allocator.dupeSentinel(u8, response, 0) catch {
                e.returnString("{\"error\":\"OutOfMemory\",\"message\":\"Cannot allocate the response\"}");
                return;
            });
        }
    };
    Binding.app = service;
    defer Binding.app = null;
    Binding.close_requested.store(false, .release);
    webui.setConfig(.multi_client, false);
    webui.setConfig(.use_cookies, true);
    const win = webui.newWindow();
    win.setPublic(false);
    win.setFileHandler(@import("asset_response.zig").response);
    _ = try win.bind("pizza_request", Binding.request);
    _ = try win.bind("pizza_session", Binding.session);
    _ = try win.bind("pizza_plan", Binding.plan);
    if (options.mode == .browser) {
        webui.setTimeout(0);
        try win.setPort(options.port);
        const url = try win.startServer("index.html");
        try std.Io.File.stdout().writeStreamingAll(io, try a.print("Pizza: {s}\n", .{url}));
    } else {
        // Enter the event loop immediately, even if the page has not connected
        // yet. Closing a window during startup must not wait for that handshake.
        webui.setConfig(.show_wait_connection, false);
        win.setCloseHandlerWv(Binding.close);
        win.setSize(1160, 740);
        win.setMinimumSize(360, 400);
        win.setResizable(true);
        // show() permits launching a system browser. The desktop entry must
        // use only the native WebView, with no implicit browser fallback.
        win.showWv("index.html") catch {
            std.log.err("Cannot open the native WebView. Linux needs GTK 3 and WebKitGTK 4.1 in a graphical session; Windows needs the WebView2 Runtime. Browser preview is explicit: pizza serve.", .{});
            return error.NativeWebViewUnavailable;
        };
        std.log.info("Pizza is using the native WebView.", .{});
    }
    if (options.mode == .browser) {
        webui.wait();
    } else {
        while (webui.waitAsync()) {
            if (Binding.close_requested.load(.acquire)) {
                webui.exit();
            } else {
                try std.Io.sleep(io, .fromMilliseconds(10), .awake);
            }
        }
    }
    webui.clean();
    return 0;
}

const Linux = if (@import("builtin").os.tag == .linux) struct {
    const libc = @import("libc");
    const gobject = @import("gobject");

    /// Apply GTK settings on GTK's own thread, before constructing the WebView.
    export fn pizza_configure_gtk_text(settings: ?*anyopaque) void {
        if (settings == null) return;
        var style: [*c]u8 = null;
        gobject.g_object_get(settings, "gtk-xft-hintstyle", &style, @as(?*anyopaque, null));
        defer gobject.g_free(style);
        if (style != null and std.mem.eql(u8, std.mem.span(style), "hintfull"))
            gobject.g_object_set(settings, "gtk-xft-hintstyle", @as([*:0]const u8, "hintslight"), @as(?*anyopaque, null));
    }
    fn prepare() bool {
        const wayland = libc.getenv("WAYLAND_DISPLAY");
        const backend = libc.getenv("GDK_BACKEND");
        const disabled = libc.getenv("WEBKIT_DISABLE_DMABUF_RENDERER");
        if (wayland == null or wayland[0] == 0 or
            backend != null and std.mem.eql(u8, std.mem.span(backend), "x11") or
            disabled != null and !std.mem.eql(u8, std.mem.span(disabled), "0") or
            libc.getenv("__NV_DISABLE_EXPLICIT_SYNC") != null or
            libc.access("/sys/module/nvidia/version", libc.R_OK) != 0) return false;
        return libc.setenv("__NV_DISABLE_EXPLICIT_SYNC", "1", 0) == 0;
    }
} else struct {};
