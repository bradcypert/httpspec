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
};

const Assertion = struct {
    key: []const u8,
    value: []const u8,
    // TODO: This shouldn't be nullable.
    // We can change the way this value is parsed so that
    // null is not a valid option.
    assertion_type: ?AssertionType,
};

pub const HttpRequest = struct {
    method: ?http.Method,
    url: []const u8,
    headers: ArrayList(http.Header),
    body: ?[]const u8,
    assertions: ArrayList(Assertion),

    pub fn init(allocator: Allocator) HttpRequest {
        return .{
            .method = null,
            .url = "",
            .headers = ArrayList(http.Header).init(allocator),
            .body = null,
            .assertions = ArrayList(Assertion).init(allocator),
        };
    }

    pub fn deinit(self: *HttpRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.url);

        for (self.assertions.items) |assertion| {
            allocator.free(assertion.key);
            allocator.free(assertion.value);
        }
        self.assertions.deinit();

        for (self.headers.items) |header| {
            allocator.free(header.name);
            allocator.free(header.value);
        }
        self.headers.deinit();

        if (self.body) |body| {
            allocator.free(body);
        }
    }
};

pub fn parseFile(allocator: std.mem.Allocator, file_path: []const u8) !ArrayList(HttpRequest) {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const file_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(file_content);

    return try parseContent(allocator, file_content);
}

pub fn parseContent(allocator: std.mem.Allocator, content: []const u8) !ArrayList(HttpRequest) {
    var requests = ArrayList(HttpRequest).init(allocator);
    errdefer {
        for (requests.items) |*request| {
            request.deinit(allocator);
        }

        requests.deinit();
    }

    var current_request = HttpRequest.init(allocator);
    errdefer current_request.deinit(allocator);
    var state: ?ParserState = null;

    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_index: usize = 0;
    var body_buffer = ArrayList(u8).init(allocator);
    defer body_buffer.deinit();

    while (lines.next()) |line| {
        line_index += 1;
        const trimmed_line = std.mem.trim(u8, line, &std.ascii.whitespace);

        if (trimmed_line.len == 0) {
            if (state == .headers) {
                state = .body;
            }
            continue;
        }

        if (std.mem.startsWith(u8, trimmed_line, "###")) {
            if (current_request.method != null) {
                // if we're in the body, dupe it and clear it
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
            // These are assertions.
            var assertion_tokens = std.mem.tokenizeScalar(u8, trimmed_line[3..], ' ');
            var assertion = Assertion{
                .key = "",
                .value = "",
                .assertion_type = null,
            };
            if (assertion_tokens.next()) |first_token| {
                // The first token is the assertion type.
                assertion.key = first_token;
            } else {
                return error.InvalidAssertionFormat;
            }
            if (assertion_tokens.next()) |second_token| {
                // The first token is the assertion type.
                assertion.assertion_type = std.meta.stringToEnum(AssertionType, second_token) orelse null;
            } else {
                return error.InvalidAssertionFormat;
            }
            if (assertion_tokens.next()) |third_token| {
                // The first token is the assertion type.
                assertion.value = third_token;
            } else {
                return error.InvalidAssertionFormat;
            }
            if (assertion.key.len == 0 or assertion.value.len == 0 or assertion.assertion_type == null) {
                return error.InvalidAssertionFormat;
            }
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
        }

        if (state == .body) {
            try body_buffer.appendSlice(trimmed_line);
            try body_buffer.append('\n');
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
        \\//# status_code equal 200
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
    try std.testing.expectEqualStrings("status", requests.items[0].assertions.items[0].assertions[0].key);
    try std.testing.expectEqual(AssertionType.equal, requests.items[0].assertions.items[0].assertions[0].assertion_type);
    try std.testing.expectEqualStrings("200", requests.items[0].assertions.items[0].assertions[0].value);
    try std.testing.expectEqual(0, (requests.items[0].body orelse "").len);
    try std.testing.expect(0 != (requests.items[1].body orelse "").len);
}
