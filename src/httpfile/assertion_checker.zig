const std = @import("std");
const http = std.http;
const regex = @import("regex");
const HttpParser = @import("./parser.zig");
const Client = @import("./http_client.zig");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

pub const FailureReason = enum {
    status_mismatch,
    header_mismatch,
    header_missing,
    body_mismatch,
    contains_failed,
    not_contains_failed,
    invalid_assertion_key,
    status_format_error,
};

// Represents a test failure due to assertion checking.
// This struct needs to own its own memory. We should adapt it to use a .init pattern
// to make that more obvious.
pub const AssertionFailure = struct {
    assertion_key: []const u8,
    assertion_value: []const u8,
    assertion_type: HttpParser.AssertionType,
    expected: []const u8,
    actual: []const u8,
    reason: FailureReason,
    source_file: ?[]const u8 = null,
    test_name: ?[]const u8 = null,
    assertion_index: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        assertion: HttpParser.Assertion,
        expected: []const u8,
        actual: []const u8,
        reason: FailureReason,
        source_file: ?[]const u8,
        test_name: ?[]const u8,
        assertion_index: usize,
    ) !AssertionFailure {
        return AssertionFailure{
            .assertion_key = try allocator.dupe(u8, assertion.key),
            .assertion_value = try allocator.dupe(u8, assertion.value),
            .assertion_type = assertion.assertion_type,
            .expected = try allocator.dupe(u8, expected),
            .actual = try allocator.dupe(u8, actual),
            .reason = reason,
            .assertion_index = assertion_index,
            .source_file = if (source_file) |file| try allocator.dupe(u8, file) else null,
            .test_name = if (test_name) |name| try allocator.dupe(u8, name) else null,
        };
    }

    pub fn deinit(self: *AssertionFailure, allocator: Allocator) void {
        allocator.free(self.assertion_key);
        allocator.free(self.assertion_value);
        allocator.free(self.expected);
        allocator.free(self.actual);
        if (self.source_file) |file| {
            allocator.free(file);
        }
        if (self.test_name) |name| {
            allocator.free(name);
        }
    }
};

pub const AssertionDiagnostic = struct {
    failures: ArrayList(AssertionFailure),
    allocator: Allocator,

    pub fn init(allocator: Allocator) AssertionDiagnostic {
        return .{
            .failures = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AssertionDiagnostic) void {
        for (self.failures.items) |*failure| {
            failure.deinit(self.allocator);
        }
        self.failures.deinit(self.allocator);
    }

    pub fn addFailure(
        self: *AssertionDiagnostic,
        assertion: HttpParser.Assertion,
        expected: []const u8,
        actual: []const u8,
        reason: FailureReason,
        assertion_index: usize,
        source_file: ?[]const u8,
        test_name: ?[]const u8,
    ) !void {
        const failure = AssertionFailure.init(
            self.allocator,
            assertion,
            expected,
            actual,
            reason,
            source_file,
            test_name,
            assertion_index,
        ) catch {
            return error.UnableToAllocateAssertionFailure;
        };
        try self.failures.append(self.allocator, failure);
    }
};

pub fn hasFailures(diagnostic: *const AssertionDiagnostic) bool {
    return diagnostic.failures.items.len > 0;
}

pub fn reportFailures(diagnostic: *const AssertionDiagnostic, writer: anytype) !void {
    for (diagnostic.failures.items) |failure| {
        const source_info = if (failure.source_file) |file|
            try std.fmt.allocPrint(diagnostic.allocator, " in {s}:{d}", .{ file, failure.assertion_index + 1 })
        else
            try std.fmt.allocPrint(diagnostic.allocator, " (assertion #{d})", .{failure.assertion_index + 1});
        defer diagnostic.allocator.free(source_info);

        switch (failure.reason) {
            .status_mismatch => try writer.print("[Fail]{s} Expected status {s}, got {s}\n", .{ source_info, failure.expected, failure.actual }),
            .header_mismatch => try writer.print("[Fail]{s} Expected header \"{s}\" to be \"{s}\", got \"{s}\"\n", .{ source_info, failure.assertion_key[8 .. failure.assertion_key.len - 2], failure.expected, failure.actual }),
            .header_missing => try writer.print("[Fail]{s} Expected header \"{s}\" to be \"{s}\", but header was missing\n", .{ source_info, failure.assertion_key[8 .. failure.assertion_key.len - 2], failure.expected }),
            .body_mismatch => try writer.print("[Fail]{s} Expected body \"{s}\", got \"{s}\"\n", .{ source_info, failure.expected, failure.actual }),
            .contains_failed => try writer.print("[Fail]{s} Expected {s} to contain \"{s}\", got \"{s}\"\n", .{ source_info, failure.assertion_key, failure.expected, failure.actual }),
            .not_contains_failed => try writer.print("[Fail]{s} Expected {s} to NOT contain \"{s}\", got \"{s}\"\n", .{ source_info, failure.assertion_key, failure.expected, failure.actual }),
            .invalid_assertion_key => try writer.print("[Fail]{s} Invalid assertion key: \"{s}\"\n", .{ source_info, failure.assertion_key }),
            .status_format_error => try writer.print("[Fail]{s} Status format error for assertion \"{s}\"\n", .{ source_info, failure.assertion_key }),
        }
    }
}

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
    var compiled_regex = regex.Regex.compile(allocator, pattern) catch return false;
    defer compiled_regex.deinit();

    return compiled_regex.match(text) catch return false;
}

pub fn check(
    request: *HttpParser.HttpRequest,
    response: Client.HttpResponse,
    diagnostic: *AssertionDiagnostic,
    source_file: ?[]const u8,
) void {
    for (request.assertions.items, 0..) |assertion, index| {
        checkAssertion(assertion, request, response, diagnostic, index, source_file) catch |err| {
            diagnostic.addFailure(
                assertion,
                "N/A",
                @errorName(err),
                .status_format_error,
                index,
                source_file,
                request.name,
            ) catch {};
        };
    }
}

fn checkAssertion(
    assertion: HttpParser.Assertion,
    request: *HttpParser.HttpRequest,
    response: Client.HttpResponse,
    diagnostic: *AssertionDiagnostic,
    assertion_index: usize,
    source_file: ?[]const u8,
) !void {
    switch (assertion.assertion_type) {
        .equal => {
            if (std.ascii.eqlIgnoreCase(assertion.key, "status")) {
                const assert_status_code = try std.fmt.parseInt(u16, assertion.value, 10);
                const expected_status = try std.meta.intToEnum(http.Status, assert_status_code);
                if (response.status != expected_status) {
                    const actual_str = try std.fmt.allocPrint(diagnostic.allocator, "{d}", .{@intFromEnum(response.status.?)});
                    defer diagnostic.allocator.free(actual_str);
                    try diagnostic.addFailure(assertion, assertion.value, actual_str, .status_mismatch, assertion_index, source_file, request.name);
                }
            } else if (std.ascii.eqlIgnoreCase(assertion.key, "body")) {
                if (!std.mem.eql(u8, response.body, assertion.value)) {
                    try diagnostic.addFailure(assertion, assertion.value, response.body, .body_mismatch, assertion_index, source_file, request.name);
                }
            } else if (std.mem.startsWith(u8, assertion.key, "header[\"")) {
                const header_name = assertion.key[8 .. assertion.key.len - 2];
                const actual_value = response.headers.get(header_name);
                if (actual_value == null) {
                    try diagnostic.addFailure(assertion, assertion.value, "null", .header_missing, assertion_index, source_file, request.name);
                } else if (!std.ascii.eqlIgnoreCase(actual_value.?, assertion.value)) {
                    try diagnostic.addFailure(assertion, assertion.value, actual_value.?, .header_mismatch, assertion_index, source_file, request.name);
                }
            } else {
                try diagnostic.addFailure(assertion, assertion.value, "N/A", .invalid_assertion_key, assertion_index, source_file, request.name);
            }
        },
        .not_equal => {
            if (std.ascii.eqlIgnoreCase(assertion.key, "status")) {
                const assert_status_code = try std.fmt.parseInt(u16, assertion.value, 10);
                const expected_status = try std.meta.intToEnum(http.Status, assert_status_code);
                if (response.status == expected_status) {
                    const actual_str = try std.fmt.allocPrint(diagnostic.allocator, "{d}", .{@intFromEnum(response.status.?)});
                    defer diagnostic.allocator.free(actual_str);
                    try diagnostic.addFailure(assertion, assertion.value, actual_str, .status_mismatch, assertion_index, source_file, request.name);
                }
            } else if (std.ascii.eqlIgnoreCase(assertion.key, "body")) {
                if (std.mem.eql(u8, response.body, assertion.value)) {
                    try diagnostic.addFailure(assertion, assertion.value, response.body, .body_mismatch, assertion_index, source_file, request.name);
                }
            } else if (std.mem.startsWith(u8, assertion.key, "header[\"")) {
                const header_name = assertion.key[8 .. assertion.key.len - 2];
                const actual_value = response.headers.get(header_name);
                if (actual_value != null and std.ascii.eqlIgnoreCase(actual_value.?, assertion.value)) {
                    try diagnostic.addFailure(assertion, assertion.value, actual_value.?, .header_mismatch, assertion_index, source_file, request.name);
                }
            } else {
                try diagnostic.addFailure(assertion, assertion.value, "N/A", .invalid_assertion_key, assertion_index, source_file, request.name);
            }
        },
        .contains => {
            if (std.ascii.eqlIgnoreCase(assertion.key, "status")) {
                var status_buf: [3]u8 = undefined;
                const status_code = @intFromEnum(response.status.?);
                const status_str = try std.fmt.bufPrint(&status_buf, "{}", .{status_code});
                if (std.mem.indexOf(u8, status_str, assertion.value) == null) {
                    try diagnostic.addFailure(assertion, assertion.value, status_str, .contains_failed, assertion_index, source_file, request.name);
                }
            } else if (std.ascii.eqlIgnoreCase(assertion.key, "body")) {
                if (std.mem.indexOf(u8, response.body, assertion.value) == null) {
                    try diagnostic.addFailure(assertion, assertion.value, response.body, .contains_failed, assertion_index, source_file, request.name);
                }
            } else if (std.mem.startsWith(u8, assertion.key, "header[\"")) {
                const header_name = assertion.key[8 .. assertion.key.len - 2];
                const actual_value = response.headers.get(header_name);
                if (actual_value == null or std.mem.indexOf(u8, actual_value.?, assertion.value) == null) {
                    try diagnostic.addFailure(assertion, assertion.value, actual_value orelse "null", .contains_failed, assertion_index, source_file, request.name);
                }
            } else {
                try diagnostic.addFailure(assertion, assertion.value, "N/A", .invalid_assertion_key, assertion_index, source_file, request.name);
            }
        },
        .not_contains => {
            if (std.ascii.eqlIgnoreCase(assertion.key, "status")) {
                var status_buf: [3]u8 = undefined;
                const status_code = @intFromEnum(response.status.?);
                const status_str = try std.fmt.bufPrint(&status_buf, "{}", .{status_code});
                if (std.mem.indexOf(u8, status_str, assertion.value) != null) {
                    try diagnostic.addFailure(assertion, assertion.value, status_str, .not_contains_failed, assertion_index, source_file, request.name);
                }
            } else if (std.ascii.eqlIgnoreCase(assertion.key, "body")) {
                if (std.mem.indexOf(u8, response.body, assertion.value) != null) {
                    try diagnostic.addFailure(assertion, assertion.value, response.body, .not_contains_failed, assertion_index, source_file, request.name);
                }
            } else if (std.mem.startsWith(u8, assertion.key, "header[\"")) {
                const header_name = assertion.key[8 .. assertion.key.len - 2];
                const actual_value = response.headers.get(header_name);
                if (actual_value != null and std.mem.indexOf(u8, actual_value.?, assertion.value) != null) {
                    try diagnostic.addFailure(assertion, assertion.value, actual_value.?, .not_contains_failed, assertion_index, source_file, request.name);
                }
            } else {
                try diagnostic.addFailure(assertion, assertion.value, "N/A", .invalid_assertion_key, assertion_index, source_file, request.name);
            }
        },
        .matches_regex => {
            if (std.ascii.eqlIgnoreCase(assertion.key, "status")) {
                var status_buf: [3]u8 = undefined;
                const status_code = @intFromEnum(response.status.?);
                const status_str = try std.fmt.bufPrint(&status_buf, "{}", .{status_code});
                if (!matchesRegex(status_str, assertion.value)) {
                    try diagnostic.addFailure(assertion, assertion.value, status_str, .contains_failed, assertion_index, source_file, request.name);
                }
            } else if (std.ascii.eqlIgnoreCase(assertion.key, "body")) {
                if (!matchesRegex(response.body, assertion.value)) {
                    try diagnostic.addFailure(assertion, assertion.value, response.body, .contains_failed, assertion_index, source_file, request.name);
                }
            } else if (std.mem.startsWith(u8, assertion.key, "header[\"")) {
                const header_name = assertion.key[8 .. assertion.key.len - 2];
                const actual_value = response.headers.get(header_name);
                if (actual_value == null or !matchesRegex(actual_value.?, assertion.value)) {
                    try diagnostic.addFailure(assertion, assertion.value, actual_value orelse "null", .contains_failed, assertion_index, source_file, request.name);
                }
            } else {
                try diagnostic.addFailure(assertion, assertion.value, "N/A", .invalid_assertion_key, assertion_index, source_file, request.name);
            }
        },
        .not_matches_regex => {
            if (std.ascii.eqlIgnoreCase(assertion.key, "status")) {
                var status_buf: [3]u8 = undefined;
                const status_code = @intFromEnum(response.status.?);
                const status_str = try std.fmt.bufPrint(&status_buf, "{}", .{status_code});
                if (matchesRegex(status_str, assertion.value)) {
                    try diagnostic.addFailure(assertion, assertion.value, status_str, .not_contains_failed, assertion_index, source_file, request.name);
                }
            } else if (std.ascii.eqlIgnoreCase(assertion.key, "body")) {
                if (matchesRegex(response.body, assertion.value)) {
                    try diagnostic.addFailure(assertion, assertion.value, response.body, .not_contains_failed, assertion_index, source_file, request.name);
                }
            } else if (std.mem.startsWith(u8, assertion.key, "header[\"")) {
                const header_name = assertion.key[8 .. assertion.key.len - 2];
                const actual_value = response.headers.get(header_name);
                if (actual_value != null and matchesRegex(actual_value.?, assertion.value)) {
                    try diagnostic.addFailure(assertion, assertion.value, actual_value.?, .not_contains_failed, assertion_index, source_file, request.name);
                }
            } else {
                try diagnostic.addFailure(assertion, assertion.value, "N/A", .invalid_assertion_key, assertion_index, source_file, request.name);
            }
        },
        else => {},
    }
}

test "Assertion checker with diagnostics - all pass" {
    const allocator = std.testing.allocator;

    var assertions: std.ArrayList(HttpParser.Assertion) = .empty;
    defer assertions.deinit(allocator);

    try assertions.append(allocator, HttpParser.Assertion{
        .key = "status",
        .value = "200",
        .assertion_type = .equal,
    });

    try assertions.append(allocator, HttpParser.Assertion{
        .key = "body",
        .value = "body content",
        .assertion_type = .contains,
    });

    try assertions.append(allocator, HttpParser.Assertion{
        .key = "body",
        .value = "Response body content",
        .assertion_type = .equal,
    });

    try assertions.append(allocator, HttpParser.Assertion{
        .key = "header[\"content-type\"]",
        .value = "application/json",
        .assertion_type = .equal,
    });

    var request = HttpParser.HttpRequest{
        .method = .GET,
        .url = "https://api.example.com",
        .name = "test name",
        .headers = .empty,
        .assertions = assertions,
        .body = null,
        .version = .@"HTTP/1.1",
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

    var diagnostic = AssertionDiagnostic.init(allocator);
    defer diagnostic.deinit();

    check(&request, response, &diagnostic, "test.httpspec");

    try std.testing.expect(!hasFailures(&diagnostic));
    try std.testing.expectEqual(@as(usize, 0), diagnostic.failures.items.len);
}

test "Assertion checker with not_equal - all pass" {
    const allocator = std.testing.allocator;

    var assertions: std.ArrayList(HttpParser.Assertion) = .empty;
    defer assertions.deinit(allocator);

    try assertions.append(allocator, HttpParser.Assertion{
        .key = "status",
        .value = "400",
        .assertion_type = .not_equal,
    });

    try assertions.append(allocator, HttpParser.Assertion{
        .key = "body",
        .value = "Response body content!!!",
        .assertion_type = .not_equal,
    });

    try assertions.append(allocator, HttpParser.Assertion{
        .key = "header[\"content-type\"]",
        .value = "application/xml",
        .assertion_type = .not_equal,
    });

    var request = HttpParser.HttpRequest{
        .method = .GET,
        .url = "https://api.example.com",
        .headers = .empty,
        .assertions = assertions,
        .body = null,
        .name = "test name",
        .version = .@"HTTP/1.1",
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

    var diagnostic = AssertionDiagnostic.init(allocator);
    defer diagnostic.deinit();

    check(&request, response, &diagnostic, "test.httpspec");

    try std.testing.expect(!hasFailures(&diagnostic));
    try std.testing.expectEqual(@as(usize, 0), diagnostic.failures.items.len);
}

test "Assertion checker with failures - collects all failures" {
    const allocator = std.testing.allocator;

    var assertions: std.ArrayList(HttpParser.Assertion) = .empty;
    defer assertions.deinit(allocator);

    try assertions.append(allocator, HttpParser.Assertion{
        .key = "status",
        .value = "404",
        .assertion_type = .equal,
    });

    try assertions.append(allocator, HttpParser.Assertion{
        .key = "body",
        .value = "Wrong body content",
        .assertion_type = .equal,
    });

    try assertions.append(allocator, HttpParser.Assertion{
        .key = "header[\"content-type\"]",
        .value = "application/xml",
        .assertion_type = .equal,
    });

    var request = HttpParser.HttpRequest{
        .method = .GET,
        .url = "https://api.example.com",
        .headers = .empty,
        .assertions = assertions,
        .body = null,
        .name = "test name",
        .version = .@"HTTP/1.1",
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

    var diagnostic = AssertionDiagnostic.init(allocator);
    defer diagnostic.deinit();

    check(&request, response, &diagnostic, "test.httpspec");

    try std.testing.expect(hasFailures(&diagnostic));
    try std.testing.expectEqual(@as(usize, 3), diagnostic.failures.items.len);

    try std.testing.expectEqual(FailureReason.status_mismatch, diagnostic.failures.items[0].reason);
    try std.testing.expectEqual(FailureReason.body_mismatch, diagnostic.failures.items[1].reason);
    try std.testing.expectEqual(FailureReason.header_mismatch, diagnostic.failures.items[2].reason);
}

test "HttpParser supports starts_with for status, body, and header" {
    const allocator = std.testing.allocator;
    var assertions: std.ArrayList(HttpParser.Assertion) = .empty;
    defer assertions.deinit(allocator);

    // Status starts with "2"
    try assertions.append(allocator, HttpParser.Assertion{
        .key = "status",
        .value = "2",
        .assertion_type = .starts_with,
    });
    // Body starts with "Hello"
    try assertions.append(allocator, HttpParser.Assertion{
        .key = "body",
        .value = "Hello",
        .assertion_type = .starts_with,
    });
    // Header starts with "application"
    try assertions.append(allocator, HttpParser.Assertion{
        .key = "header[\"content-type\"]",
        .value = "application",
        .assertion_type = .starts_with,
    });

    var request = HttpParser.HttpRequest{
        .method = .GET,
        .url = "https://api.example.com",
        .headers = .empty,
        .assertions = assertions,
        .name = "test name",
        .body = null,
        .version = .@"HTTP/1.1",
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

    var diagnostic = AssertionDiagnostic.init(allocator);
    defer diagnostic.deinit();

    check(&request, response, &diagnostic, "test.httpspec");

    try std.testing.expect(!hasFailures(&diagnostic));
}

test "HttpParser supports matches_regex and not_matches_regex for status, body, and headers" {
    const allocator = std.testing.allocator;

    var assertions: std.ArrayList(HttpParser.Assertion) = .empty;
    defer assertions.deinit(allocator);

    // Should pass: status matches regex for 2xx codes
    try assertions.append(allocator, HttpParser.Assertion{
        .key = "status",
        .value = "^2.*",
        .assertion_type = .matches_regex,
    });

    // Should pass: body matches regex for JSON-like content
    try assertions.append(allocator, HttpParser.Assertion{
        .key = "body",
        .value = ".*success.*",
        .assertion_type = .matches_regex,
    });

    // Should pass: header matches regex for application/* content types
    try assertions.append(allocator, HttpParser.Assertion{
        .key = "header[\"content-type\"]",
        .value = "application/.*",
        .assertion_type = .matches_regex,
    });

    // Should pass: status does not match regex for error codes
    try assertions.append(allocator, HttpParser.Assertion{
        .key = "status",
        .value = "^[45].*",
        .assertion_type = .not_matches_regex,
    });

    var request = HttpParser.HttpRequest{
        .method = .GET,
        .url = "https://api.example.com",
        .headers = .empty,
        .assertions = assertions,
        .body = null,
        .name = "TEST NAME",
        .version = .@"HTTP/1.1",
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

    var diagnostic = AssertionDiagnostic.init(allocator);
    defer diagnostic.deinit();

    check(&request, response, &diagnostic, "test.httpspec");

    try std.testing.expect(!hasFailures(&diagnostic));
}

test "HttpParser supports contains and not_contains for headers" {
    const allocator = std.testing.allocator;

    var assertions: std.ArrayList(HttpParser.Assertion) = .empty;
    defer assertions.deinit(allocator);

    // Should pass: header contains "json"
    try assertions.append(allocator, HttpParser.Assertion{
        .key = "header[\"content-type\"]",
        .value = "json",
        .assertion_type = .contains,
    });

    // Should pass: header does not contain "xml"
    try assertions.append(allocator, HttpParser.Assertion{
        .key = "header[\"content-type\"]",
        .value = "xml",
        .assertion_type = .not_contains,
    });

    var request = HttpParser.HttpRequest{
        .method = .GET,
        .url = "https://api.example.com",
        .headers = .empty,
        .assertions = assertions,
        .body = null,
        .name = "test name",
        .version = .@"HTTP/1.1",
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

    var diagnostic = AssertionDiagnostic.init(allocator);
    defer diagnostic.deinit();

    check(&request, response, &diagnostic, "test.httpspec");

    try std.testing.expect(!hasFailures(&diagnostic));
}
