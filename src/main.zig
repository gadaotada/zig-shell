const std = @import("std");
const builtin = @import("builtin");

const Error = enum {
    NOPATHS,
};
const BUILD_IN_COMMANDS = enum {
    exit,
    type,
    echo,
};

const OS_SPECIFICS = struct {
    is_windows: bool,
    sep: []const u8,
    path_sep: u8,
    windowsExts: [3][]const u8,
    unixExts: [2][]const u8,
};

const os_specifics = OS_SPECIFICS{
    .is_windows = builtin.os.tag == .windows,
    .sep = if (builtin.os.tag == .windows) ";" else ":",
    .path_sep = if (builtin.os.tag == .windows) '\\' else '/',
    .windowsExts = .{ ".exe", ".bat", ".cmd" },
    .unixExts = .{ "", ".sh" },
};

const sys_executable = struct {
    name: ?[]const u8,
    path: ?[]u8,
};

var RUNNING = true;

pub fn main() !void {
    const stdout_writer = std.io.getStdOut().writer();
    const stdin_reader = std.io.getStdIn().reader();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    while (RUNNING) {
        try stdout_writer.print("$ ", .{});

        var buffer: [1024]u8 = undefined;
        const raw_input = try stdin_reader.readUntilDelimiter(&buffer, '\n');
        const line = raw_input[0 .. raw_input.len - 1];

        var user_input = std.mem.splitSequence(u8, line, " ");
        const command = user_input.first();
        const args = user_input.rest();

        // std.debug.print("command is: {s}\n", .{command});
        // std.debug.print("args are: {s}\n", .{args});

        try handleCommands(allocator, stdout_writer, command, args);
    }
}

fn handleCommands(
    allocator: std.mem.Allocator,
    writer: anytype,
    command: []const u8,
    args: []const u8,
) !void {
    // BUILD INS PART
    const cmd = std.meta.stringToEnum(BUILD_IN_COMMANDS, command) orelse {
        const is_executed = try handleSystemExecutables(allocator, command, args); //writer, command, args);

        if (is_executed) {
            return;
        }

        try writer.print("{s}: command not found\n", .{command});
        return;
    };

    switch (cmd) {
        .echo => try writer.print("{s}\n", .{args}),
        .exit => RUNNING = false,
        .type => try executeTypeCmd(allocator, writer, args),
    }
}

fn executeTypeCmd(allocator: std.mem.Allocator, writer: anytype, args: []const u8) !void {
    if (std.meta.stringToEnum(BUILD_IN_COMMANDS, args)) |_| {
        try writer.print("{s} is a shell builtin\n", .{args});
        return;
    }

    const sys_exe = try findSysExecutables(allocator, args);
    defer if (sys_exe.path) |p| allocator.free(p);

    if (sys_exe.path) |path| {
        try writer.print("{s} is {s}\n", .{ sys_exe.name.?, path });
    } else {
        try writer.print("{s}: not found\n", .{args});
    }
}

fn handleSystemExecutables(
    allocator: std.mem.Allocator,
    // writer: anytype,
    command: []const u8,
    args: []const u8,
) !bool {
    const sys_exe = try findSysExecutables(allocator, command);
    defer if (sys_exe.path) |p| allocator.free(p);

    if (sys_exe.path == null) {
        //try writer.print("NO EXECUTABLES FOUND...\n", .{});
        return false;
    } else {
        try executeSysCmd(allocator, sys_exe, args);
        return true;
    }
}

fn findSysExecutables(allocator: std.mem.Allocator, command: []const u8) !sys_executable {
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    const path_env_str = if (os_specifics.is_windows) "Path" else "PATH";
    const path_value = env_map.get(path_env_str) orelse {
        return sys_executable{ .name = command, .path = null };
    };

    const ext_list = if (os_specifics.is_windows) os_specifics.windowsExts else os_specifics.unixExts;
    var dirs = std.mem.splitSequence(u8, path_value, os_specifics.sep);

    while (dirs.next()) |dir| {
        for (ext_list) |ext| {
            const nameLen = command.len + ext.len;
            const totalLen = dir.len + 1 + nameLen;
            var buf = try allocator.alloc(u8, totalLen);

            std.mem.copyBackwards(u8, buf[0..dir.len], dir);
            buf[dir.len] = os_specifics.path_sep;
            std.mem.copyBackwards(u8, buf[dir.len + 1 .. dir.len + 1 + command.len], command);
            std.mem.copyBackwards(u8, buf[dir.len + 1 + command.len ..], ext);

            if (std.fs.cwd().openFile(buf, .{}) catch null) |file| {
                file.close();
                return sys_executable{
                    .name = command,
                    .path = buf,
                };
            } else {
                allocator.free(buf);
            }
        }
    }

    return sys_executable{ .name = command, .path = null };
}

fn executeSysCmd(allocator: std.mem.Allocator, current_exe: sys_executable, args: []const u8) !void {
    var new_arr_args = std.ArrayList([]const u8).init(allocator);
    defer new_arr_args.deinit();

    try new_arr_args.append(current_exe.name.?);
    try new_arr_args.append(args);

    var child = std.process.Child.init(new_arr_args.items, allocator);
    _ = try child.spawn();
    _ = try child.wait();
}
