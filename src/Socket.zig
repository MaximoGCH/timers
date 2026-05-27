const std = @import("std");
const linux = std.os.linux;

fd: i32,
name: []const u8,
address: linux.sockaddr.un,
address_len: linux.socklen_t,

const Socket = @This();

pub fn init(allocator: std.mem.Allocator, name: []const u8) error{CreationError}!*Socket {
    const socket = allocator.create(Socket) catch {
        return error.CreationError;
    };

    socket.name = allocator.dupe(u8, name) catch {
        return error.CreationError;
    };
    errdefer allocator.free(socket.name);

    socket.fd = @as(i32, @intCast(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM, 0)));

    if (socket.fd < 0) {
        return error.CreationError;
    }

    errdefer _ = linux.close(socket.fd);

    socket.address = .{
        .family = linux.AF.UNIX,
        .path = undefined,
    };

    socket.address.path[0] = 0;

    @memcpy(socket.address.path[1 .. 1 + name.len], name);

    socket.address_len =
        @offsetOf(linux.sockaddr.un, "path") +
        1 +
        @as(linux.socklen_t, @intCast(name.len));

    return socket;
}

pub fn close(self: *Socket, allocator: std.mem.Allocator) !void {
    _ = linux.close(self.fd);
    allocator.free(self.name);
    allocator.destroy(self);
}

pub fn listen_connections(
    self: *Socket,
    comptime Ctx: type,
    ctx: Ctx,
    comptime on_connect: fn (*Connection, Ctx) void,
) !void {
    const bindResult = linux.bind(
        self.fd,
        @ptrCast(&self.address),
        self.address_len,
    );

    if (bindResult < 0) {
        return error.CreationError;
    }

    const listenResult = linux.listen(self.fd, 128);

    if (listenResult < 0) {
        return error.CreationError;
    }

    std.debug.print("Listening to conections, fd {d}\n", .{self.fd});

    while (true) {
        const client_fd = @as(i32, @intCast(linux.accept(self.fd, null, null)));
        var connection: Connection = .{ .client_fn = client_fd };
        std.debug.print("New connection with client fd {d}\n", .{connection.client_fn});
        on_connect(&connection, ctx);
    }
}

pub fn connect(
    self: *Socket,
    comptime Ctx: type,
    ctx: Ctx,
    comptime on_connect: fn (*Connection, Ctx) void,
) error{CanNotConnect}!void {
    const connection_result = linux.connect(
        self.fd,
        @ptrCast(&self.address),
        self.address_len,
    );

    if (connection_result < 0) {
        return error.CanNotConnect;
    }

    var connection: Connection = .{ .client_fn = self.fd };
    std.debug.print("Connected to fd {d}\n", .{connection.client_fn});
    on_connect(&connection, ctx);
}

pub const Connection = struct {
    client_fn: i32,

    pub fn write(self: *Connection, msg: []const u8) error{ConnectionClosed}!void {
        const r = linux.write(self.client_fn, msg.ptr, msg.len);
        if (r <= 0) {
            return error.ConnectionClosed;
        }
    }

    pub fn read(self: *Connection, comptime maximum_read: usize, buffer: *[maximum_read]u8) usize {
        const count = linux.read(self.client_fn, buffer, maximum_read);
        return count;
    }

    pub fn close(self: *Connection) void {
        std.debug.print("Closed connection with fd {d}\n", .{self.client_fn});
        _ = linux.close(self.client_fn);
    }
};
