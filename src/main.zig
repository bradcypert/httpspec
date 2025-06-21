const std = @import("std");
const HttpParser = @import("./httpfile/parser.zig");
const Client = @import("./httpfile/http_client.zig");
const AssertionChecker = @import("./httpfile/assertion_checker.zig");
const clap = @import("clap");

pub fn main() !void {
    var debug = std.heap.DebugAllocator(.{}){};
    defer _ = debug.deinit();

    const allocator = debug.allocator();

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
    }

    var files = std.ArrayList([]const u8).init(allocator);
    defer {
        for (files.items) |file| {
            allocator.free(file);
        }
        files.deinit();
    }

    if (res.positionals[0].len == 0) {
        // If no positional arguments are provided, we assume we want to run all HTTP files in the current directory and subdirectories
        const http_files = try listHttpFiles(allocator, ".");
        defer allocator.free(http_files);
        for (http_files) |file| {
            try files.append(file);
        }
    }

    for (res.positionals[0]) |pos| {
        if (std.ascii.eqlIgnoreCase(std.fs.path.extension(pos), ".http") or std.ascii.eqlIgnoreCase(std.fs.path.extension(pos), ".httpspec")) {
            // If a positional argument is provided, we assume it's a file
            try files.append(pos);
        } else {
            // if its NOT a directory we return an error
            const file_info = try std.fs.cwd().statFile(pos);
            if (file_info.kind != .directory) {
                return error.InvalidPositionalArgument;
            }
            // If it's a directory, we list all HTTP files in it
            const http_files = try listHttpFiles(allocator, pos);
            defer allocator.free(http_files);
            for (http_files) |file| {
                try files.append(file);
            }
        }
    }

    var test_count: usize = 0;
    var test_pass: usize = 0;
    var test_fail: usize = 0;
    // TODO: This is simple, but completely serial. Ideally, we'd span this across multiple threads.
    for (files.items) |pos| {
        test_count += 1;
        var has_failure = false;
        // TODO: Each one gets its own areana?
        std.io.getStdOut().writer().print("Running test {d}: {s}\n", .{ test_count, pos }) catch |err| {
            std.debug.print("Error writing to stdout: {}\n", .{err});
            return err;
        };
        var items = try HttpParser.parseFile(allocator, pos);
        const owned_items = try items.toOwnedSlice();
        defer allocator.free(owned_items);
        var client = Client.HttpClient.init(allocator);
        defer client.deinit();
        for (owned_items) |*owned_item| {
            defer owned_item.deinit(allocator);
            var responses = try client.execute(owned_item);
            defer responses.deinit();
            // Check assertions
            AssertionChecker.check(owned_item, responses) catch {
                has_failure = true;
                break;
            };
        }
        if (!has_failure) {
            test_pass += 1;
        } else {
            test_fail += 1;
        }
    }

    std.io.getStdOut().writer().print(
        \\
        \\All {d} tests ran successfully!
        \\
        \\Pass: {d}
        \\Fail: {d}
        \\
    , .{ test_count, test_pass, test_fail }) catch |err| {
        std.debug.print("Error writing to stdout: {}\n", .{err});
        return err;
    };
}

// List all HTTP files in the given directory and its subdirectories
// This function returns a slice of file paths that end with .http or .httpspec
fn listHttpFiles(allocator: std.mem.Allocator, dir: []const u8) ![][]const u8 {
    var files = std.ArrayList([]const u8).init(allocator);
    defer files.deinit();

    var dir_entry = try std.fs.cwd().openDir(dir, .{});
    defer dir_entry.close();

    var it = dir_entry.iterate();
    while (try it.next()) |entry| {
        if (entry.kind == .directory) {
            const paths = &[_][]const u8{ dir, entry.name };
            const subdir = std.fs.path.join(allocator, paths) catch return error.OutOfMemory;
            defer allocator.free(subdir);
            const sub_files = try listHttpFiles(allocator, subdir);
            defer allocator.free(sub_files);
            for (sub_files) |file| {
                try files.append(file);
            }
        } else if (std.mem.eql(u8, std.fs.path.extension(entry.name), ".http") or
            std.mem.eql(u8, std.fs.path.extension(entry.name), ".httpspec"))
        {
            const paths = &[_][]const u8{ dir, entry.name };
            const file_path = std.fs.path.join(allocator, paths) catch return error.OutOfMemory;
            try files.append(file_path);
        }
    }

    return files.toOwnedSlice();
}
