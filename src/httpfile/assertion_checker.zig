test "HttpParser supports contains and not_contains for headers" {
    const allocator = std.testing.allocator;

    var assertions = std.ArrayList(HttpParser.Assertion).init(allocator);
    defer assertions.deinit();

    // Should pass: header contains "json"
    try assertions.append(HttpParser.Assertion{
        .key = "header[\"content-type\"]",
        .value = "json",
        .assertion_type = .contains,
    });

    // Should pass: header does not contain "xml"
    try assertions.append(HttpParser.Assertion{
        .key = "header[\"content-type\"]",
        .value = "xml",
        .assertion_type = .not_contains,
    });

    var request = HttpParser.HttpRequest{
        .method = .GET,
        .url = "https://api.example.com",
        .headers = std.ArrayList(http.Header).init(allocator),
        .assertions = assertions,
        .body = null,
    };

    var response_headers = std.StringHashMap([]const u8).init(allocator);
    try response_headers.put("content-type", "application/json");
    defer response_headers.deinit();

    const body = try allocator.dupe(u8, "irrelevant");
    defer allocator.free(body);
    const response = Client.HttpResponse{
        .status = http.Status.ok,
        .headers = response_headers,
        .body = body,
        .allocator = allocator,
    };

    try check(&request, response);
}
const std = @import("std");
const http = std.http;
const HttpParser = @import("./parser.zig");
const Client = @import("./http_client.zig");

pub fn check(request: *HttpParser.HttpRequest, response: Client.HttpResponse) !void {
    const stderr = std.io.getStdErr().writer();
    for (request.assertions.items) |assertion| {
        switch (assertion.assertion_type) {
            .equal => {
                if (std.ascii.eqlIgnoreCase(assertion.key, "status")) {
                    const assert_status_code = try std.fmt.parseInt(u16, assertion.value, 10);
                    if (response.status != try std.meta.intToEnum(http.Status, assert_status_code)) {
                        stderr.print("[Fail] Expected status code {d}, got {d}\n", .{ assert_status_code, @intFromEnum(response.status.?) }) catch {};
                        return error.StatusCodeMismatch;
                    }
                } else if (std.ascii.eqlIgnoreCase(assertion.key, "body")) {
                    if (!std.mem.eql(u8, response.body, assertion.value)) {
                        stderr.print("[Fail] Expected body content \"{s}\", got \"{s}\"\n", .{ assertion.value, response.body }) catch {};
                        return error.BodyContentMismatch;
                    }
                } else if (std.mem.startsWith(u8, assertion.key, "header[\"")) {
                    // Extract the header name from the assertion key
                    const header_name = assertion.key[8 .. assertion.key.len - 2];
                    const actual_value = response.headers.get(header_name);
                    if (actual_value == null or !std.ascii.eqlIgnoreCase(actual_value.?, assertion.value)) {
                        stderr.print("[Fail] Expected header \"{s}\" to be \"{s}\", got \"{s}\"\n", .{ header_name, assertion.value, actual_value orelse "null" }) catch {};
                        return error.HeaderMismatch;
                    }
                } else {
                    stderr.print("[Fail] Invalid assertion key: {s}\n", .{assertion.key}) catch {};
                    return error.InvalidAssertionKey;
                }
            },
            .not_equal => {
                if (std.ascii.eqlIgnoreCase(assertion.key, "status")) {
                    const assert_status_code = try std.fmt.parseInt(u16, assertion.value, 10);
                    if (response.status == try std.meta.intToEnum(http.Status, assert_status_code)) {
                        stderr.print("[Fail] Expected status code to NOT equal {d}, got {d}\n", .{ assert_status_code, @intFromEnum(response.status.?) }) catch {};
                        return error.StatusCodesMatchButShouldnt;
                    }
                } else if (std.ascii.eqlIgnoreCase(assertion.key, "body")) {
                    if (std.mem.eql(u8, response.body, assertion.value)) {
                        stderr.print("[Fail] Expected body content to NOT equal \"{s}\", got \"{s}\"\n", .{ assertion.value, response.body }) catch {};
                        return error.BodyContentMatchesButShouldnt;
                    }
                } else if (std.mem.startsWith(u8, assertion.key, "header[\"")) {
                    // Extract the header name from the assertion key
                    const header_name = assertion.key[8 .. assertion.key.len - 2];
                    const actual_value = response.headers.get(header_name);
                    if (actual_value != null and std.ascii.eqlIgnoreCase(actual_value.?, assertion.value)) {
                        stderr.print("[Fail] Expected header \"{s}\" to NOT equal \"{s}\", got \"{s}\"\n", .{ header_name, assertion.value, actual_value orelse "null" }) catch {};
                        return error.HeaderMatchesButShouldnt;
                    }
                } else {
                    stderr.print("[Fail] Invalid assertion key: {s}\n", .{assertion.key}) catch {};
                    return error.InvalidAssertionKey;
                }
            },

            // .header => {
            //     // assertion.key is header[""] so we need to
            //     // parse it out of the quotes
            //     const tokens = std.mem.splitScalar(u8, assertion.key, '\"');
            //     const expected_header = tokens.next() orelse return error.InvalidHeaderFormat;
            //     if (expected_header.len != 2) {
            //         return error.InvalidHeaderFormat;
            //     }
            //     const actual_value = response.headers.get(expected_header);
            //     if (actual_value == null or actual_value.* != expected_header.value) {
            //         return error.HeaderMismatch;
            //     }
            // },
            .contains => {
                if (std.ascii.eqlIgnoreCase(assertion.key, "status")) {
                    var status_buf: [3]u8 = undefined;
                    const status_code = @intFromEnum(response.status.?); // .? if status is optional
                    const status_str = std.fmt.bufPrint(&status_buf, "{}", .{status_code}) catch return error.StatusCodeFormat;
                    if (std.mem.indexOf(u8, status_str, assertion.value) == null) {
                        stderr.print("[Fail] Expected status code to contain \"{s}\", got \"{s}\"\n", .{ assertion.value, status_str }) catch {};
                        return error.StatusCodeNotContains;
                    }
                } else if (std.ascii.eqlIgnoreCase(assertion.key, "body")) {
                    if (std.mem.indexOf(u8, response.body, assertion.value) == null) {
                        stderr.print("[Fail] Expected body content to contain \"{s}\", got \"{s}\"\n", .{ assertion.value, response.body }) catch {};
                        return error.BodyContentNotContains;
                    }
                } else if (std.mem.startsWith(u8, assertion.key, "header[\"")) {
                    // Extract the header name from the assertion key
                    const header_name = assertion.key[8 .. assertion.key.len - 2];
                    const actual_value = response.headers.get(header_name);
                    if (actual_value == null or std.mem.indexOf(u8, actual_value.?, assertion.value) == null) {
                        stderr.print("[Fail] Expected header \"{s}\" to contain \"{s}\", got \"{s}\"\n", .{ header_name, assertion.value, actual_value orelse "null" }) catch {};
                        return error.HeaderNotContains;
                    }
                } else {
                    stderr.print("[Fail] Invalid assertion key for contains: {s}\n", .{assertion.key}) catch {};
                    return error.InvalidAssertionKey;
                }
            },
            .not_contains => {
                if (std.ascii.eqlIgnoreCase(assertion.key, "status")) {
                    var status_buf: [3]u8 = undefined;
                    const status_code = @intFromEnum(response.status.?); // .? if status is optional
                    const status_str = std.fmt.bufPrint(&status_buf, "{}", .{status_code}) catch return error.StatusCodeFormat;
                    if (std.mem.indexOf(u8, status_str, assertion.value) != null) {
                        stderr.print("[Fail] Expected status code to NOT contain \"{s}\", got \"{s}\"\n", .{ assertion.value, status_str }) catch {};
                        return error.StatusCodeContainsButShouldnt;
                    }
                } else if (std.ascii.eqlIgnoreCase(assertion.key, "body")) {
                    if (std.mem.indexOf(u8, response.body, assertion.value) != null) {
                        stderr.print("[Fail] Expected body content to NOT contain \"{s}\", got \"{s}\"\n", .{ assertion.value, response.body }) catch {};
                        return error.BodyContentContainsButShouldnt;
                    }
                } else if (std.mem.startsWith(u8, assertion.key, "header[\"")) {
                    // Extract the header name from the assertion key
                    const header_name = assertion.key[8 .. assertion.key.len - 2];
                    const actual_value = response.headers.get(header_name);
                    if (actual_value != null and std.mem.indexOf(u8, actual_value.?, assertion.value) != null) {
                        stderr.print("[Fail] Expected header \"{s}\" to NOT contain \"{s}\", got \"{s}\"\n", .{ header_name, assertion.value, actual_value orelse "null" }) catch {};
                        return error.HeaderContainsButShouldnt;
                    }
                } else {
                    stderr.print("[Fail] Invalid assertion key for contains: {s}\n", .{assertion.key}) catch {};
                    return error.InvalidAssertionKey;
                }
            },
            else => {},
        }
    }
}

test "HttpParser parses assertions" {
    const allocator = std.testing.allocator;

    var assertions = std.ArrayList(HttpParser.Assertion).init(allocator);
    defer assertions.deinit();

    try assertions.append(HttpParser.Assertion{
        .key = "status",
        .value = "200",
        .assertion_type = .starts_with,
    });

    try assertions.append(HttpParser.Assertion{
        .key = "body",
        .value = "body content",
        .assertion_type = .contains,
    });

    try assertions.append(HttpParser.Assertion{
        .key = "body",
        .value = "Response body content",
        .assertion_type = .equal,
    });

    // TODO: This should also work with header[\"Content-Type\"] as the key
    try assertions.append(HttpParser.Assertion{
        .key = "header[\"content-type\"]",
        .value = "application/json",
        .assertion_type = .equal,
    });

    var request = HttpParser.HttpRequest{
        .method = .GET,
        .url = "https://api.example.com",
        .headers = std.ArrayList(http.Header).init(allocator),
        .assertions = assertions,
        .body = null,
    };

    var response_headers = std.StringHashMap([]const u8).init(allocator);
    try response_headers.put("content-type", "application/json");
    defer response_headers.deinit();

    const body = try allocator.dupe(u8, "Response body content");
    defer allocator.free(body);
    const response = Client.HttpResponse{
        .status = http.Status.ok,
        .headers = response_headers,
        .body = body,
        .allocator = allocator,
    };

    try check(&request, response);
}

test "HttpParser handles NotEquals" {
    const allocator = std.testing.allocator;

    var assertions = std.ArrayList(HttpParser.Assertion).init(allocator);
    defer assertions.deinit();

    try assertions.append(HttpParser.Assertion{
        .key = "status",
        .value = "400",
        .assertion_type = .not_equal,
    });

    try assertions.append(HttpParser.Assertion{
        .key = "body",
        .value = "Response body content!!!",
        .assertion_type = .not_equal,
    });

    // TODO: This should also work with header[\"Content-Type\"] as the key
    try assertions.append(HttpParser.Assertion{
        .key = "header[\"content-type\"]",
        .value = "application/xml",
        .assertion_type = .not_equal,
    });

    var request = HttpParser.HttpRequest{
        .method = .GET,
        .url = "https://api.example.com",
        .headers = std.ArrayList(http.Header).init(allocator),
        .assertions = assertions,
        .body = null,
    };

    var response_headers = std.StringHashMap([]const u8).init(allocator);
    try response_headers.put("content-type", "application/json");
    defer response_headers.deinit();

    const body = try allocator.dupe(u8, "Response body content");
    defer allocator.free(body);
    const response = Client.HttpResponse{
        .status = http.Status.ok,
        .headers = response_headers,
        .body = body,
        .allocator = allocator,
    };

    try check(&request, response);
}
