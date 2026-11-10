//! sd-device ownership and read-only access to kernel attributes and udev properties.
const std = @import("std");
const libc = @import("libc");
const sd = @import("libsystemd");

fn check(result: c_int) !void {
    if (result >= 0) return;
    return switch (-result) {
        libc.ENOMEM => error.OutOfMemory,
        libc.ENOENT => error.FileNotFound,
        libc.ENODEV => error.DeviceNotFound,
        libc.ENXIO => error.NoDevice,
        libc.EACCES, libc.EPERM => error.AccessDenied,
        libc.EIO => error.InputOutput,
        libc.EINVAL => error.InvalidDevice,
        else => error.DeviceQueryFailed,
    };
}

pub const Device = struct {
    handle: *sd.sd_device,

    /// Owns one reference, released by deinit.
    pub fn fromDevname(path: [:0]const u8) !Device {
        var handle: ?*sd.sd_device = null;
        try check(sd.sd_device_new_from_devname(&handle, path));
        return .{ .handle = handle.? };
    }

    pub fn deinit(self: Device) void {
        _ = sd.sd_device_unref(self.handle);
    }

    /// Returned text and parent objects are borrowed until this device is released.
    pub fn syspath(self: Device) ![]const u8 {
        var value: [*c]const u8 = null;
        try check(sd.sd_device_get_syspath(self.handle, &value));
        return std.mem.span(value);
    }

    pub fn devname(self: Device) ![:0]const u8 {
        var value: [*c]const u8 = null;
        try check(sd.sd_device_get_devname(self.handle, &value));
        return std.mem.span(value);
    }

    pub fn sysname(self: Device) ![]const u8 {
        var value: [*c]const u8 = null;
        try check(sd.sd_device_get_sysname(self.handle, &value));
        return std.mem.span(value);
    }

    pub fn parent(self: Device) !?Device {
        var handle: ?*sd.sd_device = null;
        const result = sd.sd_device_get_parent(self.handle, &handle);
        if (result == -libc.ENOENT) return null;
        try check(result);
        return .{ .handle = handle.? };
    }

    /// Only a missing attribute is optional. Empty values and read errors remain distinct.
    pub fn attribute(self: Device, key: [:0]const u8) !?[]const u8 {
        var value: [*c]const u8 = null;
        const result = sd.sd_device_get_sysattr_value(self.handle, key, &value);
        if (result == -libc.ENOENT) return null;
        try check(result);
        return std.mem.trim(u8, std.mem.span(value), &std.ascii.whitespace);
    }

    pub fn number(self: Device, key: [:0]const u8) !u64 {
        const value = (try self.attribute(key)) orelse return error.MissingDeviceAttribute;
        if (value.len == 0) return error.EmptyDeviceAttribute;
        return std.fmt.parseInt(u64, value, 10);
    }

    pub fn property(self: Device, key: [:0]const u8) !?[]const u8 {
        var value: [*c]const u8 = null;
        const result = sd.sd_device_get_property_value(self.handle, key, &value);
        if (result == -libc.ENOENT) return null;
        try check(result);
        return std.mem.span(value);
    }
};

pub const Enumerator = struct {
    handle: *sd.sd_device_enumerator,
    started: bool = false,

    pub fn init(devtype: [:0]const u8, parent: ?Device) !Enumerator {
        var handle: ?*sd.sd_device_enumerator = null;
        try check(sd.sd_device_enumerator_new(&handle));
        const self: Enumerator = .{ .handle = handle.? };
        errdefer self.deinit();
        try check(sd.sd_device_enumerator_add_match_subsystem(self.handle, "block", 1));
        try check(sd.sd_device_enumerator_add_match_property(self.handle, "DEVTYPE", devtype));
        // Kernel devices remain visible before udev has populated optional properties.
        try check(sd.sd_device_enumerator_allow_uninitialized(self.handle));
        if (parent) |device| try check(sd.sd_device_enumerator_add_match_parent(self.handle, device.handle));
        return self;
    }

    pub fn deinit(self: Enumerator) void {
        _ = sd.sd_device_enumerator_unref(self.handle);
    }

    /// Devices are borrowed from the enumerator; callers must copy retained strings.
    pub fn next(self: *Enumerator) ?Device {
        const handle = if (self.started)
            sd.sd_device_enumerator_get_device_next(self.handle)
        else
            sd.sd_device_enumerator_get_device_first(self.handle);
        self.started = true;
        return .{ .handle = handle orelse return null };
    }
};

test "sd-device errors preserve missing attributes and read failures" {
    try check(0);
    try std.testing.expectError(error.FileNotFound, check(-libc.ENOENT));
    try std.testing.expectError(error.NoDevice, check(-libc.ENXIO));
    try std.testing.expectError(error.InputOutput, check(-libc.EIO));
    try std.testing.expectError(error.OutOfMemory, check(-libc.ENOMEM));
    try std.testing.expectError(error.AccessDenied, check(-libc.EACCES));
}

test "sd-device enumerates whole disks and their partition children separately" {
    var disks = try Enumerator.init("disk", null);
    defer disks.deinit();
    var found = false;
    while (disks.next()) |disk| {
        found = true;
        try std.testing.expectEqualStrings("disk", (try disk.property("DEVTYPE")).?);
        try std.testing.expect(std.mem.startsWith(u8, try disk.syspath(), "/sys/devices/"));
        try std.testing.expect(std.mem.startsWith(u8, try disk.devname(), "/dev/"));
        _ = try disk.number("size");
        try std.testing.expect((try disk.number("queue/logical_block_size")) > 0);
        try std.testing.expect((try disk.number("ro")) <= 1);
        try std.testing.expect((try disk.attribute("pizza_missing_test_attribute")) == null);
        var partitions = try Enumerator.init("partition", disk);
        defer partitions.deinit();
        while (partitions.next()) |child| {
            try std.testing.expectEqualStrings("partition", (try child.property("DEVTYPE")).?);
            const parent = (try child.parent()).?;
            try std.testing.expectEqualStrings(try disk.syspath(), try parent.syspath());
            try std.testing.expect((try child.number("partition")) > 0);
            const owned = try Device.fromDevname(try child.devname());
            defer owned.deinit();
            try std.testing.expectEqualStrings(try child.syspath(), try owned.syspath());
        }
    }
    if (!found) return error.SkipZigTest;
}
