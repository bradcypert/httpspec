const std = @import("std");
const clap = @import("clap");

const HttpParser = @import("./httpfile/parser.zig");
const Client = @import("./httpfile/http_client.zig");
const AssertionChecker = @import("./httpfile/assertion_checker.zig");
const TestReporter = @import("./reporters/test_reporter.zig");

pub fn main(init: std.process.Init) !void {
    // Use a debug allocator for leak detection.
    const allocator = init.gpa;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    // Parse CLI arguments.
    const params = comptime clap.parseParamsComptime(
        \\-h, --help            Display this help and exit
        \\<str>...              Executes the HTTP specs in the provided files (if omitted, all files in subdirectories will be ran instead)
    );
    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, init.minimal.args, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        diag.report(stderr, err) catch {};
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        std.debug.print("--help\n", .{});
        return;
    }

    // Discover all HTTP spec files to run.
    var files: std.ArrayList([]const u8) = .empty;
    defer {
        for (files.items) |file| allocator.free(file);
        files.deinit(allocator);
    }
    try collectSpecFiles(init.io, allocator, &files, res);

    var group: std.Io.Group = .init;
    errdefer group.cancel(init.io);

    var reporter = TestReporter.BasicReporter.init();

    // Run all tests in parallel.
    for (files.items) |path| {
        group.async(init.io, runTest, .{ init.io, allocator, &reporter, path, stderr });
    }
    try group.await(init.io);

    // Print summary.
    reporter.report(stdout);
}

/// Collects all HTTP spec files to run, based on CLI args.
fn collectSpecFiles(
    io: std.Io,
    allocator: std.mem.Allocator,
    files: *std.ArrayList([]const u8),
    res: anytype,
) !void {
    if (res.positionals[0].len == 0) {
        // No args: find all .http/.httpspec files recursively from cwd.
        const http_files = try listHttpFiles(io, allocator, ".");
        defer allocator.free(http_files);
        for (http_files) |file| try files.append(allocator, file);
    } else {
        // Args: treat as files or directories.
        for (res.positionals[0]) |pos| {
            if (std.ascii.eqlIgnoreCase(std.fs.path.extension(pos), ".http") or
                std.ascii.eqlIgnoreCase(std.fs.path.extension(pos), ".httpspec"))
            {
                try files.append(allocator, try allocator.dupe(u8, pos));
            } else {
                const cwd = std.Io.Dir.cwd();
                const file_info = try cwd.statFile(io, pos, .{});
                if (file_info.kind != .directory) return error.InvalidPositionalArgument;
                const http_files = try listHttpFiles(io, allocator, pos);
                defer allocator.free(http_files);
                for (http_files) |file| try files.append(allocator, file);
            }
        }
    }
}

/// Runs all requests in a spec file and updates the reporter.
fn runTest(
    io: std.Io,
    base_allocator: std.mem.Allocator,
    reporter: *TestReporter.BasicReporter,
    path: []const u8,
    stderr: *std.Io.Writer,
) !void {
    // Create arena allocator for this test to provide memory isolation
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit(); // Automatically frees all test allocations
    const allocator = arena.allocator();

    var has_failure = false;
    try reporter.incTestCount(io);

    var items = HttpParser.parseFile(io, allocator, path) catch |err| {
        try reporter.incTestInvalid(io);
        std.debug.print("Failed to parse file {s}: {s}\n", .{ path, @errorName(err) });
        return;
    };
    const owned_items = items.toOwnedSlice(allocator) catch |err| {
        try reporter.incTestInvalid(io);
        std.debug.print("Failed to convert items to owned slice in file {s}: {s}\n", .{ path, @errorName(err) });
        return;
    };
    // Note: No need to manually free owned_items since arena will handle it

    var client = Client.HttpClient.init(io, allocator);
    defer client.deinit();

    for (owned_items) |*owned_item| {
        // Note: No need to manually deinit owned_item since arena will handle it
        var responses = client.execute(owned_item) catch |err| {
            try reporter.incTestInvalid(io);
            std.debug.print("Failed to execute request in file {s}: {s}\n", .{ path, @errorName(err) });
            return;
        };
        defer responses.deinit();
        var diagnostic = AssertionChecker.AssertionDiagnostic.init(allocator);
        defer diagnostic.deinit();
        AssertionChecker.check(owned_item, responses, &diagnostic, path);
        if (AssertionChecker.hasFailures(&diagnostic)) {
            AssertionChecker.reportFailures(&diagnostic, stderr) catch {};
            has_failure = true;
            break;
        }
    }
    if (!has_failure) {
        try reporter.incTestPass(io);
    } else {
        try reporter.incTestFail(io);
    }
}

/// Recursively finds all .http/.httpspec files in a directory.
fn listHttpFiles(io: std.Io, allocator: std.mem.Allocator, dir_path: []const u8) ![][]const u8 {
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(allocator);

    const cwd = std.Io.Dir.cwd();
    var dir_entry = try std.Io.Dir.openDir(cwd, io, dir_path, .{ .iterate = true });
    defer dir_entry.close(io);

    var it = dir_entry.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory) {
            if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
            const subdir = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.name });
            defer allocator.free(subdir);
            const sub_files = try listHttpFiles(io, allocator, subdir);
            defer allocator.free(sub_files);
            for (sub_files) |file| try files.append(allocator, file);
        } else if (std.mem.eql(u8, std.fs.path.extension(entry.name), ".http") or
            std.mem.eql(u8, std.fs.path.extension(entry.name), ".httpspec"))
        {
            const file_path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.name });
            try files.append(allocator, file_path);
        }
    }
    return files.toOwnedSlice(allocator);
}
