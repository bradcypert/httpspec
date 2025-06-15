//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.
const std = @import("std");
const HttpParser = @import("./httpfile/parser.zig");
const Client = @import("./httpfile/http_client.zig");
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

    // TODO: This is simple, but completely serial. Ideally, we'd span this across multiple
    // threads.
    // var request_files = std.ArrayList([]HttpParser.HttpRequest).init(allocator);
    for (res.positionals[0]) |pos| {
        // TODO: Each one gets its own areana?
        var items = try HttpParser.parseFile(allocator, pos);
        const owned_items = try items.toOwnedSlice();
        defer allocator.free(owned_items);
        var client = Client.HttpClient.init(allocator);
        defer client.deinit();
        for (owned_items) |*owned_item| {
            var responses = try client.execute(owned_item);
            defer responses.deinit();
            std.debug.print("Response: {s}\n", .{responses.body});
            owned_item.deinit(allocator);
        }
    }
}
