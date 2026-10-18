const std = @import("std");

// geex's fork: every level goes to stderr. Stdout is the app's: a stdio protocol (an MCP server
// speaking JSON-RPC) breaks on a line of the wrapper's before it. What a `maintenance`
// subcommand was asked to print still goes to stdout, written there by the subcommand itself.

pub fn query(comptime message: []const u8, args: anytype) void {
    printToStderr("[?] " ++ message, args);
}

pub fn log_stderr(comptime message: []const u8, args: anytype) void {
    printToStderr("[l] " ++ message ++ "\n", args);
}

pub fn info(comptime message: []const u8, args: anytype) void {
    printToStderr("[i] " ++ message ++ "\n", args);
}

pub fn warn(comptime message: []const u8, args: anytype) void {
    printToStderr("[w] " ++ message ++ "\n", args);
}

pub fn err(comptime message: []const u8, args: anytype) void {
    printToStderr("[!] " ++ message ++ "\n", args);
}

pub fn crit(comptime message: []const u8, args: anytype) void {
    printToStderr("[!!] " ++ message ++ "\n", args);
}

fn printToStderr(comptime message: []const u8, args: anytype) void {
    var stderr_buf: [64]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    const stderr = &stderr_writer.interface;

    stderr.print(message, args) catch {};
    stderr.flush() catch {};
}
