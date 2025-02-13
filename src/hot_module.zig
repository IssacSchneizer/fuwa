const std = @import("std");

// This function will be reloaded when the file changes
pub fn run() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("Hot module v2 executed at: {}\n", .{std.time.timestamp()});
}