const std = @import("std");
const clap = @import("clap");

const HttpParser = @import("./httpfile/parser.zig");
const Client = @import("./httpfile/http_client.zig");
const AssertionChecker = @import("./httpfile/assertion_checker.zig");
const TestReporter = @import("./reporters/test_reporter.zig");

pub fn main() !void {
    // Use a debug allocator for leak detection.
    var debug = std.heap.DebugAllocator(.{}){};
    defer _ = debug.deinit();
    const allocator = debug.allocator();

    // Determine thread count from environment.
    const threads = std.process.parseEnvVarInt("HTTP_THREAD_COUNT", usize, 10) catch 1;

    // Parse CLI arguments.
    const params = comptime clap.parseParamsComptime(
        \\-h, --help            Display this help and exit
        \\<str>...              Executes the HTTP specs in the provided files (if omitted, all files in subdirectories will be ran instead)
    );
    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        std.debug.print("--help\n", .{});
        return;
    }

    // Discover all HTTP spec files to run.
    var files = std.ArrayList([]const u8).init(allocator);
    defer {
        for (files.items) |file| allocator.free(file);
        files.deinit();
    }
    try collectSpecFiles(allocator, &files, res);

    // Set up thread pool and reporter.
    var pool: std.Thread.Pool = undefined;
    try pool.init(.{
        .allocator = allocator,
        .n_jobs = threads,
    });
    defer pool.deinit();

    var wg: std.Thread.WaitGroup = .{};
    var reporter = TestReporter.BasicReporter.init();

    // Run all tests in parallel.
    for (files.items) |path| {
        pool.spawnWg(&wg, runTest, .{ allocator, &reporter, path });
    }
    wg.wait();

    // Print summary.
    reporter.report(std.io.getStdOut().writer());
}

/// Collects all HTTP spec files to run, based on CLI args.
fn collectSpecFiles(
    allocator: std.mem.Allocator,
    files: *std.ArrayList([]const u8),
    res: anytype,
) !void {
    if (res.positionals[0].len == 0) {
        // No args: find all .http/.httpspec files recursively from cwd.
        const http_files = try listHttpFiles(allocator, ".");
        defer allocator.free(http_files);
        for (http_files) |file| try files.append(file);
    } else {
        // Args: treat as files or directories.
        for (res.positionals[0]) |pos| {
            if (std.ascii.eqlIgnoreCase(std.fs.path.extension(pos), ".http") or
                std.ascii.eqlIgnoreCase(std.fs.path.extension(pos), ".httpspec"))
            {
                try files.append(pos);
            } else {
                const file_info = try std.fs.cwd().statFile(pos);
                if (file_info.kind != .directory) return error.InvalidPositionalArgument;
                const http_files = try listHttpFiles(allocator, pos);
                defer allocator.free(http_files);
                for (http_files) |file| try files.append(file);
            }
        }
    }
}

/// Runs all requests in a spec file and updates the reporter.
fn runTest(
    allocator: std.mem.Allocator,
    reporter: *TestReporter.BasicReporter,
    path: []const u8,
) void {
    var has_failure = false;
    reporter.incTestCount();

    var items = HttpParser.parseFile(allocator, path) catch |err| {
        reporter.incTestInvalid();
        std.debug.print("Failed to parse file {s}: {s}\n", .{ path, @errorName(err) });
        return;
    };
    const owned_items = items.toOwnedSlice() catch |err| {
        reporter.incTestInvalid();
        std.debug.print("Failed to convert items to owned slice in file {s}: {s}\n", .{ path, @errorName(err) });
        return;
    };
    defer allocator.free(owned_items);

    var client = Client.HttpClient.init(allocator);
    defer client.deinit();

    for (owned_items) |*owned_item| {
        defer owned_item.deinit(allocator);
        var responses = client.execute(owned_item) catch |err| {
            reporter.incTestInvalid();
            std.debug.print("Failed to execute request in file {s}: {s}\n", .{ path, @errorName(err) });
            return;
        };
        defer responses.deinit();
        var diagnostic = AssertionChecker.AssertionDiagnostic.init(allocator);
        defer diagnostic.deinit();
        AssertionChecker.check(owned_item, responses, &diagnostic, path);
        if (AssertionChecker.hasFailures(&diagnostic)) {
            AssertionChecker.reportFailures(&diagnostic, std.io.getStdErr().writer()) catch {};
            has_failure = true;
            break;
        }
    }
    if (!has_failure) {
        reporter.incTestPass();
    } else {
        reporter.incTestFail();
    }
}

/// Recursively finds all .http/.httpspec files in a directory.
fn listHttpFiles(allocator: std.mem.Allocator, dir: []const u8) ![][]const u8 {
    var files = std.ArrayList([]const u8).init(allocator);
    defer files.deinit();

    var dir_entry = try std.fs.cwd().openDir(dir, .{});
    defer dir_entry.close();

    var it = dir_entry.iterate();
    while (try it.next()) |entry| {
        if (entry.kind == .directory) {
            if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
            const subdir = try std.fs.path.join(allocator, &[_][]const u8{ dir, entry.name });
            defer allocator.free(subdir);
            const sub_files = try listHttpFiles(allocator, subdir);
            defer allocator.free(sub_files);
            for (sub_files) |file| try files.append(file);
        } else if (std.mem.eql(u8, std.fs.path.extension(entry.name), ".http") or
            std.mem.eql(u8, std.fs.path.extension(entry.name), ".httpspec"))
        {
            const file_path = try std.fs.path.join(allocator, &[_][]const u8{ dir, entry.name });
            try files.append(file_path);
        }
    }
    return files.toOwnedSlice();
}
