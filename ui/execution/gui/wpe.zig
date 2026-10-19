//! Minimal stable WPE 2.0 C ABI, loaded at runtime. No WPE dependency enters PID 1
//! or the build host. Function signatures are checked against WPE 2.54 headers.
const std = @import("std");
pub const Object = opaque {};
pub const Ptr = *Object;
pub const Optional = ?Ptr;
pub const Async = *const fn (Ptr, Ptr, ?*anyopaque) callconv(.c) void;
pub const Source = *const fn (?*anyopaque) callconv(.c) c_int;
const Fn = struct {
    g_object_new: *const fn (usize, ?[*:0]const u8, ...) callconv(.c) Optional,
    g_object_unref: *const fn (Ptr) callconv(.c) void,
    g_free: *const fn (?*anyopaque) callconv(.c) void,
    g_error_free: *const fn (Ptr) callconv(.c) void,
    g_signal_connect_data: *const fn (Ptr, [*:0]const u8, *const anyopaque, ?*anyopaque, ?*const anyopaque, c_int) callconv(.c) c_ulong,
    g_main_loop_new: *const fn (Optional, c_int) callconv(.c) Ptr,
    g_main_loop_run: *const fn (Ptr) callconv(.c) void,
    g_main_loop_quit: *const fn (Ptr) callconv(.c) void,
    g_main_loop_unref: *const fn (Ptr) callconv(.c) void,
    g_timeout_add: *const fn (c_uint, Source, ?*anyopaque) callconv(.c) c_uint,
    g_source_remove: *const fn (c_uint) callconv(.c) c_int,
    webkit_network_session_new_ephemeral: *const fn () callconv(.c) Ptr,
    webkit_web_context_new: *const fn () callconv(.c) Ptr,
    webkit_web_context_add_path_to_sandbox: *const fn (Ptr, [*:0]const u8, c_int) callconv(.c) void,
    webkit_web_view_get_type: *const fn () callconv(.c) usize,
    webkit_web_view_get_user_content_manager: *const fn (Ptr) callconv(.c) Ptr,
    webkit_web_view_get_settings: *const fn (Ptr) callconv(.c) Ptr,
    webkit_settings_set_allow_file_access_from_file_urls: *const fn (Ptr, c_int) callconv(.c) void,
    webkit_settings_set_enable_write_console_messages_to_stdout: *const fn (Ptr, c_int) callconv(.c) void,
    webkit_web_view_get_wpe_view: *const fn (Ptr) callconv(.c) Ptr,
    webkit_web_view_get_uri: *const fn (Ptr) callconv(.c) ?[*:0]const u8,
    webkit_web_view_load_uri: *const fn (Ptr, [*:0]const u8) callconv(.c) void,
    webkit_web_view_evaluate_javascript: *const fn (Ptr, [*:0]const u8, isize, ?[*:0]const u8, ?[*:0]const u8, Optional, ?Async, ?*anyopaque) callconv(.c) void,
    webkit_web_view_evaluate_javascript_finish: *const fn (Ptr, Ptr, *Optional) callconv(.c) Optional,
    webkit_user_content_manager_register_script_message_handler_with_reply: *const fn (Ptr, [*:0]const u8, ?[*:0]const u8) callconv(.c) c_int,
    webkit_script_message_reply_return_value: *const fn (Ptr, Ptr) callconv(.c) void,
    webkit_script_message_reply_return_error_message: *const fn (Ptr, [*:0]const u8) callconv(.c) void,
    webkit_navigation_policy_decision_get_navigation_action: *const fn (Ptr) callconv(.c) Ptr,
    webkit_navigation_action_get_request: *const fn (Ptr) callconv(.c) Ptr,
    webkit_uri_request_get_uri: *const fn (Ptr) callconv(.c) [*:0]const u8,
    webkit_policy_decision_ignore: *const fn (Ptr) callconv(.c) void,
    jsc_value_is_string: *const fn (Ptr) callconv(.c) c_int,
    jsc_value_to_string: *const fn (Ptr) callconv(.c) ?[*:0]u8,
    jsc_value_get_context: *const fn (Ptr) callconv(.c) Ptr,
    jsc_value_new_string: *const fn (Ptr, [*:0]const u8) callconv(.c) Ptr,
    wpe_view_resized: *const fn (Ptr, c_int, c_int) callconv(.c) void,
    wpe_view_set_visible: *const fn (Ptr, c_int) callconv(.c) void,
    wpe_view_get_toplevel: *const fn (Ptr) callconv(.c) Optional,
    wpe_toplevel_fullscreen: *const fn (Ptr) callconv(.c) c_int,
};

pub const Api = struct {
    library: std.DynLib,
    f: Fn,
    pub fn open(path: []const u8) !Api {
        var lib = std.DynLib.open(path) catch |err| {
            std.log.err("Load WPE library {s}: {t}", .{ path, err });
            return err;
        };
        errdefer lib.close();
        var f: Fn = undefined;
        inline for (comptime std.meta.fieldNames(Fn)) |name| {
            @field(f, name) = lib.lookup(@TypeOf(@field(f, name)), name) orelse {
                std.log.err("Missing WPE 2.0 symbol {s}", .{name});
                return error.UnsupportedWpeAbi;
            };
        }
        return .{ .library = lib, .f = f };
    }
    pub fn close(self: *Api) void {
        self.library.close();
    }
};
