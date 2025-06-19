const std = @import("std");
const http = std.http;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Uri = std.Uri;
const httpfiles = @import("./parser.zig");

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

    pub fn execute(self: *HttpClient, request: *const httpfiles.HttpRequest) !HttpResponse {
        if (request.method == null) {
            return error.MissingHttpMethod;
        }

        // Parse the URL
        const uri = try Uri.parse(request.url);

        var server_header_buf: [4096]u8 = undefined;

        // Create the HTTP request
        var req = try self.client.open(request.method.?, uri, .{
            .server_header_buffer = &server_header_buf,
            .extra_headers = request.headers.items,
        });
        defer req.deinit();

        // Set content length if we have a body
        if (request.body) |body| {
            req.transfer_encoding = .{ .content_length = body.len };
        } else {
            //req.transfer_encoding = .{ .content_length = 0 };
        }

        // Send the request
        try req.send();

        // Send body if present
        if (request.body) |body| {
            try req.writeAll(body);
        }

        try req.finish();

        // Wait for response
        try req.wait();

        // Read the response
        var response = HttpResponse.init(self.allocator);
        response.status = req.response.status;

        // Copy response headers
        var header_iterator = req.response.iterateHeaders();
        while (header_iterator.next()) |header| {
            const name = try self.allocator.dupe(u8, header.name);
            const value = try self.allocator.dupe(u8, header.value);
            try response.headers.put(name, value);
        }

        // Read response body
        const body_reader = req.reader();
        const body_content = try body_reader.readAllAlloc(self.allocator, std.math.maxInt(usize));
        response.body = body_content;

        return response;
    }

    pub fn executeRequests(self: *HttpClient, requests: []const httpfiles.HttpRequest) !ArrayList(HttpResponse) {
        var responses = ArrayList(HttpResponse).init(self.allocator);
        errdefer {
            for (responses.items) |*response| {
                response.deinit();
            }
            responses.deinit();
        }

        for (requests) |*request| {
            const response = try self.execute(request);
            try responses.append(response);
        }

        return responses;
    }
};

// Utility function to print response details
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

    // Create a simple GET request
    var request = httpfiles.HttpRequest.init(allocator);
    defer request.deinit(allocator);

    request.method = .GET;
    // TODO: The request de-allocates the memory used by the url in the deinit method.
    // Because of this, with this test, we have to dupe it or else it cant deinit a global string.
    // Needing to do this is a sign that something is off here, but also newing up requests directly
    // isn't really intended either. Either way, need to look into this further.
    request.url = try allocator.dupe(u8, "https://httpbin.org/status/200");

    // Execute the request
    var response = try client.execute(&request);
    defer response.deinit();

    // Check that we got a 200 status
    try std.testing.expectEqual(http.Status.ok, response.status.?);
}
