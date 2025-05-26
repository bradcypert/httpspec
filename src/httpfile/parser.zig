const std = @import("std");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

pub const HttpMethod = enum {
    GET,
    POST,
    PUT,
    DELETE,
    PATCH,
    HEAD,
    OPTIONS,
    TRACE,
    CONNECT,

    pub fn fromString(method_str: []const u8) ?HttpMethod {
        return std.meta.stringToEnum(HttpMethod, method_str) orelse null;
    }
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const HttpRequest = struct {
    method: ?HttpMethod,
    url: []const u8,
    headers: ArrayList(Header),
    body: ?[]const u8,

    pub fn init(allocator: Allocator) HttpRequest {
        return .{
            .method = null,
            .url = "",
            .headers = ArrayList(Header).init(allocator),
            .body = null,
        };
    }

    pub fn deinit(self: *HttpRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.url);

        for (self.headers.items) |header| {
            allocator.free(header.name);
            allocator.free(header.value);
        }

        if (self.body) |body| {
            allocator.free(body);
        }
        self.headers.deinit();
    }
};

pub fn parseFile(allocator: std.mem.Allocator, file_path: []const u8) !ArrayList(HttpRequest) {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const file_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(file_content);

    return try parseContent(file_content);
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

    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_index: usize = 0;
    var in_headers = false;
    var in_body = false;
    var body_buffer = ArrayList(u8).init(allocator);
    defer body_buffer.deinit();

    while (lines.next()) |line| {
        line_index += 1;
        const trimmed_line = std.mem.trim(u8, line, &std.ascii.whitespace);

        if (trimmed_line.len == 0) {
            if (in_headers) {
                in_headers = false;
                in_body = true;
            }
            continue;
        }

        if (std.mem.startsWith(u8, trimmed_line, "###")) {
            if (current_request.method != null) {
                // if we're in the body, dupe it and clear it
                if (in_body and body_buffer.items.len > 0) {
                    current_request.body = try allocator.dupe(u8, body_buffer.items);
                    body_buffer.clearRetainingCapacity();
                }

                try requests.append(current_request);
                current_request = HttpRequest.init(allocator);
                in_body = false;
                in_headers = false;
            }
            continue;
        }

        if (std.mem.startsWith(u8, trimmed_line, "#") or std.mem.startsWith(u8, trimmed_line, "//")) {
            continue;
        }

        if (!in_headers and !in_body and current_request.method == null) {
            var tokens = std.mem.tokenizeScalar(u8, trimmed_line, ' ');
            const method_str = tokens.next() orelse return error.InvalidRequestMissingMethod;
            const url = tokens.next() orelse return error.InvalidRequestMissingURL;

            current_request.method = HttpMethod.fromString(method_str);
            current_request.url = try allocator.dupe(u8, url);
            in_headers = true;
            continue;
        }

        if (in_headers) {
            if (std.mem.indexOf(u8, trimmed_line, ":")) |colon_pos| {
                const header_name = std.mem.trim(u8, trimmed_line[0..colon_pos], &std.ascii.whitespace);
                const header_value = std.mem.trim(u8, trimmed_line[colon_pos + 1 ..], &std.ascii.whitespace);

                try current_request.headers.append(Header{
                    .name = try allocator.dupe(u8, header_name),
                    .value = try allocator.dupe(u8, header_value),
                });
            } else {
                return error.InvalidHeaderFormat;
            }
        }

        if (in_body) {
            try body_buffer.appendSlice(trimmed_line);
            try body_buffer.append('\n');
        }
    }

    if (current_request.method != null) {
        if (in_body and body_buffer.items.len > 0) {
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

    try std.testing.expectEqual(HttpMethod.GET, requests.items[0].method);
    try std.testing.expectEqual(HttpMethod.POST, requests.items[1].method);
    try std.testing.expectEqualStrings("https://api.example.com", requests.items[0].url);
    try std.testing.expectEqualStrings("https://api.example.com/users", requests.items[1].url);
    try std.testing.expectEqualStrings("Authorization", requests.items[0].headers.items[1].name);
    try std.testing.expectEqualStrings("Bearer ABC123", requests.items[0].headers.items[1].value);
    try std.testing.expectEqualStrings("Authorization", requests.items[1].headers.items[1].name);
    try std.testing.expectEqualStrings("Bearer ABC123", requests.items[1].headers.items[1].value);
    try std.testing.expectEqual(0, (requests.items[0].body orelse "").len);
    try std.testing.expect(0 != (requests.items[1].body orelse "").len);
}
