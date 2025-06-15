const std = @import("std");
const http = std.http;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Uri = std.Uri;
const httpfiles = @import("./parser");

pub const HttpResponse = struct {
    status_code: u16,
    headers: ArrayList(http.Header),
    body: []u8,
    allocator: Allocator,

    pub fn init(allocator: Allocator) HttpResponse {
        return .{
            .status_code = 0,
            .headers = ArrayList(http.Header).init(allocator),
            .body = &[_]u8{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *HttpResponse) void {
        for (self.headers.items) |header| {
            self.allocator.free(header.name);
            self.allocator.free(header.value);
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

        // Create the HTTP request
        var req = try self.client.open(request.method.?.toStdMethod(), uri, .{
            .server_header_buffer = try self.allocator.alloc(u8, 8192),
        });
        defer req.deinit();

        // Add headers
        for (request.headers.items) |header| {
            try req.headers.append(header.name, header.value);
        }

        // Set content length if we have a body
        if (request.body) |body| {
            req.transfer_encoding = .{ .content_length = body.len };
        } else {
            req.transfer_encoding = .{ .content_length = 0 };
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
        response.status_code = req.response.status.code();

        // Copy response headers
        var header_iterator = req.response.iterateHeaders();
        while (header_iterator.next()) |header| {
            const name = try self.allocator.dupe(u8, header.name);
            const value = try self.allocator.dupe(u8, header.value);
            try response.headers.append(.{ .name = name, .value = value });
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
    std.debug.print("Status: {d}\n", .{response.status_code});
    std.debug.print("Headers:\n");
    for (response.headers.items) |header| {
        std.debug.print("  {s}: {s}\n", .{ header.name, header.value });
    }
    std.debug.print("Body ({d} bytes):\n{s}\n", .{ response.body.len, response.body });
    std.debug.print("---\n");
}

test "HttpClient basic functionality" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = HttpClient.init(allocator);
    defer client.deinit();

    // Create a simple GET request
    var request = httpfiles.HttpRequest.init(allocator);
    defer request.deinit(allocator);

    request.method = .GET;
    request.url = "https://httpbin.org/status/200";

    // Execute the request
    var response = try client.execute(&request);
    defer response.deinit();

    // Check that we got a 200 status
    try std.testing.expectEqual(@as(u16, 200), response.status_code);
}
