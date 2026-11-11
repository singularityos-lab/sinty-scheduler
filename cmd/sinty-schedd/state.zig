const std = @import("std");

pub const State = struct {
    enabled: bool = false,

    pub fn parse(text: []const u8) State {
        var s: State = .{};
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            if (std.mem.eql(u8, std.mem.trim(u8, line[0..eq], " "), "enabled"))
                s.enabled = std.mem.eql(u8, std.mem.trim(u8, line[eq + 1 ..], " "), "1");
        }
        return s;
    }

    pub fn serialize(s: State, buf: []u8) [:0]const u8 {
        return std.fmt.bufPrintSentinel(buf, "enabled={d}\n", .{@intFromBool(s.enabled)}, 0) catch unreachable;
    }
};

pub fn listsModule(dep: []const u8) bool {
    var lines = std.mem.tokenizeScalar(u8, dep, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const path = line[0..colon];
        const base = path[(std.mem.lastIndexOfScalar(u8, path, '/') orelse return false) + 1 ..];
        if (std.mem.startsWith(u8, base, "sinty_scheduler.ko")) return true;
    }
    return false;
}

pub fn localUser(uid: u32) bool {
    return uid >= 1000 and uid < 60000;
}

pub fn eligibleDisk(name: []const u8) bool {
    for ([_][]const u8{ "loop", "ram", "zram", "dm-", "md", "sr", "fd", "nbd" }) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) return false;
    }
    return true;
}

pub fn activeScheduler(text: []const u8) ?[]const u8 {
    const open = std.mem.indexOfScalar(u8, text, '[') orelse return null;
    const close = std.mem.indexOfScalarPos(u8, text, open, ']') orelse return null;
    return text[open + 1 .. close];
}

pub fn pathAllowed(uid: u32, path: []const u8) bool {
    var buf: [64]u8 = undefined;
    const prefix = std.fmt.bufPrint(&buf, "/user.slice/user-{d}.slice/", .{uid}) catch return false;
    if (!std.mem.startsWith(u8, path, prefix) or path.len == prefix.len) return false;
    var parts = std.mem.tokenizeScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".")) return false;
    }
    return std.mem.indexOfAny(u8, path, " \n\t") == null;
}

pub fn validClass(name: []const u8) bool {
    return std.mem.eql(u8, name, "interactive") or std.mem.eql(u8, name, "normal") or std.mem.eql(u8, name, "background");
}

fn scopeChar(ch: u8) u8 {
    return switch (ch) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '-', '_' => ch,
        else => '_',
    };
}

fn sameApp(entry: []const u8, id: []const u8) bool {
    const app = if (std.mem.endsWith(u8, entry, ".desktop")) entry[0 .. entry.len - 8] else entry;
    if (app.len != id.len) return false;
    for (app, id) |a, b| {
        if (scopeChar(a) != b) return false;
    }
    return true;
}

pub fn fsyncHeavy(list: []const u8, path: []const u8) bool {
    const leaf = path[(std.mem.lastIndexOfScalar(u8, path, '/') orelse return false) + 1 ..];
    if (!std.mem.startsWith(u8, leaf, "app-") or !std.mem.endsWith(u8, leaf, ".scope")) return false;
    const id = leaf[4 .. leaf.len - 6];
    if (id.len == 0) return false;
    var lines = std.mem.tokenizeScalar(u8, list, '\n');
    while (lines.next()) |line| {
        const entry = std.mem.trim(u8, line, " \t\r");
        if (entry.len == 0 or entry[0] == '#') continue;
        if (sameApp(entry, id)) return true;
    }
    return false;
}

test "state survives a round trip" {
    var buf: [32]u8 = undefined;
    try std.testing.expect(State.parse((State{ .enabled = true }).serialize(&buf)).enabled);
    try std.testing.expect(!State.parse("").enabled);
}

test "module lookup finds the module and nothing else" {
    try std.testing.expect(listsModule("extra/sinty_scheduler.ko:\n"));
    try std.testing.expect(!listsModule("kernel/block/kyber-iosched.ko:\n"));
}

test "only real disks are eligible" {
    try std.testing.expect(eligibleDisk("nvme0n1"));
    try std.testing.expect(eligibleDisk("sda"));
    try std.testing.expect(!eligibleDisk("loop3"));
    try std.testing.expect(!eligibleDisk("dm-0"));
    try std.testing.expect(!eligibleDisk("zram0"));
}

test "the active scheduler is the bracketed one" {
    try std.testing.expectEqualStrings("none", activeScheduler("[none] sinty kyber\n").?);
    try std.testing.expectEqualStrings("sinty", activeScheduler("none [sinty]\n").?);
    try std.testing.expect(activeScheduler("none\n") == null);
}

test "a user can only classify cgroups of their own slice" {
    try std.testing.expect(pathAllowed(1001, "/user.slice/user-1001.slice/app-x.scope"));
    try std.testing.expect(!pathAllowed(1001, "/user.slice/user-1002.slice/app-x.scope"));
    try std.testing.expect(!pathAllowed(1001, "/user.slice/user-1001.slice/"));
    try std.testing.expect(!pathAllowed(1001, "/user.slice/user-1001.slice/../../system.slice"));
    try std.testing.expect(!pathAllowed(1001, "/user.slice/user-1001.slice/a b"));
    try std.testing.expect(!pathAllowed(1001, "/system.slice/x"));
}

test "listed apps are flagged as fsync heavy" {
    const list = "# browsers\nfirefox\n  org.chromium.Chromium.desktop \ncom discord\n";
    try std.testing.expect(fsyncHeavy(list, "/user.slice/user-1001.slice/app-firefox.scope"));
    try std.testing.expect(fsyncHeavy(list, "/user.slice/user-1001.slice/app-org.chromium.Chromium.scope"));
    try std.testing.expect(fsyncHeavy(list, "/user.slice/user-1001.slice/app-com_discord.scope"));
    try std.testing.expect(!fsyncHeavy(list, "/user.slice/user-1001.slice/app-firefox-esr.scope"));
    try std.testing.expect(!fsyncHeavy(list, "/user.slice/user-1001.slice/firefox.scope"));
    try std.testing.expect(!fsyncHeavy(list, "/user.slice/user-1001.slice/app-.scope"));
    try std.testing.expect(!fsyncHeavy("#firefox\n", "/user.slice/user-1001.slice/app-firefox.scope"));
}
