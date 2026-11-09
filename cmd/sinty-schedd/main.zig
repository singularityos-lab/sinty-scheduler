const std = @import("std");
const c = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cInclude("gio-import.h");
});
const state = @import("state.zig");
const care = @import("care.zig");

const NAME = "dev.sinty.Scheduler";
const PATH = "/dev/sinty/Scheduler";
const IFACE = "dev.sinty.Scheduler1";
const ACTION = "dev.sinty.scheduler.manage";
const CLASSES = "/sys/kernel/sinty_scheduler/classes";
const CGROUP = "/sys/fs/cgroup";
const NATIVE_ENABLE = "/sys/kernel/sinty_scheduler/enable";
const NATIVE_STATS = "/sys/kernel/sinty_scheduler/stats";
const STATE_FILE = "/var/lib/sinty-scheduler/state";
const SCAN_SECONDS = 2;
const DSH_DEPTH = 4;
const REQUEST_KB = "512";
const CARE_START_SECONDS = 60;
const CARE_SECONDS = 30;
const CARE_BATTERY_SECONDS = 120;
const TRIM_FILE = "/var/lib/sinty-scheduler/trim";
const TRIM_PERIOD_SECONDS = 24 * 3600;
const TRIM_CHUNK_BYTES: u64 = 16 * 1024 * 1024 * 1024;
const TRIM_MIN_BYTES: u64 = 64 * 1024;
const TRIM_PAUSE_SECONDS = 5;
const FITRIM: c_ulong = 0xC0185879;
const BUSY_PRESSURE = 30.0;

const XML =
    \\<node>
    \\  <interface name="dev.sinty.Scheduler1">
    \\    <property name="Installed" type="b" access="read"/>
    \\    <property name="Enabled" type="b" access="read"/>
    \\    <method name="SetEnabled"><arg name="enabled" type="b" direction="in"/></method>
    \\    <method name="SetClasses"><arg name="classes" type="a{ss}" direction="in"/></method>
    \\    <method name="GetStats"><arg name="stats" type="a{sx}" direction="out"/></method>
    \\    <method name="Announce"><arg name="threads" type="au" direction="in"/></method>
    \\    <method name="GetBackground"><arg name="processes" type="a{uau}" direction="out"/></method>
    \\  </interface>
    \\</node>
;

var connection: ?*c.GDBusConnection = null;
var current: state.State = .{};
var scan_source: c.guint = 0;
var marked: ?*c.GHashTable = null;
var request_sizes: ?*c.GHashTable = null;
var announced: ?*c.GHashTable = null;

const Announced = struct {
    pid: u32,
    threads: *c.GArray,
};

const IOPRIO_IDLE: c_long = 3 << 13;

fn vt(s: [*:0]const u8) *const c.GVariantType {
    return @ptrCast(s);
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("sinty-schedd: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn writeFile(path: [*:0]const u8, value: []const u8) bool {
    const f = std.c.open(path, .{ .ACCMODE = .WRONLY });
    if (f < 0) return false;
    defer _ = std.c.close(f);
    return std.c.write(f, value.ptr, value.len) == @as(isize, @intCast(value.len));
}

fn readText(path: [*:0]const u8, buf: []u8) ?[]const u8 {
    var contents: [*c]u8 = null;
    var len: c.gsize = 0;
    if (c.g_file_get_contents(path, &contents, &len, null) == 0) return null;
    defer c.g_free(contents);
    const n = @min(buf.len, len);
    @memcpy(buf[0..n], contents[0..n]);
    return buf[0..n];
}

fn loaded() bool {
    return c.g_file_test(CLASSES, c.G_FILE_TEST_EXISTS) != 0;
}

fn native() bool {
    return c.g_file_test(NATIVE_ENABLE, c.G_FILE_TEST_EXISTS) != 0;
}

fn installed() bool {
    if (native()) return true;
    var u: c.struct_utsname = undefined;
    if (c.uname(&u) != 0) return false;
    var pbuf: [512]u8 = undefined;
    const p = std.fmt.bufPrintSentinel(&pbuf, "/lib/modules/{s}/modules.dep", .{std.mem.sliceTo(&u.release, 0)}, 0) catch return false;
    var contents: [*c]u8 = null;
    var len: c.gsize = 0;
    if (c.g_file_get_contents(p.ptr, &contents, &len, null) == 0) return false;
    defer c.g_free(contents);
    return state.listsModule(contents[0..len]);
}

fn modprobe(remove: bool) bool {
    var argv = [_:null]?[*:0]const u8{ "/usr/sbin/modprobe", "-r", "sinty_scheduler" };
    if (!remove) argv = .{ "/usr/sbin/modprobe", "sinty_scheduler", null };
    var status: c_int = 0;
    var err: [*c]c.GError = null;
    if (c.g_spawn_sync(null, @ptrCast(@constCast(&argv)), null, c.G_SPAWN_DEFAULT, null, null, null, null, &status, &err) == 0) {
        std.log.warn("modprobe: {s}", .{if (err) |e| std.mem.span(e.*.message) else "failed"});
        c.g_clear_error(&err);
        return false;
    }
    return c.g_spawn_check_wait_status(status, null) != 0;
}

fn persist(path: [*:0]const u8, text: [:0]const u8) void {
    _ = c.g_mkdir_with_parents("/var/lib/sinty-scheduler", 0o755);
    const flags = c.G_FILE_SET_CONTENTS_CONSISTENT | c.G_FILE_SET_CONTENTS_DURABLE;
    if (c.g_file_set_contents_full(path, text.ptr, @intCast(text.len), flags, 0o644, null) == 0) return;
    const dir = std.c.open("/var/lib/sinty-scheduler", .{ .ACCMODE = .RDONLY, .DIRECTORY = true });
    if (dir < 0) return;
    _ = std.c.fsync(dir);
    _ = std.c.close(dir);
}

fn save() void {
    var buf: [32]u8 = undefined;
    persist(STATE_FILE, current.serialize(&buf));
}

fn load() void {
    var buf: [64]u8 = undefined;
    current = state.State.parse(readText(STATE_FILE, &buf) orelse return);
}

fn setClass(class: []const u8, path: []const u8) bool {
    var buf: [1024]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{s} {s}", .{ class, path }) catch return false;
    return writeFile(CLASSES, line);
}

const Disks = struct {
    dir: *c.GDir,

    fn open() ?Disks {
        return .{ .dir = c.g_dir_open("/sys/block", 0, null) orelse return null };
    }

    fn close(d: Disks) void {
        c.g_dir_close(d.dir);
    }

    fn next(d: Disks) ?[:0]const u8 {
        while (c.g_dir_read_name(d.dir)) |raw| {
            const name = std.mem.span(raw);
            if (state.eligibleDisk(name)) return name;
        }
        return null;
    }
};

fn queueFile(disk: []const u8, file: []const u8, buf: []u8) [*:0]const u8 {
    return (std.fmt.bufPrintSentinel(buf, "/sys/block/{s}/queue/{s}", .{ disk, file }, 0) catch unreachable).ptr;
}

fn rotational(disk: []const u8) bool {
    var pbuf: [256]u8 = undefined;
    var buf: [8]u8 = undefined;
    const text = readText(queueFile(disk, "rotational", &pbuf), &buf) orelse return true;
    return text.len > 0 and text[0] == '1';
}

fn attach() void {
    const disks = Disks.open() orelse return;
    defer disks.close();
    while (disks.next()) |disk| {
        if (rotational(disk)) continue;
        var pbuf: [256]u8 = undefined;
        var buf: [256]u8 = undefined;
        const path = queueFile(disk, "scheduler", &pbuf);
        const text = readText(path, &buf) orelse continue;
        const active = state.activeScheduler(text) orelse continue;
        if (std.mem.eql(u8, active, "sinty")) continue;
        if (!writeFile(path, "sinty")) {
            std.log.warn("sinty-schedd: {s} refused the scheduler", .{disk});
            continue;
        }
        var size_path: [256]u8 = undefined;
        var size: [32]u8 = undefined;
        const limit = queueFile(disk, "max_sectors_kb", &size_path);
        const old = readText(limit, &size) orelse continue;
        if (c.g_hash_table_contains(request_sizes, disk.ptr) == 0)
            _ = c.g_hash_table_insert(request_sizes, c.g_strdup(disk.ptr), c.g_strndup(old.ptr, old.len));
        _ = writeFile(limit, REQUEST_KB);
    }
}

fn detach() void {
    const disks = Disks.open() orelse return;
    defer disks.close();
    while (disks.next()) |disk| {
        var pbuf: [256]u8 = undefined;
        var buf: [256]u8 = undefined;
        const path = queueFile(disk, "scheduler", &pbuf);
        const text = readText(path, &buf) orelse continue;
        const active = state.activeScheduler(text) orelse continue;
        if (!std.mem.eql(u8, active, "sinty")) continue;
        _ = writeFile(path, "none");
        const old: [*c]const u8 = @ptrCast(c.g_hash_table_lookup(request_sizes, disk.ptr));
        if (old == null) continue;
        var size_path: [256]u8 = undefined;
        _ = writeFile(queueFile(disk, "max_sectors_kb", &size_path), std.mem.span(old));
        _ = c.g_hash_table_remove(request_sizes, disk.ptr);
    }
}

fn markShells(dir: []const u8, depth: u32) void {
    if (depth == 0) return;
    var pbuf: [1024]u8 = undefined;
    const full = std.fmt.bufPrintSentinel(&pbuf, CGROUP ++ "{s}", .{dir}, 0) catch return;
    const handle = c.g_dir_open(full.ptr, 0, null) orelse return;
    defer c.g_dir_close(handle);
    while (c.g_dir_read_name(handle)) |raw| {
        const name = std.mem.span(raw);
        var sub: [1024]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&sub, "{s}/{s}", .{ dir, name }, 0) catch continue;
        var check: [1100]u8 = undefined;
        const on_disk = std.fmt.bufPrintSentinel(&check, CGROUP ++ "{s}", .{path}, 0) catch continue;
        if (c.g_file_test(on_disk.ptr, c.G_FILE_TEST_IS_DIR) == 0) continue;
        if (!std.mem.eql(u8, name, "init")) {
            markShells(path, depth - 1);
            continue;
        }
        if (c.g_hash_table_contains(marked, path.ptr) != 0) continue;
        if (setClass("background", path)) _ = c.g_hash_table_add(marked, c.g_strdup(path.ptr));
    }
}

fn scan(_: ?*anyopaque) callconv(.c) c.gboolean {
    attach();
    markShells("/user.slice", DSH_DEPTH);
    return 1;
}

fn apply() bool {
    if (current.enabled) {
        if (native()) {
            if (!writeFile(NATIVE_ENABLE, "1")) return false;
        } else {
            if (!loaded() and !modprobe(false)) return false;
            attach();
        }
        if (scan_source == 0) scan_source = c.g_timeout_add_seconds(SCAN_SECONDS, scan, null);
        return true;
    }
    if (scan_source != 0) {
        _ = c.g_source_remove(scan_source);
        scan_source = 0;
    }
    c.g_hash_table_remove_all(marked);
    if (native()) {
        _ = writeFile(NATIVE_ENABLE, "0");
        _ = writeFile(CLASSES, "clear");
    } else if (loaded()) {
        detach();
        _ = writeFile(CLASSES, "clear");
        _ = modprobe(true);
    }
    return true;
}

fn emitChanged() void {
    const conn = connection orelse return;
    const b = c.g_variant_builder_new(vt("a{sv}"));
    defer c.g_variant_builder_unref(b);
    c.g_variant_builder_add(b, "{sv}", "Enabled", c.g_variant_new_boolean(@intFromBool(current.enabled)));
    const empty = [_:null]?[*:0]const u8{};
    _ = c.g_dbus_connection_emit_signal(conn, null, PATH, "org.freedesktop.DBus.Properties", "PropertiesChanged", c.g_variant_new("(sa{sv}^as)", IFACE, b, &empty), null);
}

fn addStats(totals: ?*c.GHashTable, text: []const u8) void {
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        var kbuf: [64]u8 = undefined;
        const key = std.fmt.bufPrintSentinel(&kbuf, "{s}", .{line[0..space]}, 0) catch continue;
        const value = std.fmt.parseInt(i64, line[space + 1 ..], 10) catch continue;
        const old: i64 = @intCast(@intFromPtr(c.g_hash_table_lookup(totals, key.ptr)));
        const merged = if (std.mem.endsWith(u8, key, "_p99_us")) @max(old, value) else old + value;
        _ = c.g_hash_table_insert(totals, c.g_strdup(key.ptr), @ptrFromInt(@as(usize, @intCast(merged))));
    }
}

fn stats(inv: *c.GDBusMethodInvocation) void {
    const b = c.g_variant_builder_new(vt("a{sx}"));
    defer c.g_variant_builder_unref(b);
    const totals = c.g_hash_table_new_full(c.g_str_hash, c.g_str_equal, c.g_free, null);
    defer c.g_hash_table_unref(totals);
    if (native()) {
        var buf: [2048]u8 = undefined;
        if (readText(NATIVE_STATS, &buf)) |text| addStats(totals, text);
    } else if (Disks.open()) |disks| {
        defer disks.close();
        while (disks.next()) |disk| {
            var pbuf: [256]u8 = undefined;
            var buf: [2048]u8 = undefined;
            addStats(totals, readText(queueFile(disk, "iosched/stats", &pbuf), &buf) orelse continue);
        }
    }
    addAnnounced(totals);
    var iter: c.GHashTableIter = undefined;
    c.g_hash_table_iter_init(&iter, totals);
    var key: c.gpointer = null;
    var value: c.gpointer = null;
    while (c.g_hash_table_iter_next(&iter, &key, &value) != 0) {
        c.g_variant_builder_add(b, "{sx}", @as([*c]const u8, @ptrCast(key)), @as(i64, @intCast(@intFromPtr(value))));
    }
    c.g_dbus_method_invocation_return_value(inv, c.g_variant_new("(a{sx})", b));
}

fn freeAnnounced(data: c.gpointer) callconv(.c) void {
    const entry: *Announced = @ptrCast(@alignCast(data));
    _ = c.g_array_free(entry.threads, 1);
    c.g_free(entry);
}

fn ownThread(pid: u32, tid: u32) bool {
    var buf: [64]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&buf, "/proc/{d}/task/{d}", .{ pid, tid }, 0) catch return false;
    return c.g_file_test(path.ptr, c.G_FILE_TEST_IS_DIR) != 0;
}

fn lowerThread(tid: u32) void {
    _ = std.os.linux.syscall3(.ioprio_set, 1, tid, @bitCast(IOPRIO_IDLE));
}

const Announce = struct {
    invocation: *c.GDBusMethodInvocation,
    threads: *c.GVariant,
};

fn announcedBy(src: [*c]c.GObject, res: ?*c.GAsyncResult, data: c.gpointer) callconv(.c) void {
    const call: *Announce = @ptrCast(@alignCast(data));
    defer {
        c.g_object_unref(call.invocation);
        c.g_variant_unref(call.threads);
        c.g_free(call);
    }
    var err: [*c]c.GError = null;
    const reply = c.g_dbus_connection_call_finish(@ptrCast(src), res, &err) orelse {
        c.g_dbus_method_invocation_take_error(call.invocation, err);
        return;
    };
    defer c.g_variant_unref(reply);
    var pid: c.guint32 = 0;
    c.g_variant_get(reply, "(u)", &pid);
    const sender = c.g_dbus_method_invocation_get_sender(call.invocation);
    const threads = c.g_array_new(0, 0, @sizeOf(u32));
    var iter: c.GVariantIter = undefined;
    _ = c.g_variant_iter_init(&iter, call.threads);
    var tid: c.guint32 = 0;
    while (c.g_variant_iter_next(&iter, "u", &tid) != 0) {
        if (!ownThread(pid, tid)) continue;
        if (current.enabled) lowerThread(tid);
        _ = c.g_array_append_vals(threads, &tid, 1);
    }
    if (threads.*.len == 0) {
        _ = c.g_array_free(threads, 1);
        _ = c.g_hash_table_remove(announced, sender);
    } else {
        const entry: *Announced = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Announced))));
        entry.* = .{ .pid = pid, .threads = threads };
        _ = c.g_hash_table_insert(announced, c.g_strdup(sender), entry);
    }
    c.g_dbus_method_invocation_return_value(call.invocation, null);
}

fn announce(inv: *c.GDBusMethodInvocation, params: ?*c.GVariant) void {
    const call: *Announce = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Announce))));
    call.* = .{
        .invocation = @ptrCast(@alignCast(c.g_object_ref(inv))),
        .threads = c.g_variant_get_child_value(params, 0).?,
    };
    const sender = c.g_dbus_method_invocation_get_sender(inv);
    c.g_dbus_connection_call(connection, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetConnectionUnixProcessID", c.g_variant_new("(s)", sender), vt("(u)"), c.G_DBUS_CALL_FLAGS_NONE, -1, null, announcedBy, call);
}

fn background(inv: *c.GDBusMethodInvocation) void {
    const b = c.g_variant_builder_new(vt("a{uau}"));
    defer c.g_variant_builder_unref(b);
    var iter: c.GHashTableIter = undefined;
    c.g_hash_table_iter_init(&iter, announced);
    var value: c.gpointer = null;
    while (c.g_hash_table_iter_next(&iter, null, &value) != 0) {
        const entry: *Announced = @ptrCast(@alignCast(value));
        const tids = c.g_variant_builder_new(vt("au"));
        defer c.g_variant_builder_unref(tids);
        const items: [*]u32 = @ptrCast(@alignCast(entry.threads.*.data));
        for (items[0..entry.threads.*.len]) |tid| c.g_variant_builder_add(tids, "u", tid);
        c.g_variant_builder_add(b, "{uau}", entry.pid, tids);
    }
    c.g_dbus_method_invocation_return_value(inv, c.g_variant_new("(a{uau})", b));
}

fn addAnnounced(totals: ?*c.GHashTable) void {
    var threads: usize = 0;
    var iter: c.GHashTableIter = undefined;
    c.g_hash_table_iter_init(&iter, announced);
    var value: c.gpointer = null;
    while (c.g_hash_table_iter_next(&iter, null, &value) != 0) {
        const entry: *Announced = @ptrCast(@alignCast(value));
        threads += entry.threads.*.len;
    }
    _ = c.g_hash_table_insert(totals, c.g_strdup("announced_processes"), @ptrFromInt(c.g_hash_table_size(announced)));
    _ = c.g_hash_table_insert(totals, c.g_strdup("announced_threads"), @ptrFromInt(threads));
}

fn ownerChanged(_: ?*c.GDBusConnection, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, params: ?*c.GVariant, _: c.gpointer) callconv(.c) void {
    var name: [*c]const u8 = null;
    var old: [*c]const u8 = null;
    var new: [*c]const u8 = null;
    c.g_variant_get(params, "(&s&s&s)", &name, &old, &new);
    if (new[0] == 0) _ = c.g_hash_table_remove(announced, name);
}

const Call = struct {
    invocation: *c.GDBusMethodInvocation,
    params: ?*c.GVariant,
};

fn newCall(inv: *c.GDBusMethodInvocation, params: ?*c.GVariant) *Call {
    const call: *Call = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Call))));
    call.* = .{
        .invocation = @ptrCast(@alignCast(c.g_object_ref(inv))),
        .params = if (params) |p| c.g_variant_ref(p) else null,
    };
    return call;
}

fn freeCall(call: *Call) void {
    c.g_object_unref(call.invocation);
    if (call.params) |p| c.g_variant_unref(p);
    c.g_free(call);
}

fn runEnable(call: *Call) void {
    const inv = call.invocation;
    var on: c.gboolean = 0;
    c.g_variant_get(call.params, "(b)", &on);
    const before = current;
    current.enabled = on != 0;
    if (!apply()) {
        current = before;
        _ = apply();
        return c.g_dbus_method_invocation_return_dbus_error(inv, "dev.sinty.Scheduler1.Error.Failed", "The kernel module could not be loaded.");
    }
    save();
    emitChanged();
    c.g_dbus_method_invocation_return_value(inv, null);
}

fn runClasses(call: *Call, uid: u32) void {
    const inv = call.invocation;
    if (!current.enabled or !loaded()) return c.g_dbus_method_invocation_return_value(inv, null);
    var iter: ?*c.GVariantIter = null;
    c.g_variant_get(call.params, "(a{ss})", &iter);
    defer c.g_variant_iter_free(iter);
    var path: [*c]const u8 = null;
    var class: [*c]const u8 = null;
    while (c.g_variant_iter_next(iter, "{&s&s}", &path, &class) != 0) {
        const p = std.mem.span(path);
        const k = std.mem.span(class);
        if (!state.pathAllowed(uid, p) or !state.validClass(k))
            return c.g_dbus_method_invocation_return_dbus_error(inv, "dev.sinty.Scheduler1.Error.NotAuthorized", "Not your session.");
        _ = setClass(k, p);
    }
    c.g_dbus_method_invocation_return_value(inv, null);
}

fn enableAllowed(call: *Call, ok: bool) void {
    defer freeCall(call);
    if (!ok) return c.g_dbus_method_invocation_return_dbus_error(call.invocation, "dev.sinty.Scheduler1.Error.NotAuthorized", "Not authorized.");
    runEnable(call);
}

fn byUser(src: [*c]c.GObject, res: ?*c.GAsyncResult, data: c.gpointer) callconv(.c) void {
    const call: *Call = @ptrCast(@alignCast(data));
    const reply = c.g_dbus_connection_call_finish(@ptrCast(@alignCast(src)), res, null) orelse return enableAllowed(call, false);
    defer c.g_variant_unref(reply);
    var uid: c.guint32 = 0;
    c.g_variant_get(reply, "(u)", &uid);
    enableAllowed(call, state.localUser(uid));
}

fn classesByUser(src: [*c]c.GObject, res: ?*c.GAsyncResult, data: c.gpointer) callconv(.c) void {
    const call: *Call = @ptrCast(@alignCast(data));
    defer freeCall(call);
    const reply = c.g_dbus_connection_call_finish(@ptrCast(@alignCast(src)), res, null) orelse
        return c.g_dbus_method_invocation_return_dbus_error(call.invocation, "dev.sinty.Scheduler1.Error.NotAuthorized", "Not authorized.");
    defer c.g_variant_unref(reply);
    var uid: c.guint32 = 0;
    c.g_variant_get(reply, "(u)", &uid);
    if (!state.localUser(uid))
        return c.g_dbus_method_invocation_return_dbus_error(call.invocation, "dev.sinty.Scheduler1.Error.NotAuthorized", "Not authorized.");
    runClasses(call, uid);
}

fn askUser(call: *Call, done: c.GAsyncReadyCallback) void {
    const sender = c.g_dbus_method_invocation_get_sender(call.invocation);
    c.g_dbus_connection_call(connection, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetConnectionUnixUser", c.g_variant_new("(s)", sender), vt("(u)"), c.G_DBUS_CALL_FLAGS_NONE, -1, null, done, call);
}

fn sessionTracking() bool {
    return c.g_file_test("/run/systemd/seats", c.G_FILE_TEST_IS_DIR) != 0;
}

fn byPolkit(src: [*c]c.GObject, res: ?*c.GAsyncResult, data: c.gpointer) callconv(.c) void {
    const call: *Call = @ptrCast(@alignCast(data));
    var err: [*c]c.GError = null;
    const reply = c.g_dbus_connection_call_finish(@ptrCast(@alignCast(src)), res, &err);
    if (reply == null) {
        const missing = err != null and (c.g_error_matches(err, c.g_dbus_error_quark(), c.G_DBUS_ERROR_SERVICE_UNKNOWN) != 0 or
            c.g_error_matches(err, c.g_dbus_error_quark(), c.G_DBUS_ERROR_NAME_HAS_NO_OWNER) != 0);
        c.g_clear_error(&err);
        if (!missing) return enableAllowed(call, false);
        return askUser(call, byUser);
    }
    defer c.g_variant_unref(reply);
    var ok: c.gboolean = 0;
    var challenge: c.gboolean = 0;
    c.g_variant_get(reply, "((bba{ss}))", &ok, &challenge, @as(?*anyopaque, null));
    if (ok == 0 and !sessionTracking()) return askUser(call, byUser);
    enableAllowed(call, ok != 0);
}

fn authorize(inv: *c.GDBusMethodInvocation, params: ?*c.GVariant) void {
    const call = newCall(inv, params);
    const subject = c.g_variant_builder_new(vt("a{sv}"));
    defer c.g_variant_builder_unref(subject);
    c.g_variant_builder_add(subject, "{sv}", "name", c.g_variant_new_string(c.g_dbus_method_invocation_get_sender(inv)));
    const details = c.g_variant_builder_new(vt("a{ss}"));
    defer c.g_variant_builder_unref(details);
    const args = c.g_variant_new("((sa{sv})sa{ss}us)", "system-bus-name", subject, ACTION, details, @as(c.guint32, 1), "");
    c.g_dbus_connection_call(connection, "org.freedesktop.PolicyKit1", "/org/freedesktop/PolicyKit1/Authority", "org.freedesktop.PolicyKit1.Authority", "CheckAuthorization", args, vt("((bba{ss}))"), c.G_DBUS_CALL_FLAGS_NO_AUTO_START, 120000, null, byPolkit, call);
}

fn methodCall(_: ?*c.GDBusConnection, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, method: [*c]const u8, params: ?*c.GVariant, inv: ?*c.GDBusMethodInvocation, _: c.gpointer) callconv(.c) void {
    const i = inv orelse return;
    const m = std.mem.span(method);
    if (std.mem.eql(u8, m, "GetStats")) return stats(i);
    if (std.mem.eql(u8, m, "Announce")) return announce(i, params);
    if (std.mem.eql(u8, m, "GetBackground")) return background(i);
    if (std.mem.eql(u8, m, "SetClasses")) return askUser(newCall(i, params), classesByUser);
    authorize(i, params);
}

fn getProperty(_: ?*c.GDBusConnection, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, prop: [*c]const u8, _: [*c][*c]c.GError, _: c.gpointer) callconv(.c) ?*c.GVariant {
    const p = std.mem.span(prop);
    if (std.mem.eql(u8, p, "Installed")) return c.g_variant_new_boolean(@intFromBool(installed()));
    if (std.mem.eql(u8, p, "Enabled")) return c.g_variant_new_boolean(@intFromBool(current.enabled and loaded()));
    return null;
}

var vtable: c.GDBusInterfaceVTable = undefined;

fn acquired(conn: ?*c.GDBusConnection, _: [*c]const u8, _: c.gpointer) callconv(.c) void {
    connection = conn;
    vtable = std.mem.zeroes(c.GDBusInterfaceVTable);
    vtable.method_call = methodCall;
    vtable.get_property = getProperty;
    var err: [*c]c.GError = null;
    const info = c.g_dbus_node_info_new_for_xml(XML, &err) orelse fatal("{s}", .{err.*.message});
    if (c.g_dbus_connection_register_object(conn, PATH, info.*.interfaces[0], &vtable, null, null, &err) == 0) fatal("{s}", .{err.*.message});
    _ = c.g_dbus_connection_signal_subscribe(conn, "org.freedesktop.DBus", "org.freedesktop.DBus", "NameOwnerChanged", "/org/freedesktop/DBus", null, c.G_DBUS_SIGNAL_FLAGS_NONE, ownerChanged, null, null);
}

fn lost(_: ?*c.GDBusConnection, _: [*c]const u8, data: c.gpointer) callconv(.c) void {
    c.g_main_loop_quit(@ptrCast(@alignCast(data)));
}

const TrimRange = extern struct {
    start: u64,
    len: u64,
    minlen: u64,
};

fn f2fsAttr(device: []const u8, attr: []const u8, buf: *[256]u8) [:0]const u8 {
    return std.fmt.bufPrintSentinel(buf, "/sys/fs/f2fs/{s}/{s}", .{ device, attr }, 0) catch unreachable;
}

fn setF2fs(device: []const u8, attr: []const u8, value: []const u8) void {
    var buf: [256]u8 = undefined;
    if (!writeFile(f2fsAttr(device, attr, &buf).ptr, value)) std.log.warn("f2fs {s}: write refused", .{attr});
}

fn f2fsValue(device: []const u8, attr: []const u8) ?u64 {
    var path: [256]u8 = undefined;
    var buf: [32]u8 = undefined;
    const text = readText(f2fsAttr(device, attr, &path).ptr, &buf) orelse return null;
    return std.fmt.parseInt(u64, std.mem.trim(u8, text, " \n"), 10) catch null;
}

fn pressure() f64 {
    var buf: [256]u8 = undefined;
    return care.fullPressure(readText("/proc/pressure/io", &buf) orelse return 0);
}

fn onMains() bool {
    const dir = c.g_dir_open("/sys/class/power_supply", 0, null) orelse return true;
    defer c.g_dir_close(dir);
    var entries: [16][32]u8 = undefined;
    var list: [16][]const u8 = undefined;
    var n: usize = 0;
    while (c.g_dir_read_name(dir)) |name| {
        if (n == list.len) break;
        var path_buf: [128]u8 = undefined;
        var type_buf: [16]u8 = undefined;
        var online_buf: [8]u8 = undefined;
        const base = std.mem.span(name);
        const type_path = std.fmt.bufPrintSentinel(&path_buf, "/sys/class/power_supply/{s}/type", .{base}, 0) catch continue;
        const kind = std.mem.trim(u8, readText(type_path, &type_buf) orelse continue, " \n");
        const online_path = std.fmt.bufPrintSentinel(&path_buf, "/sys/class/power_supply/{s}/online", .{base}, 0) catch continue;
        const online = std.mem.trim(u8, readText(online_path, &online_buf) orelse "", " \n");
        list[n] = std.fmt.bufPrint(&entries[n], "{s} {s}", .{ kind, online }) catch continue;
        n += 1;
    }
    return care.onMains(list[0..n]);
}

fn trimDue() bool {
    var buf: [32]u8 = undefined;
    const text = readText(TRIM_FILE, &buf) orelse return true;
    const last = std.fmt.parseInt(i64, std.mem.trim(u8, text, " \n"), 10) catch return true;
    return @divTrunc(c.g_get_real_time(), 1000000) - last >= TRIM_PERIOD_SECONDS;
}

fn trim(dir: [*:0]const u8, size: u64) void {
    const fd = std.c.open(dir, .{ .ACCMODE = .RDONLY });
    if (fd < 0) return;
    defer _ = std.c.close(fd);
    var start: u64 = 0;
    while (start < size) : (start += TRIM_CHUNK_BYTES) {
        var range: TrimRange = .{ .start = start, .len = TRIM_CHUNK_BYTES, .minlen = TRIM_MIN_BYTES };
        if (c.ioctl(fd, FITRIM, &range) != 0) {
            std.log.warn("trim stopped at {d}", .{start});
            return;
        }
        c.g_usleep(TRIM_PAUSE_SECONDS * 1000000);
    }
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrintSentinel(&buf, "{d}\n", .{@divTrunc(c.g_get_real_time(), 1000000)}, 0) catch unreachable;
    persist(TRIM_FILE, text);
}

const NvmeAdminCommand = extern struct {
    opcode: u8,
    flags: u8 = 0,
    rsvd: u16 = 0,
    nsid: u32,
    cdw2: u32 = 0,
    cdw3: u32 = 0,
    metadata: u64 = 0,
    addr: u64,
    metadata_len: u32 = 0,
    data_len: u32,
    cdw10: u32,
    cdw11: u32 = 0,
    cdw12: u32 = 0,
    cdw13: u32 = 0,
    cdw14: u32 = 0,
    cdw15: u32 = 0,
    timeout_ms: u32 = 5000,
    result: u32 = 0,
};

const NVME_ADMIN_IOCTL: c_ulong = 0xc0484e41;

fn reportNvme(device: []const u8) void {
    const controller = care.nvmeController(device) orelse return;
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buf, "/dev/{s}", .{controller}, 0) catch return;
    const fd = c.open(path.ptr, c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return;
    defer _ = c.close(fd);
    var identify: [4096]u8 align(4096) = undefined;
    var health: [512]u8 align(4096) = undefined;
    var ask = NvmeAdminCommand{ .opcode = 0x06, .nsid = 0, .addr = @intFromPtr(&identify), .data_len = identify.len, .cdw10 = 1 };
    if (c.ioctl(fd, NVME_ADMIN_IOCTL, &ask) != 0) return;
    ask = NvmeAdminCommand{ .opcode = 0x02, .nsid = 0xffffffff, .addr = @intFromPtr(&health), .data_len = health.len, .cdw10 = (127 << 16) | 2 };
    if (c.ioctl(fd, NVME_ADMIN_IOCTL, &ask) != 0) return;
    var out: [512]u8 = undefined;
    const text = care.nvmeReport(&out, &identify, &health) orelse return;
    var file_buf: [96]u8 = undefined;
    const file = std.fmt.bufPrintSentinel(&file_buf, "/run/sinty-scheduler/{s}", .{controller}, 0) catch return;
    _ = c.g_mkdir_with_parents("/run/sinty-scheduler", 0o755);
    _ = c.g_file_set_contents_full(file.ptr, text.ptr, @intCast(text.len), c.G_FILE_SET_CONTENTS_CONSISTENT, 0o644, null);
}

fn careLoop(_: c.gpointer) callconv(.c) c.gpointer {
    c.g_usleep(CARE_START_SECONDS * 1000000);
    var mounts: [16384]u8 = undefined;
    const mount = care.f2fsMount(readText("/proc/mounts", &mounts) orelse return null) orelse return null;
    var dir_buf: [256]u8 = undefined;
    const dir = std.fmt.bufPrintSentinel(&dir_buf, "{s}", .{mount.dir}, 0) catch return null;
    setF2fs(mount.device, "discard_io_aware", "0");
    reportNvme(mount.device);
    setF2fs(mount.device, "gc_urgent", "0");
    var collecting = false;
    var sleep_ms: u32 = 0;
    while (true) {
        var fs: c.struct_statvfs = undefined;
        const free = f2fsValue(mount.device, "free_segments");
        if (free != null and c.statvfs(dir.ptr, &fs) == 0) {
            const unit: u64 = fs.f_frsize;
            const b = care.band(fs.f_blocks * unit / care.SEGMENT_BYTES, fs.f_bavail * unit / care.SEGMENT_BYTES);
            const mains = onMains();
            const next = if (mains) care.collect(collecting, free.?, b) else care.collectOnBattery(collecting, free.?, b);
            if (next) {
                const wanted: u32 = if (free.? >= b.low / 4 and pressure() > BUSY_PRESSURE) 500 else 100;
                if (wanted != sleep_ms) {
                    var buf: [16]u8 = undefined;
                    setF2fs(mount.device, "gc_urgent_sleep_time", std.fmt.bufPrint(&buf, "{d}", .{wanted}) catch unreachable);
                    sleep_ms = wanted;
                }
            }
            if (next != collecting) {
                setF2fs(mount.device, "gc_urgent", if (next) "3" else "0");
                std.log.info("f2fs collection {s}, {d} free segments", .{ if (next) "on" else "off", free.? });
                collecting = next;
            }
            if (mains and trimDue()) trim(dir.ptr, fs.f_blocks * unit);
            const wait: c.gulong = if (mains or collecting) CARE_SECONDS else CARE_BATTERY_SECONDS;
            c.g_usleep(wait * 1000000);
            continue;
        }
        c.g_usleep(CARE_SECONDS * 1000000);
    }
}

pub fn main() void {
    marked = c.g_hash_table_new_full(c.g_str_hash, c.g_str_equal, c.g_free, null);
    request_sizes = c.g_hash_table_new_full(c.g_str_hash, c.g_str_equal, c.g_free, c.g_free);
    announced = c.g_hash_table_new_full(c.g_str_hash, c.g_str_equal, c.g_free, freeAnnounced);
    load();
    if (current.enabled and !apply()) std.log.warn("sinty-schedd: the kernel module could not be loaded", .{});
    _ = c.g_thread_new("disk-care", careLoop, null);
    const loop = c.g_main_loop_new(null, 0);
    _ = c.g_bus_own_name(c.G_BUS_TYPE_SYSTEM, NAME, c.G_BUS_NAME_OWNER_FLAGS_NONE, acquired, null, lost, loop, null);
    c.g_main_loop_run(loop);
}

test {
    _ = state;
    _ = care;
}
