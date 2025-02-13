const std = @import("std");
const Watcher = @import("watcher.zig").Watcher;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const stdout = std.io.getStdOut().writer();

    try stdout.print("Hot Reload Example - Press Ctrl+C to exit\n", .{});

    var watcher = try Watcher.init(allocator, "src/hot_module.zig");
    defer watcher.deinit();

    // Main program loop
    while (true) {
        if (try watcher.checkForChanges()) {
            try stdout.print("\nReloading hot_module.zig...\n", .{});
            
            // Simulate module reload
            const hot_module = @import("hot_module.zig");
            try hot_module.run();
        }

        // Sleep for a short duration to prevent busy waiting
        std.time.sleep(std.time.ns_per_ms * 100);
    }
}
