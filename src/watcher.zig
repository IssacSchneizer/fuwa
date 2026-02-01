const std = @import("std");
const builtin = @import("builtin");

pub const Watcher = struct {
    allocator: std.mem.Allocator,
    callback: *const fn ([]const u8) void,

    pub fn init(allocator: std.mem.Allocator, callback: *const fn ([]const u8) void) !*Watcher {
        const self = try allocator.create(Watcher);
        self.* = .{
            .allocator = allocator,
            .callback = callback,
        };
        return self;
    }

    pub fn deinit(self: *Watcher) void {
        self.allocator.destroy(self);
    }

    pub fn watch(self: *Watcher, path: []const u8) !void {
        if (builtin.os.tag == .linux) {
            try self.watchLinux(path);
        } else if (builtin.os.tag == .macos) {
            try self.watchMacOS(path);
        } else if (builtin.os.tag == .windows) {
            try self.watchWindows(path);
        } else {
            return error.UnsupportedOperatingSystem;
        }
    }

    fn watchLinux(self: *Watcher, path: []const u8) !void {
        const fd_usize = std.os.linux.inotify_init1(std.os.linux.IN.NONBLOCK | std.os.linux.IN.CLOEXEC);
        const fd_isize = @as(isize, @bitCast(fd_usize));
        if (fd_isize < 0) return error.InotifyInitFailed;
        const fd: i32 = @intCast(fd_usize);
        defer _ = std.os.linux.close(fd);

        const path_c = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(path_c);

        const wd_usize = std.os.linux.inotify_add_watch(fd, path_c.ptr, std.os.linux.IN.MODIFY | std.os.linux.IN.CREATE | std.os.linux.IN.DELETE);
        const wd_isize = @as(isize, @bitCast(wd_usize));
        if (wd_isize < 0) return error.InotifyWatchFailed;

        var buf: [4096]u8 align(@alignOf(std.os.linux.inotify_event)) = undefined;
        while (true) {
            const len_isize = std.os.linux.read(fd, &buf, buf.len);
            const len_err = @as(isize, @bitCast(len_isize));
            if (len_err < 0) {
                // In Zig 0.12.0, use E.AGAIN etc directly or check the error number
                const err_val = @as(isize, @bitCast(@as(usize, @bitCast(len_isize))));
                if (err_val == -@as(isize, @intCast(@intFromEnum(std.os.linux.E.AGAIN)))) {
                    std.time.sleep(100 * std.time.ns_per_ms);
                    continue;
                }
                return error.InotifyReadFailed;
            }
            const len = @as(usize, @intCast(len_isize));

            var i: usize = 0;
            while (i < len) {
                if (i + @sizeOf(std.os.linux.inotify_event) > len) break;

                const event = @as(*const std.os.linux.inotify_event, @ptrCast(@alignCast(&buf[i])));
                
                if (event.len > 0) {
                    const name_start = i + @sizeOf(std.os.linux.inotify_event);
                    const name_end = name_start + event.len;
                    
                    if (name_end <= len) {
                        const name_ptr = @as([*]const u8, @ptrCast(event)) + @sizeOf(std.os.linux.inotify_event);
                        const actual_name_len = std.mem.indexOfScalar(u8, name_ptr[0..event.len], 0) orelse event.len;
                        const name = name_ptr[0..actual_name_len];
                        if (name.len > 0) {
                            self.callback(name);
                        } else {
                            self.callback(path);
                        }
                    } else {
                        self.callback(path);
                    }
                } else {
                    self.callback(path);
                }
                
                i += @sizeOf(std.os.linux.inotify_event) + event.len;
            }
        }
    }

    fn watchMacOS(self: *Watcher, path: []const u8) !void {
        const kq = std.os.kqueue() catch return error.KqueueInitFailed;
        defer std.os.close(kq);

        const dir_fd = try std.os.open(path, std.os.O.RDONLY, 0);
        defer std.os.close(dir_fd);

        const event = std.os.Kevent{
            .ident = @intCast(dir_fd),
            .filter = std.os.system.EVFILT_VNODE,
            .flags = std.os.system.EV_ADD | std.os.system.EV_ENABLE | std.os.system.EV_CLEAR,
            .fflags = std.os.system.NOTE_WRITE | std.os.system.NOTE_EXTEND | std.os.system.NOTE_ATTRIB,
            .data = 0,
            .udata = 0,
        };

        while (true) {
            var out_event: [1]std.os.Kevent = undefined;
            const nevents = std.os.kevent(kq, &[_]std.os.Kevent{event}, &out_event, null) catch return error.KeventFailed;
            if (nevents > 0) {
                self.callback(path);
            }
        }
    }

    fn watchWindows(self: *Watcher, path: []const u8) !void {
        const windows = std.os.windows;
        const kernel32 = windows.kernel32;

        const path_w = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, path);
        defer self.allocator.free(path_w);

        const handle = kernel32.CreateFileW(
            path_w.ptr,
            windows.FILE_LIST_DIRECTORY,
            windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE,
            null,
            windows.OPEN_EXISTING,
            windows.FILE_FLAG_BACKUP_SEMANTICS,
            null,
        );
        if (handle == windows.INVALID_HANDLE_VALUE) return error.CreateFileFailed;
        defer _ = kernel32.CloseHandle(handle);

        var buf: [4096]u8 align(4) = undefined;
        while (true) {
            var bytes_returned: windows.DWORD = 0;
            const success = kernel32.ReadDirectoryChangesW(
                handle,
                &buf,
                buf.len,
                windows.FALSE,
                windows.FILE_NOTIFY_CHANGE_FILE_NAME | windows.FILE_NOTIFY_CHANGE_DIR_NAME | windows.FILE_NOTIFY_CHANGE_ATTRIBUTES | windows.FILE_NOTIFY_CHANGE_SIZE | windows.FILE_NOTIFY_CHANGE_LAST_WRITE,
                &bytes_returned,
                null,
                null,
            );

            if (success == windows.FALSE) return error.ReadDirectoryChangesFailed;

            var offset: usize = 0;
            while (true) {
                const info = @as(*windows.FILE_NOTIFY_INFORMATION, @ptrCast(@alignCast(&buf[offset])));
                const name_utf16 = info.FileName[0..(info.FileNameLength / 2)];
                const name_utf8 = try std.unicode.utf16leToUtf8Alloc(self.allocator, name_utf16);
                defer self.allocator.free(name_utf8);
                self.callback(name_utf8);

                if (info.NextEntryOffset == 0) break;
                offset += info.NextEntryOffset;
            }
        }
    }
};
