const std = @import("std");
const http = std.http;

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const ParserState = enum { headers, body };

const AssertionType = enum {
    equal,
    not_equal,
    contains,
    not_contains,
    starts_with,
    ends_with,
    // matches_regex, TODO: Soon.
    // not_matches_regex,

    pub fn fromString(s: []const u8) ?AssertionType {
        if (std.ascii.eqlIgnoreCase(s, "==")) return .equal;
        if (std.ascii.eqlIgnoreCase(s, "equal")) return .equal;
        if (std.ascii.eqlIgnoreCase(s, "!=")) return .not_equal;
        if (std.ascii.eqlIgnoreCase(s, "contains")) return .contains;
        if (std.ascii.eqlIgnoreCase(s, "not_contains")) return .not_contains;
        if (std.ascii.eqlIgnoreCase(s, "starts_with")) return .starts_with;
        if (std.ascii.eqlIgnoreCase(s, "ends_with")) return .ends_with;
        // if (std.ascii.eqlIgnoreCase(s, "matches_regex")) return .matches_regex;
        // if (std.ascii.eqlIgnoreCase(s, "not_matches_regex")) return .not_matches_regex;
        return null;
    }
};

pub const Assertion = struct {
    key: []const u8,
    value: []const u8,
    assertion_type: AssertionType,
};

pub const HttpRequest = struct {
    method: ?http.Method,
    url: []const u8,
    headers: ArrayList(http.Header),
    body: ?[]const u8,
    assertions: ArrayList(Assertion),
    // TODO: Add a name for the request if needed.

    pub fn init(allocator: Allocator) HttpRequest {
        return .{
            .method = null,
            .url = "",
            .headers = ArrayList(http.Header).init(allocator),
            .body = null,
            .assertions = ArrayList(Assertion).init(allocator),
        };
    }

    pub fn deinit(self: *HttpRequest, allocator: Allocator) void {
        if (self.url.len > 0) allocator.free(self.url);
        for (self.assertions.items) |assertion| {
            if (assertion.key.len > 0) allocator.free(assertion.key);
            if (assertion.value.len > 0) allocator.free(assertion.value);
        }
        self.assertions.deinit();
        for (self.headers.items) |header| {
            if (header.name.len > 0) allocator.free(header.name);
            if (header.value.len > 0) allocator.free(header.value);
        }
        self.headers.deinit();
        if (self.body) |body| {
            if (body.len > 0) allocator.free(body);
        }
    }
};

pub fn parseFile(allocator: Allocator, file_path: []const u8) !ArrayList(HttpRequest) {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();
    const file_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(file_content);
    return try parseContent(allocator, file_content);
}

pub fn parseContent(allocator: Allocator, content: []const u8) !ArrayList(HttpRequest) {
    var requests = ArrayList(HttpRequest).init(allocator);
    errdefer {
        for (requests.items) |*request| request.deinit(allocator);
        requests.deinit();
    }

    var current_request = HttpRequest.init(allocator);
    errdefer current_request.deinit(allocator);
    var state: ?ParserState = null;
    var lines = std.mem.splitScalar(u8, content, '\n');
    var body_buffer = ArrayList(u8).init(allocator);
    defer body_buffer.deinit();

    while (lines.next()) |line| {
        const trimmed_line = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed_line.len == 0) {
            if (state == .headers) state = .body;
            continue;
        }
        if (std.mem.startsWith(u8, trimmed_line, "###")) {
            if (current_request.method != null) {
                if (state == .body and body_buffer.items.len > 0) {
                    current_request.body = try allocator.dupe(u8, body_buffer.items);
                    body_buffer.clearRetainingCapacity();
                }
                try requests.append(current_request);
                current_request = HttpRequest.init(allocator);
                state = null;
            }
            continue;
        }
        if (std.mem.startsWith(u8, trimmed_line, "//#")) {
            // Assertion line
            var assertion_tokens = std.mem.tokenizeScalar(u8, std.mem.trim(u8, trimmed_line[3..], " "), ' ');
            const key = assertion_tokens.next() orelse return error.InvalidAssertionFormat;
            const type_str = assertion_tokens.next() orelse return error.InvalidAssertionFormat;
            const value = assertion_tokens.next() orelse return error.InvalidAssertionFormat;
            const assertion_type = AssertionType.fromString(type_str) orelse return error.InvalidAssertionFormat;
            const assertion = Assertion{
                .key = try allocator.dupe(u8, key),
                .value = try allocator.dupe(u8, value),
                .assertion_type = assertion_type,
            };
            if (assertion.key.len == 0 or assertion.value.len == 0) return error.InvalidAssertionFormat;
            try current_request.assertions.append(assertion);
            continue;
        }
        if (std.mem.startsWith(u8, trimmed_line, "#") or std.mem.startsWith(u8, trimmed_line, "//")) {
            continue;
        }
        if (state == null and current_request.method == null) {
            var tokens = std.mem.tokenizeScalar(u8, trimmed_line, ' ');
            const method_str = tokens.next() orelse return error.InvalidRequestMissingMethod;
            const url = tokens.next() orelse return error.InvalidRequestMissingURL;
            current_request.method = std.meta.stringToEnum(http.Method, method_str) orelse null;
            current_request.url = try allocator.dupe(u8, url);
            state = .headers;
            continue;
        }
        if (state == .headers) {
            if (std.mem.indexOf(u8, trimmed_line, ":")) |colon_pos| {
                const header_name = std.mem.trim(u8, trimmed_line[0..colon_pos], &std.ascii.whitespace);
                const header_value = std.mem.trim(u8, trimmed_line[colon_pos + 1 ..], &std.ascii.whitespace);
                try current_request.headers.append(http.Header{
                    .name = try allocator.dupe(u8, header_name),
                    .value = try allocator.dupe(u8, header_value),
                });
            } else {
                return error.InvalidHeaderFormat;
            }
            continue;
        }
        if (state == .body) {
            try body_buffer.appendSlice(trimmed_line);
            try body_buffer.append('\n');
            continue;
        }
    }
    if (current_request.method != null) {
        if (state == .body and body_buffer.items.len > 0) {
            current_request.body = try allocator.dupe(u8, body_buffer.items);
        }
        try requests.append(current_request);
    }
    return requests;
}

test "HttpParser from String Contents" {
    const test_http_contents =
        \\GET https://api.example.com
        \\Accept: */*
        \\Authorization: Bearer ABC123
        \\
        \\###
        \\
        \\POST https://api.example.com/users
        \\Accept: */*
        \\Authorization: Bearer ABC123
        \\
        \\{
        \\  "name": "John Doe",
        \\  "email": "John@Doe.com",
        \\}
    ;

    var requests = try parseContent(std.testing.allocator, test_http_contents);
    defer {
        for (requests.items) |*request| {
            request.deinit(std.testing.allocator);
        }
        requests.deinit();
    }

    try std.testing.expectEqual(http.Method.GET, requests.items[0].method);
    try std.testing.expectEqual(http.Method.POST, requests.items[1].method);
    try std.testing.expectEqualStrings("https://api.example.com", requests.items[0].url);
    try std.testing.expectEqualStrings("https://api.example.com/users", requests.items[1].url);
    try std.testing.expectEqualStrings("Authorization", requests.items[0].headers.items[1].name);
    try std.testing.expectEqualStrings("Bearer ABC123", requests.items[0].headers.items[1].value);
    try std.testing.expectEqualStrings("Authorization", requests.items[1].headers.items[1].name);
    try std.testing.expectEqualStrings("Bearer ABC123", requests.items[1].headers.items[1].value);
    try std.testing.expectEqual(0, (requests.items[0].body orelse "").len);
    try std.testing.expect(0 != (requests.items[1].body orelse "").len);
}

test "HttpParser parses assertions" {
    const test_http_contents =
        \\GET https://api.example.com
        \\Accept: */*
        \\Authorization: Bearer ABC123
        \\
        \\//# status equal 200
    ;

    var requests = try parseContent(std.testing.allocator, test_http_contents);
    defer {
        for (requests.items) |*request| {
            request.deinit(std.testing.allocator);
        }
        requests.deinit();
    }

    try std.testing.expectEqual(http.Method.GET, requests.items[0].method);
    try std.testing.expectEqualStrings("https://api.example.com", requests.items[0].url);
    try std.testing.expectEqualStrings("status", requests.items[0].assertions.items[0].key);
    try std.testing.expectEqual(AssertionType.equal, requests.items[0].assertions.items[0].assertion_type);
    try std.testing.expectEqualStrings("200", requests.items[0].assertions.items[0].value);
    try std.testing.expectEqual(0, (requests.items[0].body orelse "").len);
}
