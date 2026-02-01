const std = @import("std");

pub fn Channel(comptime T: type) type {
    return struct {
        queue: std.TailQueue(T) = .{},
        mutex: std.Thread.Mutex = .{},
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Channel(T) {
            return .{
                .allocator = allocator,
            };
        }

        pub fn push(self: *Channel(T), value: T) !void {
            const Node = std.TailQueue(T).Node;
            const node = try self.allocator.create(Node);
            node.data = value;
            self.mutex.lock();
            defer self.mutex.unlock();
            self.queue.append(node);
        }

        pub fn tryPop(self: *Channel(T)) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();
            const node = self.queue.popFirst() orelse return null;
            const data = node.data;
            self.allocator.destroy(node);
            return data;
        }

        pub fn deinit(self: *Channel(T)) void {
            while (self.tryPop()) |_| {}
        }
    };
}
