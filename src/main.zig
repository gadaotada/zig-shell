const std = @import("std");
const builtin = @import("builtin");

const EXIT_CMD: []const u8 = "exit 0";

const Commands = enum { exit, type, echo, null };

const ReadInputRaw = struct {
    Cmd: Commands,
    Raw: []const u8,
};

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    const stdin = std.io.getStdIn().reader();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    // Step 1)
    const os_name: []const u8 = getOs();
    const separator: u8 = if (std.mem.eql(u8, os_name, "windows")) ';' else ':';
    // Step 2)
    const env_target = if (std.mem.eql(u8, os_name, "windows")) "Path" else "PATH";
    const raw_entries = try printEnvVars(allocator, env_target) orelse {
        try stdout.print("Env var '{s}' not found\n", .{env_target});
        return;
    };
    defer allocator.free(raw_entries);

    var entries = try getPathEntries(allocator, separator, raw_entries);
    defer entries.deinit();

    while (true) {
        try stdout.print("$ ", .{});

        var buffer: [1024]u8 = undefined;
        const line = try stdin.readUntilDelimiter(&buffer, '\n');
        const trimmed = std.mem.trimRight(u8, line, "\r\n");

        if (std.mem.eql(u8, trimmed, EXIT_CMD)) {
            break;
        } else {
            try parseCommands(allocator, trimmed, stdout, entries.items);
        }
    }
}

fn parseCommands(allocator: std.mem.Allocator, user_input: []const u8, writer: anytype, entries: []const []const u8) !void {
    const result = availableCommand(user_input);
    try executeCommand(allocator, writer, result.Cmd, result.Raw, entries);
}

fn availableCommand(user_input: []const u8) ReadInputRaw {
    if (user_input.len > 4) {
        const user_command = user_input[0..4];
        const rest_raw = user_input[5..];

        const cmd = std.meta.stringToEnum(Commands, user_command) orelse Commands.null;
        if (cmd == Commands.null) {
            return ReadInputRaw{ .Cmd = cmd, .Raw = user_input };
        } else {
            return ReadInputRaw{ .Cmd = cmd, .Raw = rest_raw };
        }
    } else {
        return ReadInputRaw{ .Cmd = Commands.null, .Raw = user_input };
    }
}

fn executeCommand(allocator: std.mem.Allocator, writer: anytype, cmd: Commands, input: []const u8, entries: []const []const u8) !void {
    switch (cmd) {
        .echo => try executeEchoCMD(writer, input),
        .type => try executeTypeCMD(allocator, writer, input, entries),
        .exit => return,
        .null => try userInputCommand(allocator, writer, input, entries),
    }
}

fn executeTypeCMD(allocator: std.mem.Allocator, writer: anytype, input: []const u8, entries: []const []const u8) !void {
    const cmd_opt = std.meta.stringToEnum(Commands, input) orelse null;
    if (cmd_opt == null) {
        const res = try findExecutables(allocator, input, entries);
        defer {
            for (res.items) |path| {
                allocator.free(path);
            }
            res.deinit();
        }

        if (res.items.len > 0) {
            for (res.items, 0..) |item, i| {
                if (i == 0) {
                    try writer.print("{s} is {s}\n", .{ input, item });
                } else {
                    break;
                }
            }
        } else {
            try writer.print("{s}: not found\n", .{input});
        }
    } else {
        try writer.print("{s} is a shell builtin\n", .{input});
    }
}

fn executeEchoCMD(writer: anytype, echo_value: []const u8) !void {
    try writer.print("{s}\n", .{echo_value});
}

fn getOs() []const u8 {
    var current_os: []const u8 = "unknown";
    const os_tag = builtin.os.tag;
    if (os_tag == .windows) {
        current_os = "windows";
    } else {
        current_os = "unix_based";
    }

    return current_os;
}

fn printEnvVars(allocator: std.mem.Allocator, env: []const u8) !?[]const u8 {
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    var iter = env_map.iterator();
    while (iter.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, env)) {
            const val = entry.value_ptr.*; // slice into the map

            // clone into our own heap memory
            const buf = try allocator.alloc(u8, val.len);
            // std.mem.copy is available in 0.14+; copyBackwards would also work
            std.mem.copyBackwards(u8, buf, val);

            return buf; // owned by caller
        }
    }
    return null;
}

fn getPathEntries(allocator: std.mem.Allocator, separator: u8, env_value: []const u8) !std.ArrayList([]const u8) {
    var path_list = std.ArrayList([]const u8).init(allocator);
    var it = std.mem.splitScalar(u8, env_value, separator);

    while (it.next()) |slice| {
        if (slice.len > 0) {
            try path_list.append(slice);
        }
    }

    return path_list;
}

fn findExecutables(allocator: std.mem.Allocator, program_name: []const u8, entries: []const []const u8) !std.ArrayList([]const u8) {
    var results = std.ArrayList([]const u8).init(allocator);
    const fs = std.fs.cwd();
    const dirSep: u8 = if (builtin.os.tag == .windows) '\\' else '/';

    // Define the extensions to try based on OS
    const windowsExts = &[_][]const u8{ ".exe", ".bat", ".cmd" };
    const unixExts = &[_][]const u8{ "", ".sh" };
    const extList: []const []const u8 = if (builtin.os.tag == .windows) windowsExts else unixExts;

    for (entries) |dir| {
        for (extList) |ext| {
            // Build candidate name: program_name + ext
            const nameLen = program_name.len + ext.len;
            const totalLen = dir.len + 1 + nameLen;
            var buf = try allocator.alloc(u8, totalLen);
            std.mem.copyBackwards(u8, buf[0..dir.len], dir);
            buf[dir.len] = dirSep;
            std.mem.copyBackwards(u8, buf[dir.len + 1 .. dir.len + 1 + program_name.len], program_name);
            std.mem.copyBackwards(u8, buf[dir.len + 1 + program_name.len ..], ext);

            // Check for existence
            if (fs.openFile(buf, .{}) catch null) |file| {
                file.close();
                try results.append(buf);
                break;
            } else {
                allocator.free(buf);
            }
        }
    }

    return results;
}

fn userInputCommand(allocator: std.mem.Allocator, writer: anytype, raw_user_input: []const u8, entries: []const []const u8) !void {
    var user_list_input = std.ArrayList([]const u8).init(allocator);
    var it = std.mem.splitScalar(u8, raw_user_input, ' ');

    while (it.next()) |slice| {
        if (slice.len > 0) {
            try user_list_input.append(slice);
        }
    }

    defer user_list_input.deinit();

    const res = try findExecutables(allocator, user_list_input.items[0], entries);
    defer {
        for (res.items) |path| {
            allocator.free(path);
        }
        res.deinit();
    }

    if (res.items.len > 0) {
        // build the child
        var child = std.process.Child.init(user_list_input.items, allocator);
        _ = try child.spawn();
        _ = try child.wait();
    } else {
        try writer.print("{s}: command not found\n", .{raw_user_input});
    }
}
