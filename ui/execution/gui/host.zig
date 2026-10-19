//! WPE host and business backend share this ordinary process. PID 1 never loads WPE.
const std = @import("std");
const wpe = @import("wpe.zig");
const bridge = @import("maintenance").bridge;
const proto = @import("proto");

pub const Options = struct { library: []const u8, panel: []const u8, self_test: bool = false, timeout_s: u32 = 30 };
const Runtime = struct {
    api: *wpe.Api,
    backend: *bridge.Backend,
    io: std.Io,
    view: wpe.Ptr,
    loop: wpe.Ptr,
    uri: [:0]const u8,
    options: Options,
    deadline: i96,
    ready: bool = false,
    failed: bool = false,
    methods: u8 = 0,
    subscribed: bool = false,
    cursor: u64 = 0,
    generation: u64 = 0,
    pending_generation: u64 = 0,
    pending_cursor: u64 = 0,
    inflight: bool = false,
    journal_failed: bool = false,
    execution_revision: ?u64 = null,
    pending_revision: u64 = 0,
    observed_running: bool = false,
    verifying_dom: bool = false,
    verified_dom: bool = false,
};
fn runtime(data: ?*anyopaque) *Runtime {
    return @ptrCast(@alignCast(data.?));
}

/// Requires a validated local panel. Runtime symbol lookup lets ordinary builds
/// and non-graphical operation work without installing WPE development headers.
pub fn run(a: std.mem.Allocator, io: std.Io, backend: *bridge.Backend, options: Options) !void {
    const panel = try std.Io.Dir.cwd().realPathFileAlloc(io, options.panel, a);
    // file:// escaping follows GLib's URI conversion rather than concatenating paths.
    var api = try wpe.Api.open(options.library);
    if (options.self_test) std.log.info("Bridge fixture: WPE ABI loaded", .{});
    const filename_to_uri = api.library.lookup(*const fn ([*:0]const u8, ?[*:0]const u8, *wpe.Optional) callconv(.c) ?[*:0]u8, "g_filename_to_uri") orelse return error.UnsupportedWpeAbi;
    var uri_error: wpe.Optional = null;
    const uri_c = filename_to_uri(try a.dupeSentinel(u8, panel, 0), null, &uri_error) orelse return error.PanelUriUnavailable;
    defer api.f.g_free(uri_c);
    const uri = try a.dupeSentinel(u8, std.mem.span(uri_c), 0);
    const session = api.f.webkit_network_session_new_ephemeral();
    defer api.f.g_object_unref(session);
    const context = api.f.webkit_web_context_new();
    if (options.self_test) std.log.info("Bridge fixture: context created", .{});
    defer api.f.g_object_unref(context);
    // View construction can spawn engine subprocesses, so configure access first.
    api.f.webkit_web_context_add_path_to_sandbox(context, try a.dupeSentinel(u8, try std.process.currentPathAlloc(io, a), 0), 1);
    const view = api.f.g_object_new(api.f.webkit_web_view_get_type(), "web-context", context, "network-session", session, @as(?[*:0]const u8, null)) orelse return error.WpeViewUnavailable;
    if (options.self_test) std.log.info("Bridge fixture: view created", .{});
    const settings = api.f.webkit_web_view_get_settings(view);
    // ES modules import neighboring verified panel files. Navigation restrictions
    // and the panel CSP still prohibit other documents, frames and network access.
    api.f.webkit_settings_set_allow_file_access_from_file_urls(settings, 1);
    if (options.self_test) api.f.webkit_settings_set_enable_write_console_messages_to_stdout(settings, 1);
    // Keep libWPE loaded until process exit: its internal worker threads and
    // global objects can outlive this view. Never dlclose active engine code.
    defer api.f.g_object_unref(view);
    const loop = api.f.g_main_loop_new(null, 0);
    defer api.f.g_main_loop_unref(loop);
    var state: Runtime = .{ .api = &api, .backend = backend, .io = io, .view = view, .loop = loop, .uri = uri, .options = options, .deadline = std.Io.Timestamp.now(io, .awake).nanoseconds + @as(i96, options.timeout_s) * std.time.ns_per_s };
    const manager = api.f.webkit_web_view_get_user_content_manager(view);
    _ = api.f.g_signal_connect_data(manager, "script-message-with-reply-received::pizza", @ptrCast(&message), &state, null, 0);
    if (api.f.webkit_user_content_manager_register_script_message_handler_with_reply(manager, proto.bridge_channel, null) == 0) return error.BridgeRegistrationFailed;
    _ = api.f.g_signal_connect_data(view, "decide-policy", @ptrCast(&policy), &state, null, 0);
    _ = api.f.g_signal_connect_data(view, "web-process-terminated", @ptrCast(&terminated), &state, null, 0);
    _ = api.f.g_signal_connect_data(view, "load-failed", @ptrCast(&loadFailed), &state, null, 0);
    if (options.self_test) _ = api.f.g_signal_connect_data(view, "load-changed", @ptrCast(&loadChanged), &state, null, 0);
    const native_view = api.f.webkit_web_view_get_wpe_view(view);
    if (options.self_test) std.log.info("Bridge fixture: callbacks registered", .{});
    api.f.wpe_view_resized(native_view, 1280, 720);
    api.f.wpe_view_set_visible(native_view, 1);
    if (api.f.wpe_view_get_toplevel(native_view)) |top| _ = api.f.wpe_toplevel_fullscreen(top);
    const timer = api.f.g_timeout_add(100, tick, &state);
    defer _ = api.f.g_source_remove(timer);
    api.f.webkit_web_view_load_uri(view, uri);
    std.log.info("PIZZA_MAINT_APP_STARTED: native bridge; execution={t}", .{backend.execution().status});
    api.f.g_main_loop_run(loop);
    if (!options.self_test) return;
    if (!state.ready or state.failed) return error.BridgeSelfTestFailed;
    if (backend.executor != null and (!state.observed_running or !state.verified_dom)) return error.ExecutionSelfTestFailed;
    std.log.info("PIZZA_BRIDGE_SELFTEST_READY: real DOM, request/reply and journal replay", .{});
}

fn message(_: wpe.Ptr, value: wpe.Ptr, reply: wpe.Ptr, data: ?*anyopaque) callconv(.c) c_int {
    const s = runtime(data);
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const output = handle(s, a, value) catch |err| {
        s.api.f.webkit_script_message_reply_return_error_message(reply, @errorName(err));
        return 1;
    };
    const text = a.dupeSentinel(u8, output, 0) catch {
        s.api.f.webkit_script_message_reply_return_error_message(reply, "OutOfMemory");
        return 1;
    };
    const result = s.api.f.jsc_value_new_string(s.api.f.jsc_value_get_context(value), text);
    defer s.api.f.g_object_unref(result);
    s.api.f.webkit_script_message_reply_return_value(reply, result);
    return 1;
}
fn handle(s: *Runtime, a: std.mem.Allocator, value: wpe.Ptr) ![]const u8 {
    const current = s.api.f.webkit_web_view_get_uri(s.view) orelse return error.UntrustedDocument;
    if (!std.mem.eql(u8, std.mem.span(current), s.uri)) return error.UntrustedDocument;
    if (s.api.f.jsc_value_is_string(value) == 0) return error.ExpectedBridgeString;
    const raw = s.api.f.jsc_value_to_string(value) orelse return error.ExpectedBridgeString;
    defer s.api.f.g_free(raw);
    const request = try bridge.parse(a, std.mem.span(raw));
    if (request.method == .execution and s.backend.execution().status == .running) s.observed_running = true;
    if (s.options.self_test) std.log.info("Bridge fixture: method={t}, after={s}", .{ request.method, request.after });
    const output = try s.backend.reply(a, request);
    s.methods |= @as(u8, 1) << @intCast(@backingInt(request.method));
    if (request.method == .subscribe) {
        const batch = try s.backend.events(a, try bridge.cursor(request.after));
        s.cursor = batch.last;
        s.generation +%= 1;
        s.subscribed = true;
    }
    const all_methods = (@as(u8, 1) << (comptime std.meta.fieldNames(proto.wire.BridgeMethod)).len) - 1;
    if (request.method == .ready and try bridge.cursor(request.after) == s.backend.lastSequence() and s.methods == all_methods) s.ready = true;
    return output;
}

fn policy(_: wpe.Ptr, decision: wpe.Ptr, kind: c_int, data: ?*anyopaque) callconv(.c) c_int {
    const s = runtime(data);
    if (kind != 0 and kind != 1) return 0;
    const action = s.api.f.webkit_navigation_policy_decision_get_navigation_action(decision);
    const request = s.api.f.webkit_navigation_action_get_request(action);
    const uri = s.api.f.webkit_uri_request_get_uri(request);
    if (kind == 1 or !std.mem.eql(u8, std.mem.span(uri), s.uri)) {
        s.api.f.webkit_policy_decision_ignore(decision);
        return 1;
    }
    return 0;
}
fn terminated(_: wpe.Ptr, _: c_int, data: ?*anyopaque) callconv(.c) void {
    const s = runtime(data);
    s.subscribed = false;
    s.generation +%= 1;
    std.log.err("WPE renderer terminated; maintenance backend remains alive", .{});
    if (s.options.self_test) s.failed = true;
}
fn loadFailed(_: wpe.Ptr, _: c_int, _: [*:0]const u8, _: wpe.Ptr, data: ?*anyopaque) callconv(.c) c_int {
    const s = runtime(data);
    std.log.err("Maintenance panel load failed", .{});
    if (s.options.self_test) s.failed = true;
    return 1;
}
fn loadChanged(_: wpe.Ptr, stage: c_int, data: ?*anyopaque) callconv(.c) void {
    std.log.info("Bridge fixture: load stage={d}", .{stage});
    if (stage == 3) {
        const s = runtime(data);
        const script = "JSON.stringify({status:document.querySelector('#status')?.textContent,bridge:typeof globalThis.webkit?.messageHandlers?.pizza,resources:performance.getEntriesByType('resource').map(x=>x.name)})";
        s.api.f.webkit_web_view_evaluate_javascript(s.view, script, -1, null, null, null, inspectPage, s);
    }
}
fn inspectPage(_: wpe.Ptr, result: wpe.Ptr, data: ?*anyopaque) callconv(.c) void {
    const s = runtime(data);
    var err: wpe.Optional = null;
    if (s.api.f.webkit_web_view_evaluate_javascript_finish(s.view, result, &err)) |value| {
        defer s.api.f.g_object_unref(value);
        if (s.api.f.jsc_value_to_string(value)) |text| {
            defer s.api.f.g_free(text);
            std.log.info("Bridge fixture: DOM {s}", .{std.mem.span(text)});
        }
    }
    if (err) |e| s.api.f.g_error_free(e);
}
fn tick(data: ?*anyopaque) callconv(.c) c_int {
    const s = runtime(data);
    if (s.backend.cancelled) {
        s.api.f.g_main_loop_quit(s.loop);
        return 1;
    }
    const terminal = if (s.backend.executor) |executor| executor.terminal() else true;
    const delivered = s.ready and !s.inflight and s.cursor == s.backend.lastSequence() and s.execution_revision == s.backend.revision();
    const expired = std.Io.Timestamp.now(s.io, .awake).nanoseconds >= s.deadline;
    if (s.options.self_test and s.backend.executor != null and terminal and delivered and !expired and !s.failed and !s.verified_dom) {
        if (!s.verifying_dom) {
            s.verifying_dom = true;
            var buffer: [512]u8 = undefined;
            const view = s.backend.execution();
            const script = std.fmt.bufPrintSentinel(&buffer, "document.querySelector('progress').value === {d} && document.documentElement.dataset.executionStatus === '{t}'", .{ view.committed, view.status }, 0) catch unreachable;
            s.api.f.webkit_web_view_evaluate_javascript(s.view, script, -1, null, null, null, verifyExecutionDom, s);
        }
        return 1;
    }
    if (s.options.self_test and (s.failed or (terminal and delivered) or expired)) {
        s.api.f.g_main_loop_quit(s.loop);
        return 1;
    }
    pump(s) catch |err| {
        if (err == error.WouldBlock) return 1;
        if (!s.journal_failed) std.log.err("Native event delivery degraded: {t}", .{err});
        s.journal_failed = true;
        const script = "globalThis.__pizzaBridgeError?.('日志暂时不可用，维护后端仍在运行')";
        s.api.f.webkit_web_view_evaluate_javascript(s.view, script, -1, null, null, null, null, null);
        if (s.options.self_test) s.failed = true;
    };
    return 1;
}
fn verifyExecutionDom(_: wpe.Ptr, result: wpe.Ptr, data: ?*anyopaque) callconv(.c) void {
    const s = runtime(data);
    var err: wpe.Optional = null;
    if (s.api.f.webkit_web_view_evaluate_javascript_finish(s.view, result, &err)) |value| {
        defer s.api.f.g_object_unref(value);
        if (s.api.f.jsc_value_to_string(value)) |text| {
            defer s.api.f.g_free(text);
            s.verified_dom = std.mem.eql(u8, std.mem.span(text), "true");
        }
    }
    if (err) |e| s.api.f.g_error_free(e);
    if (!s.verified_dom) s.failed = true else std.log.info("PIZZA_EXECUTOR_DOM_READY: progress={d}; state={t}", .{ s.backend.execution().committed, s.backend.execution().status });
}
fn pump(s: *Runtime) !void {
    try s.backend.tick(s.io);
    if (s.backend.snapshot) |snapshot| if (snapshot.tail != .clean) return error.JournalDamagedTail;
    if (!s.subscribed or s.inflight) return;
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const batch = try s.backend.events(a, s.cursor);
    if (batch.count == 0 and s.execution_revision == s.backend.revision()) return;
    const code = try a.print("globalThis.__pizzaDeliverEvents({s});globalThis.__pizzaExecutionState({s});", .{ batch.json, try std.json.Stringify.valueAlloc(a, s.backend.execution(), .{}) });
    const script = try a.dupeSentinel(u8, code, 0);
    s.inflight = true;
    s.pending_cursor = batch.last;
    s.pending_generation = s.generation;
    s.pending_revision = s.backend.revision();
    s.api.f.webkit_web_view_evaluate_javascript(s.view, script, @intCast(code.len), null, null, null, evaluated, s);
}
fn evaluated(_: wpe.Ptr, result: wpe.Ptr, data: ?*anyopaque) callconv(.c) void {
    const s = runtime(data);
    var err: wpe.Optional = null;
    if (s.api.f.webkit_web_view_evaluate_javascript_finish(s.view, result, &err)) |value| {
        s.api.f.g_object_unref(value);
        if (s.pending_generation == s.generation) {
            s.cursor = s.pending_cursor;
            s.execution_revision = s.pending_revision;
        }
    }
    if (err) |e| s.api.f.g_error_free(e);
    s.inflight = false;
}
