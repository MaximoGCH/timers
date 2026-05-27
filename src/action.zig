const std = @import("std");
const Socket = @import("Socket.zig");

const ConnectionCtx = struct {
    allocator: std.mem.Allocator,
    args: []const [:0]const u8,
};

fn on_connect(connection: *Socket.Connection, ctx: ConnectionCtx) void {
    defer connection.close();

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();

    const payload = std.mem.join(arena.allocator(), " ", ctx.args[1..ctx.args.len]) catch {
        std.debug.print("Unexpected error, could not produce payload\n", .{});
        return;
    };
    connection.write(payload) catch {
        std.debug.print("The connection was closed, unexpected error", .{});
    };
}

pub fn action_exec(allocator: std.mem.Allocator, socket: *Socket, args: []const [:0]const u8) void {
    socket.connect(ConnectionCtx, ConnectionCtx{
        .allocator = allocator,
        .args = args,
    }, on_connect) catch {
        std.debug.print("Could not connect with socket name: {s}, fd: {d}\n", .{ socket.name, socket.fd });
        return;
    };
}
