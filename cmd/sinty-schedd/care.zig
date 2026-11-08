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
        .low = @min(total * 10 / 100, available * 40 / 100),
        .high = @min(total * 15 / 100, available * 60 / 100),
    };
}

pub fn collect(running: bool, free: u64, b: Band) bool {
    if (free < b.low) return true;
    if (free >= b.high) return false;
    return running;
}

pub fn collectOnBattery(running: bool, free: u64, b: Band) bool {
    if (free < b.low / 4) return true;
    if (free >= b.low) return false;
    return running;
}

pub fn onMains(supplies: []const []const u8) bool {
    var battery = false;
    for (supplies) |entry| {
        var parts = std.mem.splitScalar(u8, entry, ' ');
        const kind = parts.next() orelse continue;
        const online = parts.next() orelse "";
        if ((std.mem.eql(u8, kind, "Mains") or std.mem.eql(u8, kind, "USB")) and std.mem.eql(u8, online, "1")) return true;
        if (std.mem.eql(u8, kind, "Battery")) battery = true;
    }
    return !battery;
}

pub fn fullPressure(text: []const u8) f64 {
    const line = std.mem.indexOf(u8, text, "full avg10=") orelse return 0;
    const start = line + "full avg10=".len;
    const end = std.mem.indexOfScalarPos(u8, text, start, ' ') orelse return 0;
    return std.fmt.parseFloat(f64, text[start..end]) catch 0;
}

pub fn nvmeController(device: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, device, "nvme")) return null;
    const end = std.mem.indexOfScalarPos(u8, device, 4, 'n') orelse return null;
    return if (end > 4) device[0..end] else null;
}

fn le16(data: []const u8, at: usize) u32 {
    return std.mem.readInt(u16, data[at..][0..2], .little);
}

fn le32(data: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, data[at..][0..4], .little);
}

pub fn nvmeReport(out: []u8, identify: *const [4096]u8, health: *const [512]u8) ?[]const u8 {
    const mdts: u32 = identify[77];
    return std.fmt.bufPrint(out,
        \\max_transfer_kib={d}
        \\hmb_preferred_kib={d}
        \\hmb_minimum_kib={d}
        \\power_states={d}
        \\autonomous_power={d}
        \\warning_kelvin={d}
        \\critical_kelvin={d}
        \\optional_commands=0x{x}
        \\volatile_cache={d}
        \\throttle_light_count={d}
        \\throttle_heavy_count={d}
        \\throttle_light_seconds={d}
        \\throttle_heavy_seconds={d}
        \\
    , .{
        if (mdts == 0) 0 else @as(u64, 4) << @intCast(@min(mdts, 32)),
        @as(u64, le32(identify, 272)) * 4,
        @as(u64, le32(identify, 276)) * 4,
        @as(u32, identify[263]) + 1,
        identify[265] & 1,
        le16(identify, 266),
        le16(identify, 268),
        le16(identify, 520),
        identify[525] & 1,
        le32(health, 216),
        le32(health, 220),
        le32(health, 224),
        le32(health, 228),
    }) catch null;
}

test "finds the controller of an NVMe partition" {
    try std.testing.expectEqualStrings("nvme0", nvmeController("nvme0n1p2").?);
    try std.testing.expectEqualStrings("nvme12", nvmeController("nvme12n1").?);
    try std.testing.expect(nvmeController("sda1") == null);
    try std.testing.expect(nvmeController("nvme") == null);
}

test "reports the fields of the identify and health pages" {
    var identify = std.mem.zeroes([4096]u8);
    var health = std.mem.zeroes([512]u8);
    identify[77] = 5;
    std.mem.writeInt(u32, identify[272..][0..4], 16384, .little);
    identify[263] = 4;
    identify[265] = 1;
    std.mem.writeInt(u16, identify[266..][0..2], 354, .little);
    std.mem.writeInt(u16, identify[520..][0..2], 0x5f, .little);
    identify[525] = 1;
    std.mem.writeInt(u32, health[216..][0..4], 7, .little);
    var out: [512]u8 = undefined;
    const text = nvmeReport(&out, &identify, &health).?;
    try std.testing.expect(std.mem.indexOf(u8, text, "max_transfer_kib=128\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "hmb_preferred_kib=65536\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "power_states=5\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "warning_kelvin=354\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "optional_commands=0x5f\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "throttle_light_count=7\n") != null);
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
    const b = band(243464, 100000);
    try std.testing.expectEqual(@as(u64, 24346), b.low);
    try std.testing.expectEqual(@as(u64, 36519), b.high);
    try std.testing.expect(collect(false, 1000, b));
    try std.testing.expect(collect(true, 30000, b));
    try std.testing.expect(!collect(false, 30000, b));
    try std.testing.expect(!collect(true, 36519, b));
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

test "on battery collects only when space runs out" {
    const b = Band{ .low = 400, .high = 600 };
    try std.testing.expect(!collectOnBattery(false, 300, b));
    try std.testing.expect(collectOnBattery(false, 90, b));
    try std.testing.expect(collectOnBattery(true, 300, b));
    try std.testing.expect(!collectOnBattery(true, 400, b));
}

test "tells mains from battery" {
    try std.testing.expect(onMains(&.{}));
    try std.testing.expect(onMains(&.{ "Mains 1", "Battery 1" }));
    try std.testing.expect(!onMains(&.{ "Mains 0", "Battery 1" }));
    try std.testing.expect(!onMains(&.{"Battery 1"}));
    try std.testing.expect(onMains(&.{"Mains 0"}));
}
