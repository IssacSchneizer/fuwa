const std = @import("std");
const Watcher = @import("watcher.zig").Watcher;

fn callback(path: []const u8) void {
    std.debug.print("Change detected: {s}\n", .{path});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: {s} <path_to_watch>\n", .{args[0]});
        return;
    }

    const watcher = try Watcher.init(allocator, callback);
    defer watcher.deinit();

    std.debug.print("Watching: {s}\n", .{args[1]});
    try watcher.watch(args[1]);
}
