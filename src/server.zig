const std = @import("std");
const Socket = @import("Socket.zig");
const Connection = Socket.Connection;
const spsc_queue = @import("spsc_queue.zig");
const Settings = @import("Settings.zig");

const ReaderFormat = enum {
    default,
    waybar,
};

const Action = union(enum) {
    add_reader: struct {
        timer_id: usize,
        connection: Connection,
        format: ReaderFormat,
    },
    toggle: struct {
        timer_id: usize,
    },
    next_sequence: struct {
        timer_id: usize,
    },
    add_time: struct {
        timer_id: usize,
        time: i96,
    },
};

const ActionQueue = spsc_queue.SpscQueue(Action, 1024);

const ConnectCtx = struct {
    action_queue: *ActionQueue,
    allocator: std.mem.Allocator,
    settings: *const Settings,
};
const MAX_COMMAND_LEN = 1024;
fn on_connect(connection: *Connection, ctx: *const ConnectCtx) void {
    const arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();

    var buffer: [MAX_COMMAND_LEN]u8 = undefined;
    const len = connection.read(MAX_COMMAND_LEN, &buffer);
    const command = buffer[0..len];

    var iterator = std.mem.tokenizeScalar(u8, command, ' ');

    const command_type = iterator.next() orelse {
        std.debug.print("Closed connection because command was empty\n", .{});
        connection.close();
        return;
    };

    // READER
    if (std.mem.eql(u8, command_type, "reader")) {
        const timer_name = iterator.next() orelse {
            std.debug.print("Timer name is required\n", .{});
            return;
        };

        const timer_id = ctx.settings.get_timer_id(timer_name) catch {
            std.debug.print("Timer not found {s}\n", .{timer_name});
            return;
        };

        const format_name = iterator.next() orelse "";
        const format = std.meta.stringToEnum(ReaderFormat, format_name) orelse ReaderFormat.default;

        const slot = ctx.action_queue.reserve_slot() orelse return;
        slot.* = .{
            .add_reader = .{
                .timer_id = timer_id,
                .connection = connection.*,
                .format = format,
            },
        };
        ctx.action_queue.commit_slot();
        return;
    }

    // ACTION
    if (std.mem.eql(u8, command_type, "action")) {
        defer connection.close();

        const action = iterator.next() orelse {
            std.debug.print("Action is required\n", .{});
            return;
        };

        const timer_name = iterator.next() orelse {
            std.debug.print("Timer name is required\n", .{});
            return;
        };

        const timer_id = ctx.settings.get_timer_id(timer_name) catch {
            std.debug.print("Timer not found {s}\n", .{timer_name});
            return;
        };

        if (std.mem.eql(u8, action, "toggle")) {
            const slot = ctx.action_queue.reserve_slot() orelse return;
            slot.* = .{
                .toggle = .{
                    .timer_id = timer_id,
                },
            };
            ctx.action_queue.commit_slot();
            return;
        }

        if (std.mem.eql(u8, action, "next_sequence")) {
            const slot = ctx.action_queue.reserve_slot() orelse return;
            slot.* = .{
                .next_sequence = .{
                    .timer_id = timer_id,
                },
            };
            ctx.action_queue.commit_slot();
            return;
        }

        if (std.mem.eql(u8, action, "add_time")) {
            const time_str = iterator.next() orelse {
                std.debug.print("Time is mandatory for add_time command\n", .{});
                return;
            };

            const time = std.fmt.parseInt(i96, time_str, 10) catch {
                std.debug.print("Incorrect format for time, {s}\n", .{time_str});
                return;
            };

            const slot = ctx.action_queue.reserve_slot() orelse return;
            slot.* = .{
                .add_time = .{
                    .timer_id = timer_id,
                    .time = time,
                },
            };
            ctx.action_queue.commit_slot();
            return;
        }
    }

    std.debug.print("No command found\n", .{});
}

fn producer(allocator: std.mem.Allocator, action_queue: *ActionQueue, socket: *Socket, settings: *const Settings) void {
    const connectCtx: ConnectCtx = .{
        .action_queue = action_queue,
        .allocator = allocator,
        .settings = settings,
    };

    socket.listen_connections(*const ConnectCtx, &connectCtx, on_connect) catch {
        std.debug.print("Could not start listening, fatal error\n", .{});
        return;
    };
}

const TimerState = struct {
    time: i96,
    sequence_id: usize,
    active: bool,
};

const ReaderState = struct {
    connection: Connection,
    timer_id: usize,
    format: ReaderFormat,
};

const State = struct {
    timers: []TimerState,
    readers: std.ArrayList(ReaderState),
    previous: std.Io.Timestamp,
};

const DefaultReaderOut = struct {
    sequence_name: []const u8,
    sequence_seconds: i96,
    elapsed_seconds: i96,
    remaining_seconds: i96,
    active: bool,
};

const WaybarReaderOut = struct {
    sequence_name: []const u8,
    sequence_seconds: i96,
    elapsed_seconds: i96,
    remaining_seconds: i96,
    active: bool,
    class: [][]const u8,
    alt: []const u8,
};

fn consumer(allocator: std.mem.Allocator, io: std.Io, queue: *ActionQueue, settings: *const Settings) void {
    var state: State = undefined;

    state.timers = allocator.alloc(TimerState, settings.timers.len) catch {
        std.debug.print("Could not allocate timer, fatal error\n", .{});
        return;
    };
    defer allocator.free(state.timers);

    for (state.timers) |*timer| {
        timer.time = 0;
        timer.sequence_id = 0;
        timer.active = true;
    }

    state.readers = std.ArrayList(ReaderState).initCapacity(allocator, 10) catch {
        std.debug.print("Could not allocate readers, fatal error\n", .{});
        return;
    };
    defer state.readers.deinit(allocator);

    state.previous = std.Io.Clock.now(.awake, io);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var closedConnection = std.ArrayList(usize).initCapacity(allocator, 10) catch {
        std.debug.print("Unexpected error, could not create closed connection array", .{});
        return;
    };
    defer closedConnection.deinit(allocator);

    while (true) {
        defer std.Io.sleep(io, std.Io.Duration.fromMilliseconds(200), .awake) catch {};
        defer _ = arena.reset(.retain_capacity);

        const now = std.Io.Clock.now(.awake, io);
        const diff = state.previous.durationTo(now);
        state.previous = now;

        for (state.timers, 0..) |*timer, i| {
            const timer_settings = &settings.timers[i];
            const current_sequence = &timer_settings.sequence[timer.sequence_id];

            if (timer.active) {
                timer.time += diff.nanoseconds;
                const current_sequence_ns = current_sequence.seconds * std.time.ns_per_s;
                if (current_sequence_ns <= timer.time) {
                    timer.time -= current_sequence_ns;
                    timer.sequence_id = (timer.sequence_id + 1) % timer_settings.sequence.len;
                }
            }
            std.debug.print("Timer {s}, sequence {s}, time: {d}, active: {}\n", .{ timer_settings.name, current_sequence.name, timer.time, timer.active });
        }

        for (state.readers.items, 0..) |*reader, readerI| {
            const timer = state.timers[reader.timer_id];
            const timer_settings = &settings.timers[reader.timer_id];
            const current_sequence = &timer_settings.sequence[timer.sequence_id];

            var out = std.Io.Writer.Allocating.init(arena.allocator());
            defer out.deinit();

            var stringify = std.json.Stringify{
                .writer = &out.writer,
                .options = .{},
            };

            switch (reader.format) {
                .default => {
                    const payload: DefaultReaderOut = .{
                        .sequence_name = current_sequence.name,
                        .sequence_seconds = current_sequence.seconds,
                        .elapsed_seconds = @divFloor(timer.time, std.time.ns_per_s),
                        .remaining_seconds = current_sequence.seconds - (@divFloor(timer.time, std.time.ns_per_s)),
                        .active = timer.active,
                    };

                    stringify.write(payload) catch {
                        std.debug.print("Error stringifying to json reader out payload\n", .{});
                        continue;
                    };
                },
                .waybar => {
                    var class: [3][]const u8 = undefined;

                    class[0] = "mgch-timers-sequence";
                    class[1] = current_sequence.name;
                    class[2] = if (timer.active) "active" else "paused";

                    const payload: WaybarReaderOut = .{
                        .sequence_name = current_sequence.name,
                        .sequence_seconds = current_sequence.seconds,
                        .elapsed_seconds = @divFloor(timer.time, std.time.ns_per_s),
                        .remaining_seconds = current_sequence.seconds - (@divFloor(timer.time, std.time.ns_per_s)),
                        .active = timer.active,
                        .class = &class,
                        .alt = if (!timer.active) "paused" else current_sequence.name,
                    };

                    stringify.write(payload) catch {
                        std.debug.print("Error stringifying to json reader out payload\n", .{});
                        continue;
                    };
                },
            }

            reader.connection.write(out.writer.buffered()) catch {
                std.debug.print("Connection {d} closed", .{reader.connection.client_fn});
                closedConnection.append(allocator, readerI) catch {};
                continue;
            };
        }

        state.readers.orderedRemoveMany(closedConnection.items);
        closedConnection.clearRetainingCapacity();

        while (queue.pop()) |action| {
            switch (action.*) {
                .add_reader => |*add_reader| {
                    const reader = state.readers.addOne(allocator) catch {
                        std.debug.print("Unexpected error, could not allocate a new reader\n", .{});
                        add_reader.connection.close();
                        continue;
                    };

                    reader.connection = add_reader.connection;
                    reader.timer_id = add_reader.timer_id;
                    reader.format = add_reader.format;
                },

                .toggle => |toggle| {
                    const timer_state = &state.timers[toggle.timer_id];
                    timer_state.active = !timer_state.active;
                },

                .next_sequence => |next_sequence| {
                    const timer_state = &state.timers[next_sequence.timer_id];
                    const timer_settings = &settings.timers[next_sequence.timer_id];
                    timer_state.time = 0;
                    timer_state.active = true;
                    timer_state.sequence_id = (timer_state.sequence_id + 1) % timer_settings.sequence.len;
                },

                .add_time => |add_time| {
                    const timer_state = &state.timers[add_time.timer_id];
                    timer_state.time -= add_time.time * std.time.ns_per_s;
                },
            }
        }
    }
}

pub fn server_init(allocator: std.mem.Allocator, socket: *Socket, io: std.Io, settings_path: []const u8) void {
    const parsed_settings = Settings.read(settings_path, allocator, io) catch {
        std.debug.print("Could not read or parse settings in path {s}\n", .{settings_path});
        return;
    };
    defer parsed_settings.deinit();
    const settings = parsed_settings.value;

    var queue = ActionQueue{};

    const prod_thread =
        std.Thread.spawn(.{}, producer, .{ allocator, &queue, socket, &settings }) catch {
            std.debug.print("Could not start producer thread, not expected error\n", .{});
            return;
        };

    const cons_thread =
        std.Thread.spawn(.{}, consumer, .{ allocator, io, &queue, &settings }) catch {
            std.debug.print("Could not start consumer thread, not expected error\n", .{});
            return;
        };

    prod_thread.join();
    cons_thread.join();
}
