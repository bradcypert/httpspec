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

    var test_count: usize = 0;
    var test_pass: usize = 0;
    var test_fail: usize = 0;
    // TODO: This is simple, but completely serial. Ideally, we'd span this across multiple threads.
    // TODO: Need to make this handle directories as well.
    // TODO: Need to make this handle no positional inputs (i.e., run all files in subdirectories).
    for (res.positionals[0]) |pos| {
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
