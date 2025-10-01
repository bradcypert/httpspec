const std = @import("std");
const curl = @import("curl");
const http = std.http;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Uri = std.Uri;
const httpfiles = @import("./parser.zig");

/// Represents an HTTP response, including status, headers, and body.
pub const HttpResponse = struct {
    status: ?http.Status,
    headers: std.StringHashMap([]const u8),
    body: []u8,
    allocator: Allocator,

    pub fn init(allocator: Allocator) HttpResponse {
        return .{
            .status = null,
            .headers = std.StringHashMap([]const u8).init(allocator),
            .body = &[_]u8{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *HttpResponse) void {
        var headers = self.headers.iterator();
        while (headers.next()) |header| {
            self.allocator.free(header.value_ptr.*);
            self.allocator.free(header.key_ptr.*);
        }
        self.headers.deinit();
        if (self.body.len > 0) {
            self.allocator.free(self.body);
        }
    }
};

/// HTTP client for executing requests defined in httpfiles.HttpRequest.
pub const HttpClient = struct {
    allocator: Allocator,
    client: http.Client,

    pub fn init(allocator: Allocator) HttpClient {
        return .{
            .allocator = allocator,
            .client = http.Client{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *HttpClient) void {
        self.client.deinit();
    }

    fn map_method_for_curl(method: std.http.Method) !curl.Easy.Method {
        return switch (method) {
            .GET => .GET,
            .POST => .POST,
            .PUT => .PUT,
            .DELETE => .DELETE,
            .HEAD => .HEAD,
            .PATCH => .PATCH,
            else => error.UnsupportedMethod,
        };
    }

    /// Executes a single HTTP request and returns the response.
    pub fn execute(self: *HttpClient, request: *const httpfiles.HttpRequest) !HttpResponse {
        const ca_bundle = try curl.allocCABundle(self.allocator);
        defer ca_bundle.deinit();
        const easy = try curl.Easy.init(.{
            .ca_bundle = ca_bundle,
        });
        defer easy.deinit();

        var writer = std.Io.Writer.Allocating.init(self.allocator);
        defer writer.deinit();

        var headers: std.ArrayList([]const u8) = .empty;
        for (request.headers.items) |header| {
            const s = try std.fmt.allocPrintSentinel(self.allocator, "{s}: {s}", .{ header.name, header.value }, 0);
            try headers.append(self.allocator, s);
        }

        defer {
            for (headers.items) |header| {
                self.allocator.free(header);
            }
            headers.deinit(self.allocator);
        }

        const url = try self.allocator.dupeZ(u8, request.url);
        defer self.allocator.free(url);
        const resp = try easy.fetch(url, .{
            .method = try map_method_for_curl(request.method orelse return error.RequestMethodNotSet),
            // TODO: Is it possible to remove the ptrCast?
            .headers = @ptrCast(headers.items),
            .writer = &writer.writer,
            .body = request.body,
        });

        const resp_body = try self.allocator.dupe(u8, writer.writer.buffered());
        var response = HttpResponse.init(self.allocator);
        response.status = @enumFromInt(resp.status_code);

        var header_iterator = try resp.iterateHeaders(.{});
        while (try header_iterator.next()) |header| {
            std.debug.print("{s}: {s}\n", .{ header.name, header.get() });
            const name = try std.ascii.allocLowerString(self.allocator, header.name);
            const value = try self.allocator.dupe(u8, header.get());
            try response.headers.put(name, value);
        }

        response.body = resp_body;
        return response;
    }

    /// Executes multiple HTTP requests and returns an array of responses.
    pub fn executeRequests(self: *HttpClient, requests: []const httpfiles.HttpRequest) !ArrayList(HttpResponse) {
        var responses = ArrayList(HttpResponse).init(self.allocator);
        errdefer {
            for (responses.items) |*response| response.deinit();
            responses.deinit();
        }

        for (requests) |*request| {
            const response = try self.execute(request);
            try responses.append(response);
        }

        return responses;
    }
};

// Utility function for backwards compatibility.
pub fn printResponse(response: *const HttpResponse) void {
    std.debug.print("Status: {d}\n", .{response.status});
    std.debug.print("Headers:\n");
    for (response.headers.items) |header| {
        std.debug.print("  {s}: {s}\n", .{ header.name, header.value });
    }
    std.debug.print("Body ({d} bytes):\n{s}\n", .{ response.body.len, response.body });
    std.debug.print("---\n");
}

test "HttpClient basic functionality" {
    const allocator = std.testing.allocator;

    var client = HttpClient.init(allocator);
    defer client.deinit();

    var request = httpfiles.HttpRequest.init();
    defer request.deinit(allocator);

    request.method = .GET;
    // TODO: The request de-allocates the memory used by the url in the deinit method.
    // Because of this, with this test, we have to dupe it or else it cant deinit a global string.
    // Needing to do this is a sign that something is off here, but also newing up requests directly
    // isn't really intended either. Either way, need to look into this further.
    request.url = try allocator.dupe(u8, "https://httpbin.org/status/200");

    var response = try client.execute(&request);
    defer response.deinit();

    try std.testing.expectEqual(http.Status.ok, response.status.?);
}
