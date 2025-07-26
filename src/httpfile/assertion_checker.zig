const std = @import("std");
const http = std.http;
const regex = @import("regex");
const HttpParser = @import("./parser.zig");
const Client = @import("./http_client.zig");

fn extractHeaderName(key: []const u8) ![]const u8 {
    // Expects key in the form header["..."]
    const start_quote = std.mem.indexOfScalar(u8, key, '"') orelse return error.InvalidAssertionKey;
    const end_quote = std.mem.lastIndexOfScalar(u8, key, '"') orelse return error.InvalidAssertionKey;
    if (end_quote <= start_quote) return error.InvalidAssertionKey;
    return key[start_quote + 1 .. end_quote];
}

fn matchesRegex(text: []const u8, pattern: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const compiled_regex = regex.Regex.compile(allocator, pattern) catch return false;
    defer compiled_regex.deinit();

    return compiled_regex.match(text);
}

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
                    const header_name = try extractHeaderName(assertion.key);
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
                    const header_name = try extractHeaderName(assertion.key);
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
                    const header_name = try extractHeaderName(assertion.key);
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
                    const header_name = try extractHeaderName(assertion.key);
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
            .starts_with => {
                if (std.ascii.eqlIgnoreCase(assertion.key, "status")) {
                    var status_buf: [3]u8 = undefined;
                    const status_code = @intFromEnum(response.status.?);
                    const status_str = std.fmt.bufPrint(&status_buf, "{}", .{status_code}) catch return error.StatusCodeFormat;
                    if (!std.mem.startsWith(u8, status_str, assertion.value)) {
                        stderr.print("[Fail] Expected status code to start with \"{s}\", got \"{s}\"\n", .{ assertion.value, status_str }) catch {};
                        return error.StatusCodeNotStartsWith;
                    }
                } else if (std.ascii.eqlIgnoreCase(assertion.key, "body")) {
                    if (!std.mem.startsWith(u8, response.body, assertion.value)) {
                        stderr.print("[Fail] Expected body content to start with \"{s}\", got \"{s}\"\n", .{ assertion.value, response.body }) catch {};
                        return error.BodyContentNotStartsWith;
                    }
                } else if (std.mem.startsWith(u8, assertion.key, "header[\"")) {
                    const header_name = try extractHeaderName(assertion.key);
                    const actual_value = response.headers.get(header_name);
                    if (actual_value == null or !std.mem.startsWith(u8, actual_value.?, assertion.value)) {
                        stderr.print("[Fail] Expected header \"{s}\" to start with \"{s}\", got \"{s}\"\n", .{ header_name, assertion.value, actual_value orelse "null" }) catch {};
                        return error.HeaderNotStartsWith;
                    }
                } else {
                    stderr.print("[Fail] Invalid assertion key for starts_with: {s}\n", .{assertion.key}) catch {};
                    return error.InvalidAssertionKey;
                }
            },
            .matches_regex => {
                if (std.ascii.eqlIgnoreCase(assertion.key, "status")) {
                    var status_buf: [3]u8 = undefined;
                    const status_code = @intFromEnum(response.status.?);
                    const status_str = std.fmt.bufPrint(&status_buf, "{}", .{status_code}) catch return error.StatusCodeFormat;
                    if (!matchesRegex(status_str, assertion.value)) {
                        stderr.print("[Fail] Expected status code to match regex \"{s}\", got \"{s}\"\n", .{ assertion.value, status_str }) catch {};
                        return error.StatusCodeNotMatchesRegex;
                    }
                } else if (std.ascii.eqlIgnoreCase(assertion.key, "body")) {
                    if (!matchesRegex(response.body, assertion.value)) {
                        stderr.print("[Fail] Expected body content to match regex \"{s}\", got \"{s}\"\n", .{ assertion.value, response.body }) catch {};
                        return error.BodyContentNotMatchesRegex;
                    }
                } else if (std.mem.startsWith(u8, assertion.key, "header[\"")) {
                    const header_name = try extractHeaderName(assertion.key);
                    const actual_value = response.headers.get(header_name);
                    if (actual_value == null or !matchesRegex(actual_value.?, assertion.value)) {
                        stderr.print("[Fail] Expected header \"{s}\" to match regex \"{s}\", got \"{s}\"\n", .{ header_name, assertion.value, actual_value orelse "null" }) catch {};
                        return error.HeaderNotMatchesRegex;
                    }
                } else {
                    stderr.print("[Fail] Invalid assertion key for matches_regex: {s}\n", .{assertion.key}) catch {};
                    return error.InvalidAssertionKey;
                }
            },
            .not_matches_regex => {
                if (std.ascii.eqlIgnoreCase(assertion.key, "status")) {
                    var status_buf: [3]u8 = undefined;
                    const status_code = @intFromEnum(response.status.?);
                    const status_str = std.fmt.bufPrint(&status_buf, "{}", .{status_code}) catch return error.StatusCodeFormat;
                    if (matchesRegex(status_str, assertion.value)) {
                        stderr.print("[Fail] Expected status code to NOT match regex \"{s}\", got \"{s}\"\n", .{ assertion.value, status_str }) catch {};
                        return error.StatusCodeMatchesRegexButShouldnt;
                    }
                } else if (std.ascii.eqlIgnoreCase(assertion.key, "body")) {
                    if (matchesRegex(response.body, assertion.value)) {
                        stderr.print("[Fail] Expected body content to NOT match regex \"{s}\", got \"{s}\"\n", .{ assertion.value, response.body }) catch {};
                        return error.BodyContentMatchesRegexButShouldnt;
                    }
                } else if (std.mem.startsWith(u8, assertion.key, "header[\"")) {
                    const header_name = try extractHeaderName(assertion.key);
                    const actual_value = response.headers.get(header_name);
                    if (actual_value != null and matchesRegex(actual_value.?, assertion.value)) {
                        stderr.print("[Fail] Expected header \"{s}\" to NOT match regex \"{s}\", got \"{s}\"\n", .{ header_name, assertion.value, actual_value orelse "null" }) catch {};
                        return error.HeaderMatchesRegexButShouldnt;
                    }
                } else {
                    stderr.print("[Fail] Invalid assertion key for not_matches_regex: {s}\n", .{assertion.key}) catch {};
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

test "HttpParser supports starts_with for status, body, and header" {
    const allocator = std.testing.allocator;
    var assertions = std.ArrayList(HttpParser.Assertion).init(allocator);
    defer assertions.deinit();

    // Status starts with "2"
    try assertions.append(HttpParser.Assertion{
        .key = "status",
        .value = "2",
        .assertion_type = .starts_with,
    });
    // Body starts with "Hello"
    try assertions.append(HttpParser.Assertion{
        .key = "body",
        .value = "Hello",
        .assertion_type = .starts_with,
    });
    // Header starts with "application"
    try assertions.append(HttpParser.Assertion{
        .key = "header[\"content-type\"]",
        .value = "application",
        .assertion_type = .starts_with,
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

    const body = try allocator.dupe(u8, "Hello world!");
    defer allocator.free(body);
    const response = Client.HttpResponse{
        .status = http.Status.ok,
        .headers = response_headers,
        .body = body,
        .allocator = allocator,
    };

    try check(&request, response);
}

test "HttpParser supports matches_regex and not_matches_regex for status, body, and headers" {
    const allocator = std.testing.allocator;

    var assertions = std.ArrayList(HttpParser.Assertion).init(allocator);
    defer assertions.deinit();

    // Should pass: status matches regex for 2xx codes
    try assertions.append(HttpParser.Assertion{
        .key = "status",
        .value = "^2.*",
        .assertion_type = .matches_regex,
    });

    // Should pass: body matches regex for JSON-like content
    try assertions.append(HttpParser.Assertion{
        .key = "body",
        .value = ".*success.*",
        .assertion_type = .matches_regex,
    });

    // Should pass: header matches regex for application/* content types
    try assertions.append(HttpParser.Assertion{
        .key = "header[\"content-type\"]",
        .value = "application/.*",
        .assertion_type = .matches_regex,
    });

    // Should pass: status does not match regex for error codes
    try assertions.append(HttpParser.Assertion{
        .key = "status",
        .value = "^[45].*",
        .assertion_type = .not_matches_regex,
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

    const body = try allocator.dupe(u8, "Operation success completed");
    defer allocator.free(body);
    const response = Client.HttpResponse{
        .status = http.Status.ok,
        .headers = response_headers,
        .body = body,
        .allocator = allocator,
    };

    try check(&request, response);
}

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
