const std = @import("std");

pub const Threads = union(enum) {
    single,
    multi: u8,
};

pub const ArgsError = error{
    MissingThreadCount,
    InvalidThreadCount,
    MissingSource,
    MissingDestination,
};

pub const Args = struct {
    recursive: bool = false,
    verbose: bool = false,
    threads: Threads = .single,
    sources: []const []const u8 = undefined,
    destination: []const u8 = undefined,

    pub fn parse(args: []const []const u8) ArgsError!Args {
        var result = Args{};
        var index: usize = 0;
        const max_threads: u8 = 64;
        while (index < args.len) : (index += 1) {
            const arg = args[index];
            if (std.mem.eql(u8, arg, "-r")) {
                result.recursive = true;
            } else if (std.mem.eql(u8, arg, "-v")) {
                result.verbose = true;
            } else if (std.mem.eql(u8, arg, "-t")) {
                index += 1;

                if (index >= args.len) {
                    return error.MissingThreadCount;
                }

                const count = std.fmt.parseInt(u8, args[index], 10) catch {
                    return error.InvalidThreadCount;
                };

                if (count == 0 or count > max_threads) {
                    return error.InvalidThreadCount;
                }

                if (count > 1) {
                    result.threads = .{ .multi = count };
                }
            } else {
                break;
            }
        }

        if (index >= args.len) {
            return error.MissingSource;
        }

        if (index + 1 >= args.len) {
            return error.MissingDestination;
        }

        const sources = args[index .. args.len - 1];
        const destination = args[args.len - 1];

        result.sources = sources;
        result.destination = destination;

        return result;
    }
};

pub fn printHelp(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\Usage:
        \\ zcp [opions] <source>... <destination>
        \\
        \\Opions:
        \\ -r Copy directories recursively
        \\ -t N Use N threads (1-64, default: single-threaded)
        \\ -v Verbose output
    );
}
