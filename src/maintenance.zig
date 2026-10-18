const std = @import("std");
const builtin = @import("builtin");

const logger = @import("logger.zig");
const metadata = @import("metadata.zig");
const install = @import("install.zig");
const wrapper = @import("wrapper.zig");

const MetaStruct = metadata.MetaStruct;

// geex's fork: a running app's install directory is marked in use by a shared lock on this file,
// which the app holds for its whole life (`hold_in_use_lock`). Cleaning up older versions takes
// an exclusive lock first, and leaves a directory it can't lock alone (`do_clean_old_versions`).
pub const IN_USE_LOCK = ".burrito-in-use";

/// Take a shared lock on `<install_dir>/.burrito-in-use` and keep it for the app's life: on
/// POSIX the descriptor survives the `execve` into the VM (close-on-exec cleared), so the
/// running BEAM holds the lock; on Windows the wrapper, which waits for the VM, holds it. Never
/// fails the launch: without the lock the app still runs, only unprotected.
pub fn hold_in_use_lock(allocator: std.mem.Allocator, install_dir: []const u8) ?std.fs.File {
    const path = std.fs.path.join(allocator, &.{ install_dir, IN_USE_LOCK }) catch return null;

    // Non-blocking: a newer version holding it exclusively is deleting this directory now.
    const file = std.fs.createFileAbsolute(path, .{
        .read = true,
        .truncate = false,
        .lock = .shared,
        .lock_nonblocking = true,
    }) catch |err| {
        std.log.debug("Not marking {s} in use: {t}", .{ install_dir, err });
        return null;
    };

    if (builtin.os.tag != .windows) {
        _ = std.posix.fcntl(file.handle, std.posix.F.SETFD, 0) catch |err| {
            std.log.debug("The in-use lock won't outlive the launcher: {t}", .{err});
        };
    }

    return file;
}

// Whether an install directory may be deleted: the exclusive lock, held until the caller closes
// it (`.claimed`), or why not: a runner holds the lock (`.in_use`), or the directory is from
// before the lock and a process runs from it (`.running`).
const Claim = union(enum) {
    claimed: ?std.fs.File,
    in_use,
    running,
};

fn claim_for_removal(allocator: std.mem.Allocator, dir: []const u8) Claim {
    const path = std.fs.path.join(allocator, &.{ dir, IN_USE_LOCK }) catch return .in_use;

    const file = std.fs.openFileAbsolute(path, .{
        .mode = .read_write,
        .lock = .exclusive,
        .lock_nonblocking = true,
    }) catch |err| switch (err) {
        error.WouldBlock => return .in_use,
        // An install from before the lock existed: in use if a process runs from it.
        error.FileNotFound => return if (runs_from(allocator, dir)) .running else .{ .claimed = null },
        else => return .in_use,
    };

    return .{ .claimed = file };
}

/// `maintenance purge`: delete every unpack of this app, the current version's too, that no
/// process uses, by the lock contract (`claim_for_removal`), and say what became of each, on
/// stdout. Some kept is not an error. One implementation of the contract on every platform, for
/// a tool that can't take a `flock` itself (a BEAM can't).
fn do_purge(install_dir: []const u8, out: *std.Io.Writer) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const app_name = metadata.parse(allocator, wrapper.RELEASE_METADATA_JSON).?.app_name;
    const base = std.fs.path.dirname(install_dir) orelse return;
    const prefix = try std.fmt.allocPrint(allocator, "{s}_erts-", .{app_name});

    var base_dir = std.fs.openDirAbsolute(base, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            try out.print("nothing to purge: {s} doesn't exist\n", .{base});
            try out.flush();
            return;
        },
        else => return err,
    };
    defer base_dir.close();

    var removed: usize = 0;
    var kept: usize = 0;
    var itr = base_dir.iterate();

    while (try itr.next()) |entry| {
        if (entry.kind != .directory or !std.mem.startsWith(u8, entry.name, prefix)) continue;

        const dir = try std.fs.path.join(allocator, &.{ base, entry.name });

        // Another app whose name begins the same, or not an unpack at all: leave it.
        const other = install.load_install_from_path(allocator, dir) catch null;
        if (other == null or !std.mem.eql(u8, other.?.metadata.app_name, app_name)) continue;

        switch (claim_for_removal(allocator, dir)) {
            .claimed => |lock| {
                defer if (lock) |file| file.close();
                try std.fs.deleteTreeAbsolute(dir);
                try out.print("removed {s}\n", .{dir});
                removed += 1;
            },
            .in_use => {
                try out.print("kept {s}: in use\n", .{dir});
                kept += 1;
            },
            .running => {
                try out.print("kept {s}: from before the in-use lock, and a process runs from it\n", .{dir});
                kept += 1;
            },
        }
    }

    try out.print("{d} removed, {d} kept\n", .{ removed, kept });
    try out.flush();
}

// Whether a process runs from `dir`, by each process's executable (`/proc/<pid>/exe`, Linux). A
// running Erlang VM's executable is the install's own `beam.smp`. Where that can't be read, the
// directory counts as in use.
fn runs_from(allocator: std.mem.Allocator, dir: []const u8) bool {
    if (builtin.os.tag != .linux) return true;

    const prefix = std.fmt.allocPrint(allocator, "{s}/", .{dir}) catch return true;
    var proc = std.fs.openDirAbsolute("/proc", .{ .iterate = true }) catch return true;
    defer proc.close();

    var itr = proc.iterate();
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var path_buf: [64]u8 = undefined;

    while (itr.next() catch return true) |entry| {
        _ = std.fmt.parseInt(u32, entry.name, 10) catch continue;
        const exe_path = std.fmt.bufPrint(&path_buf, "/proc/{s}/exe", .{entry.name}) catch continue;
        const exe = std.fs.readLinkAbsolute(exe_path, &link_buf) catch continue;
        if (std.mem.startsWith(u8, exe, prefix)) return true;
    }

    return false;
}

pub fn do_maint(args: [][:0]u8, install_dir: []const u8) !void {
    var stdout_buf: [64]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    if (args.len < 1) {
        logger.warn("No sub-command provided!", .{});
    } else {
        if (std.mem.eql(u8, args[0], "uninstall")) {
            try do_uninstall(install_dir);
        }

        if (std.mem.eql(u8, args[0], "directory")) {
            try print_install_dir(stdout, install_dir);
        }

        if (std.mem.eql(u8, args[0], "meta")) {
            try print_metadata(stdout);
        }

        if (std.mem.eql(u8, args[0], "purge")) {
            try do_purge(install_dir, stdout);
        }
    }
}

fn confirm() !bool {
    var stdin_buf: [8]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buf);
    var stdin = &stdin_reader.interface;

    logger.query("Please confirm this action [y/n]: ", .{});

    if (stdin.takeDelimiterExclusive('\n')) |user_input| {
        if (std.mem.eql(u8, user_input[0..1], "y") or std.mem.eql(u8, user_input[0..1], "Y")) {
            return true;
        }
    } else |err| {
        logger.err("Failed to confirm: {t}", .{err});
        return err;
    }

    return false;
}

fn do_uninstall(install_dir: []const u8) !void {
    logger.warn("This will uninstall the application runtime for this Burrito binary!", .{});
    if (try confirm() == false) {
        logger.warn("Uninstall was aborted!", .{});
        logger.info("Quitting.", .{});
        return;
    }

    logger.info("Deleting directory: {s}", .{install_dir});
    try std.fs.deleteTreeAbsolute(install_dir);
    logger.info("Uninstall complete!", .{});
    logger.info("Quitting.", .{});
}

fn print_metadata(out: *std.Io.Writer) !void {
    try out.print("{s}", .{wrapper.RELEASE_METADATA_JSON});
    try out.flush();
}

fn print_install_dir(out: *std.Io.Writer, install_dir: []const u8) !void {
    try out.print("{s}\n", .{install_dir});
    try out.flush();
}

pub fn do_clean_old_versions(install_prefix_path: []const u8, current_install_path: []const u8) !void {
    std.log.debug("Going to clean up older versions of this application...", .{});

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const prefix_dir = try std.fs.openDirAbsolute(install_prefix_path, .{ .access_sub_paths = true, .iterate = true });

    const current_install = try install.load_install_from_path(allocator, current_install_path);

    var itr = prefix_dir.iterate();
    while (try itr.next()) |dir| {
        if (dir.kind == .directory) {
            const possible_app_path = try std.fs.path.join(allocator, &[_][]const u8{ install_prefix_path, dir.name });
            const other_install = try install.load_install_from_path(allocator, possible_app_path);

            // If can can't figure out if this is an install dir, just ignore it
            if (other_install == null) {
                continue;
            }

            // If this isn't the same installed app as us ignore it
            if (!std.mem.eql(u8, current_install.?.metadata.app_name, other_install.?.metadata.app_name)) {
                continue;
            }

            // Compare the version, if it's older, delete the directory: unless an app still runs
            // from it (geex's fork). The exclusive lock is held while it is deleted.
            if (std.SemanticVersion.order(current_install.?.version, other_install.?.version) == .gt) {
                switch (claim_for_removal(allocator, other_install.?.install_dir_path)) {
                    .in_use, .running => {
                        std.log.debug("Kept older version (v{s}): in use", .{other_install.?.metadata.app_version});
                    },
                    .claimed => |lock| {
                        defer if (lock) |file| file.close();
                        try std.fs.deleteTreeAbsolute(other_install.?.install_dir_path);
                        logger.log_stderr("Uninstalled older version (v{s})", .{other_install.?.metadata.app_version});
                    },
                }
            }
        }
    }
}
