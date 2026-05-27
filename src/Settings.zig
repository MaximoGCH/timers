const std = @import("std");

pub const TimerItem = struct {
    name: []const u8,
    seconds: i96,
};

pub const TimerSetting = struct {
    name: []u8,
    sequence: []TimerItem,
};

timers: []TimerSetting,

const Settings = @This();
pub fn read(path: []const u8, allocator: std.mem.Allocator, io: std.Io) !std.json.Parsed(Settings) {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const dir = std.Io.Dir.cwd();
    const text = try dir.readFileAlloc(io, path, arena.allocator(), .unlimited);
    const settings = std.json.parseFromSlice(Settings, allocator, text, .{}) catch |e| {
        std.debug.print("error: {}\n", .{e});
        return e;
    };
    return settings;
}

pub fn get_timer_id(self: *const Settings, name: []const u8) error{NotFound}!usize {
    for (self.timers, 0..) |timer, i| {
        if (std.mem.eql(u8, timer.name, name)) {
            return i;
        }
    }

    return error.NotFound;
}
