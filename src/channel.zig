const std = @import("std");

pub fn Channel(comptime T: type) type {
    return struct {
        queue: std.TailQueue(T),
        mutex: std.Thread.Mutex,
        allocator: std.mem.Allocator,

        const Self = @this();
        const Node = std.TailQueue(T).Node;

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .queue = .{},
                .mutex = .{},
                .allocator = allocator,
            };
        }

        pub fn push(self: *Self, value: T) !void {
            const node = try self.allocator.create(Node);
            node.data = value;
            self.mutex.lock();
            defer self.mutex.unlock();
            self.queue.append(node);
        }

        pub fn tryPop(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();
            const node = self.queue.popFirst() orelse return null;
            const data = node.data;
            self.allocator.destroy(node);
            return data;
        }

        pub fn deinit(self: *Self) void {
            while (self.tryPop()) |_| {}
        }
    };
}
