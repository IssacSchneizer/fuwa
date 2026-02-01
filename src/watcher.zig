const std = @import("std");
const builtin = @import("builtin");
const channel_mod = @import("channel.zig");

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
    wd: i32 = -1,
    is_stale: bool = false,
    parent_wd: i32 = -1,

    fn deinit(self: *WatchNode, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

pub const Watcher = struct {
    allocator: std.mem.Allocator,
    input_chan: channel_mod.Channel(WatchRequest),
    output_chan: channel_mod.Channel(WatchEvent),
    path_to_node: std.StringHashMap(*WatchNode),
    wd_to_node: std.AutoHashMap(i32, *WatchNode),
    parent_wd_to_stale_node: std.AutoHashMap(i32, *WatchNode),
    thread: ?std.Thread = null,
    running: bool = false,

    pub fn init(allocator: std.mem.Allocator) !*Watcher {
        const self = try allocator.create(Watcher);
        self.* = .{
            .allocator = allocator,
            .input_chan = .{ .allocator = allocator },
            .output_chan = .{ .allocator = allocator },
            .path_to_node = std.StringHashMap(*WatchNode).init(allocator),
            .wd_to_node = std.AutoHashMap(i32, *WatchNode).init(allocator),
            .parent_wd_to_stale_node = std.AutoHashMap(i32, *WatchNode).init(allocator),
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
        self.wd_to_node.deinit();
        self.parent_wd_to_stale_node.deinit();
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
    }

    fn addWatchInternal(self: *Watcher, fd: i32, path: []const u8, recursive: bool) !i32 {
        _ = recursive;
        const path_c = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(path_c);

        const wd_usize = std.os.linux.inotify_add_watch(fd, path_c.ptr, std.os.linux.IN.MODIFY | std.os.linux.IN.CREATE | std.os.linux.IN.DELETE | std.os.linux.IN.DELETE_SELF | std.os.linux.IN.MOVE_SELF);
        const wd: i32 = @intCast(wd_usize);
        return wd;
    }

    fn addWatchRecursive(self: *Watcher, fd: i32, path: []const u8, recursive: bool) !void {
        const wd = try self.addWatchInternal(fd, path, recursive);
        if (wd < 0) return;

        if (!self.path_to_node.contains(path)) {
            const node = try self.allocator.create(WatchNode);
            node.* = .{
                .path = try self.allocator.dupe(u8, path),
                .recursive = recursive,
                .wd = wd,
            };
            try self.path_to_node.put(node.path, node);
            try self.wd_to_node.put(wd, node);
        }

        if (recursive) {
            var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch return;
            defer dir.close();
            var it = dir.iterate();
            while (try it.next()) |entry| {
                if (entry.kind == .directory) {
                    const sub_path = try std.fs.path.join(self.allocator, &.{ path, entry.name });
                    defer self.allocator.free(sub_path);
                    try self.addWatchRecursive(fd, sub_path, true);
                }
            }
        }
    }

    fn loopLinux(self: *Watcher) !void {
        const fd_usize = std.os.linux.inotify_init1(std.os.linux.IN.NONBLOCK | std.os.linux.IN.CLOEXEC);
        const fd: i32 = @intCast(fd_usize);
        defer _ = std.os.linux.close(fd);

        var buf: [8192]u8 align(@alignOf(std.os.linux.inotify_event)) = undefined;
        while (self.running) {
            while (self.input_chan.tryPop()) |req| {
                switch (req) {
                    .Add => |add| try self.addWatchRecursive(fd, add.path, add.recursive),
                    .Remove => |rem| {
                        if (self.path_to_node.fetchRemove(rem.path)) |kv| {
                            const node = kv.value;
                            _ = std.os.linux.inotify_rm_watch(fd, node.wd);
                            _ = self.wd_to_node.remove(node.wd);
                            node.deinit(self.allocator);
                            self.allocator.destroy(node);
                        }
                    },
                }
            }

            const len_isize = std.os.linux.read(fd, &buf, buf.len);
            const len_err = @as(isize, @bitCast(len_isize));
            if (len_err > 0) {
                const len = @as(usize, @intCast(len_err));
                var i: usize = 0;
                while (i < len) {
                    const event = @as(*const std.os.linux.inotify_event, @ptrCast(@alignCast(&buf[i])));
                    
                    if (self.wd_to_node.get(event.wd)) |node| {
                        if (event.mask & (std.os.linux.IN.DELETE_SELF | std.os.linux.IN.MOVE_SELF) != 0) {
                            // Directory deleted or moved - it's now stale
                            node.is_stale = true;
                            _ = self.wd_to_node.remove(event.wd);
                            
                            // Try to watch parent
                            const parent_path = std.fs.path.dirname(node.path) orelse ".";
                            const parent_wd = try self.addWatchInternal(fd, parent_path, false);
                            if (parent_wd >= 0) {
                                node.parent_wd = parent_wd;
                                try self.parent_wd_to_stale_node.put(parent_wd, node);
                            }
                            try self.output_chan.push(.{ .Removed = try self.allocator.dupe(u8, node.path) });
                        } else if (event.len > 0) {
                            const name_ptr = @as([*]const u8, @ptrCast(event)) + @sizeOf(std.os.linux.inotify_event);
                            const actual_name_len = std.mem.indexOfScalar(u8, name_ptr[0..event.len], 0) orelse event.len;
                            const name = name_ptr[0..actual_name_len];
                            const full_path = try std.fs.path.join(self.allocator, &.{ node.path, name });
                            defer self.allocator.free(full_path);

                            if (event.mask & (std.os.linux.IN.CREATE | std.os.linux.IN.MOVED_TO) != 0) {
                                try self.output_chan.push(.{ .Added = try self.allocator.dupe(u8, full_path) });
                                if (node.recursive) {
                                    const stat = std.fs.cwd().statFile(full_path) catch null;
                                    if (stat != null and stat.?.kind == .directory) {
                                        try self.addWatchRecursive(fd, full_path, true);
                                    }
                                }
                            } else if (event.mask & (std.os.linux.IN.DELETE | std.os.linux.IN.MOVED_FROM) != 0) {
                                try self.output_chan.push(.{ .Removed = try self.allocator.dupe(u8, full_path) });
                            } else if (event.mask & std.os.linux.IN.MODIFY != 0) {
                                try self.output_chan.push(.{ .Modified = try self.allocator.dupe(u8, full_path) });
                            }
                        } else {
                            try self.output_chan.push(.{ .Modified = try self.allocator.dupe(u8, node.path) });
                        }
                    } else if (self.parent_wd_to_stale_node.get(event.wd)) |stale_node| {
                        // Event in parent of a stale node
                        if (event.mask & (std.os.linux.IN.CREATE | std.os.linux.IN.MOVED_TO) != 0) {
                            const name_ptr = @as([*]const u8, @ptrCast(event)) + @sizeOf(std.os.linux.inotify_event);
                            const actual_name_len = std.mem.indexOfScalar(u8, name_ptr[0..event.len], 0) orelse event.len;
                            const name = name_ptr[0..actual_name_len];
                            const node_name = std.fs.path.basename(stale_node.path);
                            
                            if (std.mem.eql(u8, name, node_name)) {
                                // Stale directory is back!
                                const new_wd = try self.addWatchInternal(fd, stale_node.path, stale_node.recursive);
                                if (new_wd >= 0) {
                                    stale_node.wd = new_wd;
                                    stale_node.is_stale = false;
                                    try self.wd_to_node.put(new_wd, stale_node);
                                    _ = self.parent_wd_to_stale_node.remove(event.wd);
                                    // Optionally stop watching parent if no other stale nodes depend on it
                                    // For simplicity, we keep it for now or rely on fetchRemove logic if we had a refcount
                                    try self.output_chan.push(.{ .Added = try self.allocator.dupe(u8, stale_node.path) });
                                }
                            }
                        }
                    }
                    i += @sizeOf(std.os.linux.inotify_event) + event.len;
                }
            }
            std.time.sleep(10 * std.time.ns_per_ms);
        }
    }
};
