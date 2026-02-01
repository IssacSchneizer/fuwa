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
        const fd = std.os.linux.inotify_init1(std.os.linux.IN.NONBLOCK | std.os.linux.IN.CLOEXEC);
        if (fd < 0) return error.InotifyInitFailed;
        defer _ = std.os.linux.close(fd);

        // Ensure path is null-terminated for inotify_add_watch
        const path_c = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(path_c);

        const wd = std.os.linux.inotify_add_watch(fd, path_c.ptr, std.os.linux.IN.MODIFY | std.os.linux.IN.CREATE | std.os.linux.IN.DELETE);
        if (wd < 0) return error.InotifyWatchFailed;

        var buf: [4096]u8 align(@alignOf(std.os.linux.inotify_event)) = undefined;
        while (true) {
            const len = std.os.linux.read(fd, &buf, buf.len);
            if (len < 0) {
                const err = std.os.linux.getErrno(len);
                if (err == .AGAIN) {
                    std.time.sleep(100 * std.time.ns_per_ms);
                    continue;
                }
                return error.InotifyReadFailed;
            }

            var i: usize = 0;
            while (i < @as(usize, @intCast(len))) {
                const event = @as(*std.os.linux.inotify_event, @ptrCast(@alignCast(&buf[i])));
                if (event.len > 0) {
                    const name_ptr = @as([*]u8, @ptrCast(&event.name));
                    const name = name_ptr[0..std.mem.indexOfSentinel(u8, 0, name_ptr)];
                    self.callback(name);
                }
                i += @sizeOf(std.os.linux.inotify_event) + event.len;
            }
        }
    }

    fn watchMacOS(self: *Watcher, path: []const u8) !void {
        // macOS FSEvents requires linking CoreServices. For a "libc-only" feel, 
        // one might use kqueue for simple file watching, but FSEvents is preferred for directories.
        // Since we are limited to std/libc, kqueue is more 'portable' in terms of dependency.
        const kq = std.os.kqueue() catch return error.KqueueInitFailed;
        defer std.os.close(kq);

        const dir_fd = try std.os.open(path, std.os.O.RDONLY, 0);
        defer std.os.close(dir_fd);

        var event = std.os.Kevent{
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
