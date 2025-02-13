const std = @import("std");
const fs = std.fs;

pub const Watcher = struct {
    allocator: std.mem.Allocator,
    file_path: []const u8,
    last_modified: i128,

    pub fn init(allocator: std.mem.Allocator, file_path: []const u8) !Watcher {
        const last_modified = try getFileModifiedTime(file_path);
        return Watcher{
            .allocator = allocator,
            .file_path = file_path,
            .last_modified = last_modified,
        };
    }

    pub fn deinit(self: *Watcher) void {
        // Nothing to deallocate in this simple implementation
        _ = self;
    }

    pub fn checkForChanges(self: *Watcher) !bool {
        const current_modified = try getFileModifiedTime(self.file_path);
        
        if (current_modified > self.last_modified) {
            self.last_modified = current_modified;
            return true;
        }
        
        return false;
    }
};

fn getFileModifiedTime(file_path: []const u8) !i128 {
    const file = try fs.cwd().openFile(file_path, .{});
    defer file.close();
    
    const stat = try file.stat();
    return stat.mtime;
}
