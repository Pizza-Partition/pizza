const std = @import("std");

pub const BuildOptions = @import("image.zig").Options;
pub const build = @import("image.zig").build;

pub const Entry = @import("archive.zig").Entry;
pub const archive = @import("archive.zig").archive;
pub const console = @import("archive.zig").console;
pub const staticInit = @import("archive.zig").staticInit;

test {
    @import("std").testing.refAllDecls(@import("archive.zig"));
}
