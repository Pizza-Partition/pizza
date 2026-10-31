const std = @import("std");
pub const Bindings = @import("linux/bindings.zig");

/// GTK integration corrections for the pinned WebUI source.
/// GTK gboolean is a C int, whereas WebUI declares this callback as C bool.
/// In debug x86-64 builds the upper return-register bytes can remain nonzero,
/// causing GTK to interpret FALSE as TRUE and refuse every window-manager close.
/// Generate a corrected source in the build cache; never mutate zig fetch data.
pub fn patch(b: *std.Build, wrapper: *std.Build.Module) !void {
    for (wrapper.link_objects.items) |object| {
        if (object != .other_step) continue;
        const library = object.other_step;
        if (!std.mem.eql(u8, library.name, "webui")) continue;
        for (library.root_module.link_objects.items) |link| {
            if (link != .c_source_file) continue;
            const source = link.c_source_file;
            if (source.file != .src_path) continue;
            const path = source.file.src_path;
            if (!std.mem.eql(u8, path.sub_path, "src/webui.c")) continue;
            b.dependOnFileContents(source.file);
            const original = try path.owner.root.root_dir.handle.readFileAlloc(b.graph.io, path.sub_path, b.allocator, .limited(2 * 1024 * 1024));
            const before = "static bool _webui_wv_event_on_close(";
            // Forward declaration and definition must agree.
            if (std.mem.count(u8, original, before) != 2) return error.WebuiGtkPatchNeedsReview;
            const corrected = try std.mem.replaceOwned(u8, b.allocator, original, before, "static int _webui_wv_event_on_close(");
            const gtk_init = "gtk_init(NULL, NULL);";
            if (std.mem.count(u8, corrected, gtk_init) != 1) return error.WebuiGtkPatchNeedsReview;
            // Apply process-local text settings on GTK's own thread before the
            // WebView exists. GTK remains a runtime-loaded system dependency.
            const configured = try std.mem.replaceOwned(u8, b.allocator, corrected, gtk_init,
                \\gtk_init(NULL, NULL);
                \\            {
                \\                void *(*get_settings)(void) = (void *(*)(void))dlsym(libgtk, "gtk_settings_get_default");
                \\                extern void pizza_configure_gtk_text(void *settings);
                \\                if (get_settings)
                \\                    pizza_configure_gtk_text(get_settings());
                \\            }
            );
            // Preserve relative includes from the original source directory.
            library.root_module.addIncludePath(source.file.dirname());
            source.file = b.addWriteFiles().add("webui.c", configured);
            return;
        }
    }
    return error.WebuiGtkSourceNotFound;
}
