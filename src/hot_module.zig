const std = @import("std");

// Export the function so it can be loaded dynamically
export fn run() callconv(.C) void {
    const stdout = std.io.getStdOut().writer();
    stdout.print("Hot module v2 executed at: {}\n", .{std.time.timestamp()}) catch return;
}