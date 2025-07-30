const std = @import("std");
const HttpParser = @import("./httpfile/parser.zig");
const AssertionChecker = @import("./httpfile/assertion_checker.zig");
const Client = @import("./httpfile/http_client.zig");

// Global allocator for WASM - use page allocator which works reliably in WASM
const allocator = std.heap.page_allocator;

// External JavaScript functions that we can call from WASM
extern fn consoleLog(ptr: [*]const u8, len: usize) void;
extern fn consoleError(ptr: [*]const u8, len: usize) void;

// External fetch function - JS will implement this
extern fn fetchHttp(
    method_ptr: [*]const u8, method_len: usize,
    url_ptr: [*]const u8, url_len: usize, 
    headers_ptr: [*]const u8, headers_len: usize,
    body_ptr: [*]const u8, body_len: usize
) [*]const u8;
extern fn getFetchResultLength() usize;

// Buffer to store the result JSON
var result_buffer: [65536]u8 = undefined; // 64KB for results
var result_len: usize = 0;

// Test result structure
const TestResult = struct {
    request_name: []const u8,
    passed: bool,
    error_message: ?[]const u8,
    status_code: ?u16,
    
    pub fn init(request_name: []const u8, passed: bool, error_message: ?[]const u8, status_code: ?u16) TestResult {
        return TestResult{
            .request_name = request_name,
            .passed = passed,
            .error_message = error_message,
            .status_code = status_code,
        };
    }
};

/// WASM HTTP Client that uses external fetch function
const WasmHttpClient = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(alloc: std.mem.Allocator) WasmHttpClient {
        return .{ .allocator = alloc };
    }
    
    pub fn execute(self: *WasmHttpClient, request: *const HttpParser.HttpRequest) !Client.HttpResponse {
        const method_name = if (request.method) |m| @tagName(m) else "GET";
        
        // Serialize headers to JSON string
        var headers_json = std.ArrayList(u8).init(self.allocator);
        defer headers_json.deinit();
        var writer = headers_json.writer();
        
        try writer.writeAll("{");
        for (request.headers.items, 0..) |header, i| {
            if (i > 0) try writer.writeAll(", ");
            try std.json.stringify(header.name, .{}, writer);
            try writer.writeAll(": ");
            try std.json.stringify(header.value, .{}, writer);
        }
        try writer.writeAll("}");
        
        const body_ptr = if (request.body) |body| body.ptr else "";
        const body_len = if (request.body) |body| body.len else 0;
        
        // Call external fetch function
        const response_ptr = fetchHttp(
            method_name.ptr, method_name.len,
            request.url.ptr, request.url.len,
            headers_json.items.ptr, headers_json.items.len,
            body_ptr, body_len
        );
        
        const response_len = getFetchResultLength();
        const response_json = response_ptr[0..response_len];
        
        // Parse the JSON response from JavaScript
        return try parseHttpResponse(self.allocator, response_json);
    }
};

/// Parse HTTP response JSON from JavaScript fetch
fn parseHttpResponse(alloc: std.mem.Allocator, json_str: []const u8) !Client.HttpResponse {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_str, .{}) catch |err| {
        const error_msg = std.fmt.allocPrint(alloc, "Failed to parse response JSON: {s}", .{@errorName(err)}) catch "Failed to parse response JSON";
        defer alloc.free(error_msg);
        consoleError(error_msg, error_msg.len);
        return error.InvalidResponseJson;
    };
    defer parsed.deinit();
    
    const root = parsed.value.object;
    
    var response = Client.HttpResponse.init(alloc);
    
    // Parse status code
    if (root.get("status")) |status_val| {
        if (status_val == .integer) {
            const status_code: u16 = @intCast(status_val.integer);
            response.status = std.meta.intToEnum(std.http.Status, status_code) catch null;
        }
    }
    
    // Parse headers
    if (root.get("headers")) |headers_val| {
        if (headers_val == .object) {
            var header_iter = headers_val.object.iterator();
            while (header_iter.next()) |entry| {
                const name = try alloc.dupe(u8, entry.key_ptr.*);
                const value = if (entry.value_ptr.* == .string) 
                    try alloc.dupe(u8, entry.value_ptr.*.string) 
                else 
                    try alloc.dupe(u8, "");
                try response.headers.put(name, value);
            }
        }
    }
    
    // Parse body
    if (root.get("body")) |body_val| {
        if (body_val == .string) {
            response.body = try alloc.dupe(u8, body_val.string);
        }
    }
    
    return response;
}

/// Main unified function: parse, execute, and assert all in WASM
export fn executeHttpSpecComplete(content_ptr: [*]const u8, content_len: usize) [*]const u8 {
    const content = content_ptr[0..content_len];
    
    // Parse the HTTPSpec content
    var items = HttpParser.parseContent(allocator, content) catch |err| {
        const error_json = std.fmt.bufPrint(&result_buffer, 
            \\{{"success": false, "error": "Parse failed: {s}", "results": []}}
        , .{@errorName(err)}) catch "{{\"success\": false, \"error\": \"JSON format error\", \"results\": []}}";
        
        result_len = error_json.len;
        return &result_buffer;
    };
    
    const owned_items = items.toOwnedSlice() catch |err| {
        const error_json = std.fmt.bufPrint(&result_buffer, 
            \\{{"success": false, "error": "Failed to convert items: {s}", "results": []}}
        , .{@errorName(err)}) catch "{{\"success\": false, \"error\": \"JSON format error\", \"results\": []}}";
        
        result_len = error_json.len;
        return &result_buffer;
    };
    defer {
        for (owned_items) |*item| {
            item.deinit(allocator);
        }
        allocator.free(owned_items);
    }
    
    // Execute requests and run assertions
    var results = std.ArrayList(TestResult).init(allocator);
    defer results.deinit();
    
    var client = WasmHttpClient.init(allocator);
    
    for (owned_items, 0..) |*request, i| {
        const request_name = std.fmt.allocPrint(allocator, "Request {d}", .{i + 1}) catch "Unknown Request";
        // Don't defer free - the TestResult needs to keep the string
        
        // Execute HTTP request
        var response = client.execute(request) catch |err| {
            const error_msg = std.fmt.allocPrint(allocator, "HTTP request failed: {s}", .{@errorName(err)}) catch "HTTP request failed";
            // Don't defer free - the TestResult needs to keep the string
            
            results.append(TestResult.init(request_name, false, error_msg, null)) catch {
                consoleError("Failed to append test result", 30);
                continue;
            };
            continue;
        };
        defer response.deinit();
        
        const status_code: u16 = if (response.status) |status| @intFromEnum(status) else 0;
        
        // Run assertions
        var console_error_writer = ConsoleErrorWriter{};
        AssertionChecker.check(request, response, console_error_writer.writer()) catch |err| {
            const error_msg = std.fmt.allocPrint(allocator, "Assertion failed: {s}", .{@errorName(err)}) catch "Assertion failed";
            // Don't defer free - the TestResult needs to keep the string
            
            results.append(TestResult.init(request_name, false, error_msg, status_code)) catch {
                consoleError("Failed to append test result", 30);
                continue;
            };
            continue;
        };
        
        // All assertions passed
        results.append(TestResult.init(request_name, true, null, status_code)) catch {
            consoleError("Failed to append test result", 30);
            continue;
        };
    }
    
    // Format results as JSON
    const json = formatTestResults(results.items) catch "{{\"success\": false, \"error\": \"Failed to format results\", \"results\": []}}";
    result_len = json.len;
    
    return &result_buffer;
}

/// Format test results as JSON
fn formatTestResults(results: []const TestResult) ![]const u8 {
    var json_string = std.ArrayList(u8).init(allocator);
    defer json_string.deinit();
    
    var writer = json_string.writer();
    
    try writer.writeAll("{\"success\": true, \"results\": [");
    
    for (results, 0..) |result, i| {
        if (i > 0) try writer.writeAll(", ");
        
        try writer.writeAll("{");
        try writer.writeAll("\"name\": ");
        try std.json.stringify(result.request_name, .{}, writer);
        try writer.writeAll(", \"passed\": ");
        try writer.writeAll(if (result.passed) "true" else "false");
        
        if (result.status_code) |status| {
            try writer.writeAll(", \"status\": ");
            try writer.print("{d}", .{status});
        }
        
        if (result.error_message) |error_msg| {
            try writer.writeAll(", \"error\": ");
            try std.json.stringify(error_msg, .{}, writer);
        }
        
        try writer.writeAll("}");
    }
    
    try writer.writeAll("]}");
    
    // Copy to result buffer
    const json_str = json_string.items;
    if (json_str.len >= result_buffer.len) {
        return std.fmt.bufPrint(&result_buffer, "{{\"success\": false, \"error\": \"Results too large ({d} bytes), buffer size {d}\", \"results\": []}}", .{ json_str.len, result_buffer.len });
    }
    
    @memcpy(result_buffer[0..json_str.len], json_str);
    return result_buffer[0..json_str.len];
}


/// Returns the length of the last result
export fn getResultLength() usize {
    return result_len;
}



/// Console error writer for assertion failures
const ConsoleErrorWriter = struct {
    pub const Error = error{};
    pub const Writer = std.io.Writer(ConsoleErrorWriter, Error, write);
    
    pub fn writer(self: ConsoleErrorWriter) Writer {
        return .{ .context = self };
    }
    
    pub fn write(self: ConsoleErrorWriter, bytes: []const u8) Error!usize {
        _ = self;
        consoleError(bytes.ptr, bytes.len);
        return bytes.len;
    }
};



