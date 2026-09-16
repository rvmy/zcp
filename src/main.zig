const std = @import("std");
const args = @import("args.zig");
const Copier = @import("copy.zig").Copier;
const Io = std.Io;

const zcp = @import("zcp");

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = Io.File.Writer.init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = Io.File.Writer.init(.stderr(), init.io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    const argv = try init.minimal.args.toSlice(arena);

    if (argv.len == 1) {
        try args.printHelp(stdout);
        try stdout.flush();
        return;
    }

    const parsed_args = args.Args.parse(argv[1..]) catch |err| {
        switch (err) {
            error.MissingThreadCount => {
                try stderr.writeAll("zcp: option '-t' requires a thread count\n");
            },
            error.InvalidThreadCount => {
                try stderr.writeAll("zcp: invalid thread count: expect a number between 1 and 64\n");
            },
            error.MissingSource => {
                try stderr.writeAll("zcp: missing source operand\n");
            },
            error.MissingDestination => {
                try stderr.writeAll("zcp: missing destination operand\n");
            },
        }
        try stderr.flush();
        return;
    };

    var copier = Copier.init(arena, init.io, parsed_args);
    try copier.run();
    std.debug.print("{any}", .{parsed_args});
}
