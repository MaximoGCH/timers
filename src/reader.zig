const std = @import("std");
const Socket = @import("Socket.zig");

const ConnectionCtx = struct {
    allocator: std.mem.Allocator,
    timer_name: []const u8,
    io: std.Io,
};

const MAX_MSG_LEN = 1024;

fn on_connect(connection: *Socket.Connection, ctx: ConnectionCtx) void {
    defer connection.close();

    const payload = std.fmt.allocPrint(ctx.allocator, "reader {s}", .{ctx.timer_name}) catch {
        std.debug.print("Unexpected error, could not allocate the connection payload", .{});
        return;
    };
    defer ctx.allocator.free(payload);
    connection.write(payload) catch {
        std.debug.print("The connection was closed, Unexpected error", .{});
        return;
    };

    const out = std.Io.File.stdout();

    while (true) {
        var buffer: [MAX_MSG_LEN]u8 = undefined;
        const len = connection.read(MAX_MSG_LEN, &buffer);
        const msg = buffer[0..len];

        if (len == 0) {
            connection.close();
            std.debug.print("Unexpected connection close, server closed connection", .{});
            return;
        }

        out.writeStreamingAll(ctx.io, msg) catch {
            std.debug.print("Unexpected error trying to write msg to stdout", .{});
            continue;
        };
    }
}

pub fn reader_init(allocator: std.mem.Allocator, socket: *Socket, timer_name: []const u8, io: std.Io) void {
    socket.connect(ConnectionCtx, ConnectionCtx{
        .allocator = allocator,
        .timer_name = timer_name,
        .io = io,
    }, on_connect) catch {
        std.debug.print("Could not connect with socket name: {s}, fd: {d}\n", .{ socket.name, socket.fd });
        return;
    };
}
