const std = @import("std");
const Watcher = @import("watcher.zig").Watcher;

const RunFn = fn() callconv(.C) void;

const DynamicLib = struct {
    handle: *std.DynLib,
    run_fn: RunFn,

    pub fn load(lib_path: []const u8) !DynamicLib {
        const handle = try std.DynLib.open(lib_path);
        if (handle.lookup(RunFn, "run")) |run_fn| {
            return DynamicLib{
                .handle = handle,
                .run_fn = run_fn,
            };
        }
        return error.SymbolNotFound;
    }

    pub fn unload(self: *DynamicLib) void {
        self.handle.close();
    }
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const stdout = std.io.getStdOut().writer();

    try stdout.print("Hot Reload Example - Press Ctrl+C to exit\n", .{});

    const lib_path = "zig-out/lib/libhot_module.so";
    var watcher = try Watcher.init(allocator, lib_path);
    defer watcher.deinit();

    // Main program loop
    while (true) {
        if (try watcher.checkForChanges()) {
            try stdout.print("\nReloading {s}...\n", .{lib_path});

            // Load the dynamic library
            var lib = DynamicLib.load(lib_path) catch |err| {
                try stdout.print("Error loading library: {}\n", .{err});
                continue;
            };
            defer lib.unload();

            // Call the run function
            lib.run_fn();
        }

        // Sleep for a short duration to prevent busy waiting
        std.time.sleep(std.time.ns_per_ms * 100);
    }
}