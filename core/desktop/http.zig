const std = @import("std");

pub fn contentType(path: []const u8) []const u8 {
    const types = .{
        .{ ".js", "text/javascript" },
        .{ ".css", "text/css" },
        .{ ".svg", "image/svg+xml" },
        .{ ".ttf", "font/ttf" },
        .{ ".woff", "font/woff" },
        .{ ".woff2", "font/woff2" },
        .{ ".png", "image/png" },
    };
    inline for (types) |entry| {
        if (std.mem.endsWith(u8, path, entry[0])) return entry[1];
    }
    return "text/html";
}

test "embedded fonts have font MIME types under nosniff" {
    try std.testing.expectEqualStrings("font/ttf", contentType("assets/fonts/DMSans.ttf"));
    try std.testing.expectEqualStrings("font/ttf", contentType("assets/fonts/CormorantGaramond.ttf"));
    try std.testing.expectEqualStrings("font/woff2", contentType("assets/font.woff2"));
    try std.testing.expectEqualStrings("text/css", contentType("style.css"));
    try std.testing.expectEqualStrings("text/html", contentType("index.html"));
}

pub fn response(path: []const u8) ?[]const u8 {
    const webui = @import("webui");
    const proto = @import("proto");
    const Assets = webui.EmbeddedFS(@import("embedded_assets"));
    const p = if (std.mem.startsWith(u8, path, "/")) path[1..] else path;
    const body = if (std.mem.eql(u8, p, "protocol/contract.js")) proto.JAVASCRIPT_BINDING else Assets.get(p) orelse return "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n";
    const mime = contentType(p);
    var header_buf: [256]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nX-Content-Type-Options: nosniff\r\n\r\n", .{ mime, body.len }) catch return null;
    const bytes = webui.malloc(header.len + body.len) catch return null;
    @memcpy(bytes[0..header.len], header);
    @memcpy(bytes[header.len..], body);
    return bytes;
}
