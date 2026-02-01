const std = @import("std");
const builtin = @import("builtin");
const Channel = @import("channel.zig").Channel;

pub const WatchRequest = union(enum) {
    Add: struct {
        path: []const u8,
        recursive: bool,
    },
    Remove: struct {
        path: []const u8,
    },
};

pub const WatchEvent = union(enum) {
    Added: []const u8,
    Removed: []const u8,
    Modified: []const u8,
    Rescan: []const u8,
};

const WatchNode = struct {
    path: []const u8,
    recursive: bool,
    os_handle: if (builtin.os.tag == .linux) i32 else if (builtin.os.tag == .windows) std.os.windows.HANDLE else usize,
    children: std.StringHashMap(*WatchNode),

    fn deinit(self: *WatchNode, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        var it = self.children.valueIterator();
        while (it.next()) |child| {
            child.*.deinit(allocator);
            allocator.destroy(child.*);
        }
        self.children.deinit();
    }
};

pub const Watcher = struct {
    allocator: std.mem.Allocator,
    input_chan: Channel(WatchRequest),
    output_chan: Channel(WatchEvent),
    path_to_node: std.StringHashMap(*WatchNode),
    thread: ?std.Thread = null,
    running: bool = false,

    pub fn init(allocator: std.mem.Allocator) !*Watcher {
        const self = try allocator.create(Watcher);
        self.* = .{
            .allocator = allocator,
            .input_chan = Channel(WatchRequest).init(allocator),
            .output_chan = Channel(WatchEvent).init(allocator),
            .path_to_node = std.StringHashMap(*WatchNode).init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *Watcher) void {
        self.running = false;
        if (self.thread) |t| t.join();
        self.input_chan.deinit();
        self.output_chan.deinit();
        var it = self.path_to_node.valueIterator();
        while (it.next()) |node| {
            node.*.deinit(self.allocator);
            self.allocator.destroy(node.*);
        }
        self.path_to_node.deinit();
        self.allocator.destroy(self);
    }

    pub fn start(self: *Watcher) !void {
        self.running = true;
        self.thread = try std.Thread.spawn(.{}, watcherLoop, .{self});
    }

    fn watcherLoop(self: *Watcher) void {
        if (builtin.os.tag == .linux) {
            self.loopLinux() catch |err| std.debug.print("Watcher loop error: {}\n", .{err});
        }
        // Other backends...
    }

    fn loopLinux(self: *Watcher) !void {
        const fd_usize = std.os.linux.inotify_init1(std.os.linux.IN.NONBLOCK | std.os.linux.IN.CLOEXEC);
        const fd: i32 = @intCast(fd_usize);
        defer _ = std.os.linux.close(fd);

        var buf: [4096]u8 align(@alignOf(std.os.linux.inotify_event)) = undefined;
        while (self.running) {
            // Drain requests
            while (self.input_chan.tryPop()) |req| {
                switch (req) {
                    .Add => |add| {
                        const path_c = try self.allocator.dupeZ(u8, add.path);
                        defer self.allocator.free(path_c);
                        const wd_usize = std.os.linux.inotify_add_watch(fd, path_c.ptr, std.os.linux.IN.MODIFY | std.os.linux.IN.CREATE | std.os.linux.IN.DELETE | std.os.linux.IN.DELETE_SELF | std.os.linux.IN.MOVE_SELF);
                        const wd: i32 = @intCast(wd_usize);
                        
                        const node = try self.allocator.create(WatchNode);
                        node.* = .{
                            .path = try self.allocator.dupe(u8, add.path),
                            .recursive = add.recursive,
                            .os_handle = wd,
                            .children = std.StringHashMap(*WatchNode).init(self.allocator),
                        };
                        try self.path_to_node.put(node.path, node);
                    },
                    .Remove => |rem| {
                        if (self.path_to_node.get(rem.path)) |node| {
                            _ = std.os.linux.inotify_rm_watch(fd, node.os_handle);
                            // Cleanup node logic...
                        }
                    },
                }
            }

            // Read events
            const len_isize = std.os.linux.read(fd, &buf, buf.len);
            const len_err = @as(isize, @bitCast(len_isize));
            if (len_err > 0) {
                const len = @as(usize, @intCast(len_err));
                var i: usize = 0;
                while (i < len) {
                    const event = @as(*const std.os.linux.inotify_event, @ptrCast(@alignCast(&buf[i])));
                    // Normalize and push to output_chan
                    try self.output_chan.push(.Modified, .{ .path = "dummy" }); // Placeholder
                    i += @sizeOf(std.os.linux.inotify_event) + event.len;
                }
            }
            std.time.sleep(50 * std.time.ns_per_ms);
        }
    }
};
