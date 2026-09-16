const std = @import("std");
const args = @import("args.zig");

const CopierError = error{ DestinationError, DestinationNotFound, DestinationPermissionDenied, DestinationMustBeDirectory, SourceFilePermissionDenied, SourceFileNotFound, SourceFileError, UnsupportedSourceType, OutOfMemory, AllSourcesInvalid };

const READ_BUF_SIZE: usize = 256 * 1024;
const CHUNK_SIZE: u64 = 10 * 1024 * 1024;
const Source = struct {
    path: []const u8,
    kind: std.Io.File.Kind,
    size: u64,
};

const InvalidSources = struct {
    path: []const u8,
    err: CopierError,
};

const SourceResult = union(enum) {
    valid: Source,
    invalid: InvalidSources,
};

pub const Copier = struct {
    allocator: std.mem.Allocator,
    config: args.Args,
    io: std.Io,
    sources: []SourceResult,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: args.Args) Copier {
        return .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .sources = &.{},
        };
    }

    pub fn run(self: *Copier) !void {
        try self.validate();

        for (self.sources) |result| {
            if (result == .invalid) {
                std.log.err("skipping {s}: {}", .{ result.invalid.path, result.invalid.err });
            }
        }

        switch (self.config.threads) {
            .single => try self.copySingleThreaded(),
            .multi => |count| _ = count,
        }
    }

    pub fn copySingleThreaded(self: *Copier) !void {
        const total_bytes = self.totalValidBytes();
        var copied_so_far: u64 = 0;
        for (self.sources) |result| {
            if (result != .valid) continue;
            const src = result.valid;

            const filename = std.fs.path.basename(src.path);
            const dst_path = try std.fs.path.join(self.allocator, &.{ self.config.destination, filename });
            defer self.allocator.free(dst_path);

            try self.copyFile(src, dst_path, &copied_so_far, total_bytes);
        }
    }

    fn copyFile(self: *Copier, source: Source, dst_path: []const u8, copied_so_far: *u64, total_bytes: u64) !void {
        const cwd = std.Io.Dir.cwd();

        const src_file = try cwd.openFile(self.io, source.path, .{});
        defer src_file.close(self.io);

        const dst_file = try cwd.createFile(self.io, dst_path, .{});
        defer dst_file.close(self.io);
        var buf: [READ_BUF_SIZE]u8 = undefined;
        var offset: u64 = 0;
        var accumulated: u64 = 0;
        while (true) {
            const n = try src_file.readPositionalAll(self.io, &buf, offset);
            if (n == 0) break;

            try dst_file.writePositionalAll(self.io, buf[0..n], offset);
            offset += n;
            accumulated += n;
            copied_so_far.* += n;

            if (accumulated >= CHUNK_SIZE or offset == source.size) {
                printProgressBar(copied_so_far.*, total_bytes);
                accumulated = 0;
            }
        }
    }
    fn printProgressBar(copied: u64, total: u64) void {
        const width = 40;
        const percent = if (total > 0) @as(f64, @floatFromInt(copied)) / @as(f64, @floatFromInt(total)) else 1.0;
        const filled: usize = @intFromFloat(percent * width);

        std.debug.print("\r[", .{});
        var i: usize = 0;
        while (i < width) : (i += 1) {
            std.debug.print("{c}", .{if (i < filled) @as(u8, '=') else ' '});
        }
        std.debug.print("] {d:.1}%", .{percent * 100});
    }

    fn totalValidBytes(self: *Copier) u64 {
        var total: u64 = 0;
        for (self.sources) |result| {
            if (result == .valid) total += result.valid.size;
        }
        return total;
    }

    fn validate(self: *Copier) CopierError!void {
        const cwd = std.Io.Dir.cwd();

        const destination = cwd.statFile(self.io, self.config.destination, .{}) catch |err| {
            return switch (err) {
                error.FileNotFound => error.DestinationNotFound,
                error.AccessDenied, error.PermissionDenied => error.DestinationPermissionDenied,
                else => error.DestinationError,
            };
        };

        if (destination.kind != .directory) {
            return error.DestinationMustBeDirectory;
        }

        var invalid_count: usize = 0;
        const results = try self.allocator.alloc(SourceResult, self.config.sources.len);
        for (self.config.sources, 0..) |path, index| {
            const stat = cwd.statFile(self.io, path, .{}) catch |err| {
                results[index] = .{ .invalid = .{ .path = path, .err = switch (err) {
                    error.FileNotFound => error.SourceFileNotFound,
                    error.AccessDenied, error.PermissionDenied => error.SourceFilePermissionDenied,
                    else => error.SourceFileError,
                } } };
                invalid_count += 1;
                continue;
            };
            results[index] = .{ .valid = .{ .path = path, .kind = stat.kind, .size = stat.size } };
        }
        self.sources = results;

        if (invalid_count == self.sources.len) {
            return error.AllSourcesInvalid;
        }
    }
};
