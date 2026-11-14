//! Platform ports for the active reboot maintenance controller.
const std = @import("std");
const proto = @import("proto");
pub const Digest = [32]u8;
pub const digest = proto.firmware_pin.digest;
pub const Binding = proto.firmware_pin.FirmwarePin(MAX_MANIFEST_BYTES);
pub const MAX_MANIFEST_BYTES = 256 * 1024 * 1024;
pub const File = enum { image, manifest, lease, receipt, request, anchor };
/// Application-facing port. The platform owns trusted artifacts, its protected
/// pending record, ESP admission and the actual reboot mechanism.
pub const Controller = struct {
    available: bool = true,
    context: *anyopaque,
    prepare: *const fn (*anyopaque, std.mem.Allocator, std.Io, proto.wire.InventorySnapshot, proto.wire.ValidatedPlan) anyerror!proto.wire.MaintenanceSession,
    reboot: *const fn (*anyopaque, std.mem.Allocator, std.Io, []const u8, []const u8) anyerror!proto.wire.MaintenanceSession,
    complete: *const fn (*anyopaque, std.mem.Allocator, std.Io, ?[]const u8) anyerror!proto.wire.CompletionReceipt,
    pending: *const fn (*anyopaque) anyerror!bool,
    discover: *const fn (*anyopaque, std.mem.Allocator, std.Io) anyerror!?proto.wire.MaintenanceSession,
    cancel: *const fn (*anyopaque, std.mem.Allocator, std.Io, []const u8, ?[]const u8) anyerror!?proto.wire.MaintenanceSession,
    /// Explicit test/demo port; production installs its platform controller.
    pub fn unavailable(context: *anyopaque) Controller {
        return .{ .available = false, .context = context, .prepare = unavailablePrepare, .reboot = unavailableReboot, .complete = unavailableComplete, .pending = noPending, .discover = noDiscovery, .cancel = noCancellation };
    }
    fn unavailablePrepare(_: *anyopaque, _: std.mem.Allocator, _: std.Io, _: proto.wire.InventorySnapshot, _: proto.wire.ValidatedPlan) !proto.wire.MaintenanceSession {
        return error.MaintenancePreparationUnavailable;
    }
    fn unavailableReboot(_: *anyopaque, _: std.mem.Allocator, _: std.Io, _: []const u8, _: []const u8) !proto.wire.MaintenanceSession {
        return error.MaintenancePreparationUnavailable;
    }
    fn unavailableComplete(_: *anyopaque, _: std.mem.Allocator, _: std.Io, _: ?[]const u8) !proto.wire.CompletionReceipt {
        return error.NoCompletionReceipt;
    }
    fn noPending(_: *anyopaque) !bool {
        return false;
    }
    fn noDiscovery(_: *anyopaque, _: std.mem.Allocator, _: std.Io) !?proto.wire.MaintenanceSession {
        return null;
    }
    fn noCancellation(_: *anyopaque, _: std.mem.Allocator, _: std.Io, _: []const u8, _: ?[]const u8) !?proto.wire.MaintenanceSession {
        return null;
    }
};
pub const Store = struct {
    context: *anyopaque,
    /// Publish must reserve real space, sync bytes and publication metadata.
    /// read() rechecks the device and the file's allocation/ownership evidence.
    /// All allocations must be finalized before the manifest's FAT allocation
    /// proof is captured; publication may not change that frozen FAT layout.
    publish: *const fn (*anyopaque, std.Io, File, []const u8) anyerror!void,
    read: *const fn (*anyopaque, std.mem.Allocator, std.Io, File) anyerror!?[]const u8,
};
pub const decodeReceiptEnvelope = proto.receipt_envelope.decode;
