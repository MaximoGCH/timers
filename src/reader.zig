const std = @import("std");
const Socket = @import("Socket.zig");

const ConnectionCtx = struct {
    allocator: std.mem.Allocator,
    timer_name: []const u8,
    format: ?[]const u8,
    io: std.Io,
};

const MAX_MSG_LEN = 1024;

fn on_connect(connection: *Socket.Connection, ctx: ConnectionCtx) void {
    defer connection.close();
    var arena_allocator = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_allocator.deinit();

    const payload = (if (ctx.format) |format| std.fmt.allocPrint(arena_allocator.allocator(), "reader {s} {s}", .{ ctx.timer_name, format }) else std.fmt.allocPrint(arena_allocator.allocator(), "reader {s}", .{ctx.timer_name})) catch {
        std.debug.print("Unexpected error, could not allocate the connection payload", .{});
        return;
    };
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
        out.writeStreamingAll(ctx.io, "\n") catch {
            std.debug.print("Unexpected error trying to write msg to stdout", .{});
            continue;
        };
    }
}

pub fn reader_init(allocator: std.mem.Allocator, socket: *Socket, io: std.Io, timer_name: []const u8, format_arg: ?[]const u8) void {
    socket.connect(ConnectionCtx, ConnectionCtx{
        .allocator = allocator,
        .timer_name = timer_name,
        .format = format_arg,
        .io = io,
    }, on_connect) catch {
        std.debug.print("Could not connect with socket name: {s}, fd: {d}\n", .{ socket.name, socket.fd });
        return;
    };
}
