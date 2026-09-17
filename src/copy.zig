const std = @import("std");
const args = @import("args.zig");
const Io = std.Io;

const Source = struct {
    path: []const u8,
    dest_rel: []const u8,

    fn deinit(self: Source, alloc: std.mem.Allocator) void {
        alloc.free(self.path);
        alloc.free(self.dest_rel);
    }
};

pub const Copier = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    raw_sources: []const []const u8,
    sources: std.ArrayList(Source) = .empty,
    dest_dir: []const u8,
    jobs: u8 = 1,
    recursive: bool,
    verbose: bool,

    const Task = struct {
        source: [:0]u8,
        dest: [:0]u8,

        fn free(self: Task, alloc: std.mem.Allocator) void {
            alloc.free(self.source);
            alloc.free(self.dest);
        }
    };

    const Context = struct {
        copier: *Copier,
        queue: *Io.Queue(Task),
        pending: std.atomic.Value(usize),
        failed: std.atomic.Value(bool),
    };

    pub fn init(io: std.Io, alloc: std.mem.Allocator, options: args.Args) !Copier {
        const jobs = switch (options.threads) {
            .single => 1,
            .multi => |jobs| jobs,
        };

        return .{
            .io = io,
            .alloc = alloc,
            .recursive = options.recursive,
            .verbose = options.verbose,
            .dest_dir = options.destination,
            .raw_sources = options.sources,
            .jobs = jobs,
        };
    }
    pub fn run(self: *Copier) !void {
        try self.validSources();

        defer {
            for (self.sources.items) |source| {
                source.deinit(self.alloc);
            }

            self.sources.deinit(self.alloc);
        }

        const capacity = @max(
            @as(usize, self.jobs) * 8,
            256,
        );

        const buffer = try self.alloc.alloc(
            Task,
            capacity,
        );
        defer self.alloc.free(buffer);

        var queue = Io.Queue(Task).init(buffer);
        defer queue.close(self.io);

        var ctx: Context = .{
            .copier = self,
            .queue = &queue,
            .pending = .init(0),
            .failed = .init(false),
        };

        var workers: Io.Group = .init;

        for (0..self.jobs) |_| {
            workers.async(
                self.io,
                worker,
                .{&ctx},
            );
        }

        for (self.sources.items) |source| {
            self.enqueue(&ctx, source) catch |err| {
                queue.close(self.io);
                workers.await(self.io) catch {};

                return err;
            };
        }

        queue.close(self.io);

        workers.await(self.io) catch |err| {
            if (ctx.failed.load(.acquire)) {
                return error.CopyFailed;
            }
            return err;
        };
    }

    fn enqueue(
        self: *Copier,
        ctx: *Context,
        source: Source,
    ) !void {
        const dest_path = try std.fs.path.join(
            self.alloc,
            &.{ self.dest_dir, source.dest_rel },
        );
        defer self.alloc.free(dest_path);

        const src = try self.alloc.dupeZ(
            u8,
            source.path,
        );

        const dst = self.alloc.dupeZ(
            u8,
            dest_path,
        ) catch |err| {
            self.alloc.free(src);
            return err;
        };

        const task = Task{
            .source = src,
            .dest = dst,
        };

        std.debug.print(
            "ENQUEUE source=[{s}] dest=[{s}]\n",
            .{ src, dst },
        );

        ctx.queue.putOne(
            self.io,
            task,
        ) catch |err| {
            task.free(self.alloc);
            return err;
        };
    }

    fn worker(ctx: *Context) Io.Cancelable!void {
        const self = ctx.copier;

        while (true) {
            const task = ctx.queue.getOne(self.io) catch |err| switch (err) {
                error.Closed => return,
                error.Canceled => return error.Canceled,
            };

            std.debug.print(
                "WORKER source=[{s}] dest=[{s}]\n",
                .{
                    task.source,
                    task.dest,
                },
            );
            defer task.free(self.alloc);

            self.copyFile(task) catch |err| {
                if (!ctx.failed.swap(true, .acq_rel)) {
                    std.log.err(
                        "zcp: copy '{s}' -> '{s}': {s}",
                        .{
                            task.source,
                            task.dest,
                            @errorName(err),
                        },
                    );
                }

                ctx.queue.close(self.io);
                return error.Canceled;
            };

            if (ctx.pending.fetchSub(1, .acq_rel) == 1) {
                ctx.queue.close(self.io);
                return;
            }
        }
    }

    fn collectSources(self: *Copier, list: *std.ArrayList(Source), src_path: []const u8, dest_rel: []const u8) !void {
        const cwd = std.Io.Dir.cwd();
        const stat = cwd.statFile(self.io, src_path, .{}) catch |err| {
            std.log.err("{s}: {s}", .{ @errorName(err), src_path });
            return;
        };

        switch (stat.kind) {
            .file => {
                const path = try self.alloc.dupe(u8, src_path);
                errdefer self.alloc.free(path);

                const dest_rel_copy = try self.alloc.dupe(u8, dest_rel);
                errdefer self.alloc.free(dest_rel_copy);

                try list.append(self.alloc, .{
                    .path = path,
                    .dest_rel = dest_rel_copy,
                });
            },

            .directory => {
                if (!self.recursive) {
                    return std.log.err("zcp: -r not specified; omitting directory '{s}'", .{src_path});
                }

                var dir = try cwd.openDir(self.io, src_path, .{ .iterate = true });
                defer dir.close(self.io);

                var it = dir.iterate();

                while (try it.next(self.io)) |entry| {
                    const child_src = try std.fs.path.join(
                        self.alloc,
                        &.{ src_path, entry.name },
                    );
                    defer self.alloc.free(child_src);

                    const child_rel = try std.fs.path.join(self.alloc, &.{ dest_rel, entry.name });
                    defer self.alloc.free(child_rel);

                    std.debug.print("[{s}]..[{s}]\n", .{ child_src, child_rel });

                    try self.collectSources(
                        list,
                        child_src,
                        child_rel,
                    );
                }
            },
            else => return error.FileNotSupported,
        }
    }

    fn copyFile(
        self: *Copier,
        task: Task,
    ) !void {
        const cwd = Io.Dir.cwd();

        try cwd.copyFile(
            task.source,
            cwd,
            task.dest,
            self.io,
            .{
                .replace = true,
                .permissions = null,
            },
        );

        if (self.verbose) {
            std.debug.print(
                "{s} -> {s}\n",
                .{
                    task.source,
                    task.dest,
                },
            );
        }
    }

    fn validSources(self: *Copier) !void {
        var list: std.ArrayList(Source) = .empty;
        errdefer list.deinit(self.alloc);

        for (self.raw_sources) |path| {
            const top_name = std.fs.path.basename(path);
            try self.collectSources(&list, path, top_name);
        }

        self.sources = list;

        if (self.sources.items.len == 0)
            return error.AllSourcesInvalid;

        try self.createDestinationDirs();
    }

    fn createDestinationDirs(self: *Copier) !void {
        const cwd = std.Io.Dir.cwd();

        var created = std.StringHashMap(void).init(self.alloc);
        defer {
            var it = created.keyIterator();
            while (it.next()) |k| self.alloc.free(k.*);
            created.deinit();
        }

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        for (self.sources.items) |source| {
            const dir_rel = std.fs.path.dirname(source.dest_rel) orelse continue;
            if (created.contains(dir_rel)) continue;

            const dir_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ self.dest_dir, dir_rel });

            try cwd.createDirPath(self.io, dir_path);

            const key = try self.alloc.dupe(u8, dir_rel);
            errdefer self.alloc.free(key);

            try created.put(key, {});
        }
    }
};
