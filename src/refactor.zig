const std = @import("std");
const builtin = @import("builtin");

const BUILD_IN_COMMANDS = enum { exit, type, echo };
const OS_SPECIFICS = struct { name: if (builtin.os.tag == .windows) "windows" else "unix", sep: if (builtin.os.tag == .windows) ';' else ':', path_sep: if (builtin.os.tag == .windows) '\\' else '/' };

pub fn main() !void {
    const stdout_writer = std.io.getStdOut().writer();
    const stdin_reader = std.io.getStdIn().reader();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    while (true) {
        try stdout_writer.print("$ ", .{});

        var buffer: [1024]u8 = undefined;
        const line = try stdin_reader.readUntilDelimiter(&buffer, '\n');
        const trimmed_input = std.mem.trimRight(u8, line, "\r\n");

        try parseCommands(allocator, stdout_writer, trimmed_input);
    }
}

fn parseCommands(
    allocator: std.mem.Allocator,
    writer: anytype,
    user_input: []const u8,
) !void {}
