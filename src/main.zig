const std = @import("std");
const Io = std.Io;
const Socket = @import("Socket.zig");
const server = @import("server.zig");
const action = @import("action.zig");
const reader = @import("reader.zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 0) return;
    const type_arg = if (args.len > 1) args[1] else {
        std.debug.print("Error, missing command, use commands: serve, action\n", .{});
        return;
    };

    const socket = Socket.init(init.gpa, "mgch_eye_care_connection") catch {
        std.debug.print("Could not create abstract socket\n", .{});
        return;
    };
    defer socket.close(init.gpa) catch {};

    if (std.mem.eql(u8, type_arg, "action")) {
        action.action_exec(init.gpa, socket, args);
        return;
    }

    if (std.mem.eql(u8, type_arg, "reader")) {
        const timer_arg = if (args.len > 2) args[2] else {
            std.debug.print("Error, missing timmer name after server command\n", .{});
            return;
        };
        reader.reader_init(init.gpa, socket, timer_arg, init.io);
        return;
    }

    if (std.mem.eql(u8, type_arg, "server")) {
        const settings_arg = if (args.len > 2) args[2] else {
            std.debug.print("Error, missing settings path after server command\n", .{});
            return;
        };
        server.server_init(init.gpa, socket, init.io, settings_arg);
        return;
    }

    std.debug.print("Error, invalid command, use commands: server, action \n", .{});
}
