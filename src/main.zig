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

    std.debug.print("Watching directory: . (Press Ctrl+C to stop)\n", .{});
    while (true) {
        while (watcher.output_chan.tryPop()) |event| {
            switch (event) {
                .Added => |path| {
                    std.debug.print("[ADDED] {s}\n", .{path});
                    allocator.free(path);
                },
                .Removed => |path| {
                    std.debug.print("[REMOVED] {s}\n", .{path});
                    allocator.free(path);
                },
                .Modified => |path| {
                    std.debug.print("[MODIFIED] {s}\n", .{path});
                    allocator.free(path);
                },
                .Rescan => |path| {
                    std.debug.print("[RESCAN] {s}\n", .{path});
                    allocator.free(path);
                },
            }
        }
        std.time.sleep(100 * std.time.ns_per_ms);
    }
}
