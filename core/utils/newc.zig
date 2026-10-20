//! Streaming deterministic SVR4 newc writer (the Linux initramfs archive format).
const std = @import("std");
pub const Writer = struct {
    output: *std.Io.Writer,
    offset: u64 = 0,
    inode: u32 = 1,
    pub fn header(self: *Writer, name: []const u8, mode: u32, size: u64, major: u32, minor: u32) !void {
        if (size > std.math.maxInt(u32) or name.len >= std.math.maxInt(u32) or std.mem.indexOfScalar(u8, name, 0) != null) return error.NewcFieldTooLarge;
        try self.output.writeAll("070701");
        for ([_]u32{ self.inode, mode, 0, 0, 1, 0, @intCast(size), 0, 0, major, minor, @intCast(name.len + 1), 0 }) |value| try self.output.print("{x:0>8}", .{value});
        try self.output.writeAll(name);
        try self.output.writeByte(0);
        self.offset += 110 + name.len + 1;
        try self.pad(4);
        self.inode = std.math.add(u32, self.inode, 1) catch return error.TooManyArchiveEntries;
    }
    pub fn endData(self: *Writer, size: u64) !void {
        self.offset += size;
        try self.pad(4);
    }
    fn pad(self: *Writer, alignment: u64) !void {
        const n: usize = @intCast((alignment - self.offset % alignment) % alignment);
        try self.output.splatByteAll(0, n);
        self.offset += n;
    }
    pub fn finish(self: *Writer) !void {
        try self.header("TRAILER!!!", 0, 0, 0, 0);
        try self.pad(512);
    }
};
