const std = @import("std");

pub const SEGMENT_BYTES: u64 = 2 * 1024 * 1024;

pub const Mount = struct {
    device: []const u8,
    dir: []const u8,
};

pub const Band = struct {
    low: u64,
    high: u64,
};

pub fn f2fsMount(mounts: []const u8) ?Mount {
    var lines = std.mem.tokenizeScalar(u8, mounts, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const source = fields.next() orelse continue;
        const dir = fields.next() orelse continue;
        const kind = fields.next() orelse continue;
        if (!std.mem.eql(u8, kind, "f2fs") or !std.mem.startsWith(u8, source, "/dev/")) continue;
        return .{ .device = source[(std.mem.lastIndexOfScalar(u8, source, '/') orelse 0) + 1 ..], .dir = dir };
    }
    return null;
}

pub fn band(total: u64, available: u64) Band {
    return .{
        .low = @min(total * 8 / 100, available * 40 / 100),
        .high = @min(total * 12 / 100, available * 60 / 100),
    };
}

pub fn collect(running: bool, free: u64, b: Band) bool {
    if (free < b.low) return true;
    if (free >= b.high) return false;
    return running;
}

pub fn fullPressure(text: []const u8) f64 {
    const line = std.mem.indexOf(u8, text, "full avg10=") orelse return 0;
    const start = line + "full avg10=".len;
    const end = std.mem.indexOfScalarPos(u8, text, start, ' ') orelse return 0;
    return std.fmt.parseFloat(f64, text[start..end]) catch 0;
}

test "picks the first f2fs block device" {
    const m = f2fsMount(
        \\/dev/root / erofs ro 0 0
        \\tmpfs /run tmpfs rw 0 0
        \\/dev/nvme0n1p2 /var f2fs rw,discard 0 0
        \\/dev/nvme0n1p2 /home f2fs rw,discard 0 0
    ).?;
    try std.testing.expectEqualStrings("nvme0n1p2", m.device);
    try std.testing.expectEqualStrings("/var", m.dir);
    try std.testing.expect(f2fsMount("/dev/sda1 / ext4 rw 0 0\n") == null);
}

test "keeps collecting inside the band and stops above it" {
    const b = band(243464, 52262);
    try std.testing.expectEqual(@as(u64, 19477), b.low);
    try std.testing.expectEqual(@as(u64, 29215), b.high);
    try std.testing.expect(collect(false, 1000, b));
    try std.testing.expect(collect(true, 20000, b));
    try std.testing.expect(!collect(false, 20000, b));
    try std.testing.expect(!collect(true, 29215, b));
}

test "a nearly full disk leaves room for user data" {
    const b = band(243464, 1000);
    try std.testing.expectEqual(@as(u64, 400), b.low);
    try std.testing.expectEqual(@as(u64, 600), b.high);
}

test "reads full pressure" {
    const psi = "some avg10=47.59 avg60=62.49 avg300=34.00 total=1\nfull avg10=37.56 avg60=51.31 avg300=27.90 total=1\n";
    try std.testing.expectEqual(@as(f64, 37.56), fullPressure(psi));
    try std.testing.expectEqual(@as(f64, 0), fullPressure("garbage"));
}
