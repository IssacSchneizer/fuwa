const std = @import("std");
const Watcher = @import("watcher.zig").Watcher;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const watcher = try Watcher.init(allocator);
    defer watcher.deinit();

    try watcher.start();
    try watcher.input_chan.push(.{ .Add = .{ .path = ".", .recursive = true } });

    std.debug.print("Watching... Press Ctrl+C to stop.\n", .{});
    while (true) {
        while (watcher.output_chan.tryPop()) |event| {
            switch (event) {
                .Modified => |path| std.debug.print("Modified: {s}\n", .{path}),
                else => |e| std.debug.print("Event: {}\n", .{e}),
            }
        }
        std.time.sleep(100 * std.time.ns_per_ms);
    }
}
