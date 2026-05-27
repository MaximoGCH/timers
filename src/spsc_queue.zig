const std = @import("std");

pub fn SpscQueue(comptime T: type, comptime Capacity: usize) type {
    comptime {
        if (Capacity < 2)
            @compileError("Capacity must be >= 2");
    }

    return struct {
        const Self = @This();

        buffer: [Capacity]T = undefined,

        head: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        tail: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

        inline fn next(i: usize) usize {
            return (i + 1) % Capacity;
        }

        /// Producer only: reserve a slot to write into
        pub fn reserve_slot(self: *Self) ?*T {
            const tail = self.tail.load(.monotonic);
            const next_tail = next(tail);

            const head = self.head.load(.acquire);

            if (next_tail == head) {
                return null; // full
            }

            // IMPORTANT: we do NOT publish yet
            return &self.buffer[tail];
        }

        /// Producer only: commit after writing into slot
        pub fn commit_slot(self: *Self) void {
            const tail = self.tail.load(.monotonic);
            self.tail.store(next(tail), .release);
        }

        /// Consumer only
        pub fn pop(self: *Self) ?*T {
            const head = self.head.load(.monotonic);
            const tail = self.tail.load(.acquire);

            if (head == tail) return null;

            const ptr = &self.buffer[head];

            self.head.store(next(head), .release);
            return ptr;
        }

        pub fn is_empty(self: *Self) bool {
            return self.head.load(.acquire) ==
                self.tail.load(.acquire);
        }
    };
}
