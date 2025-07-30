const std = @import("std");
const HttpParser = @import("./httpfile/parser.zig");

// Global allocator for WASM - use page allocator which works reliably in WASM
const allocator = std.heap.page_allocator;

// External JavaScript functions that we can call from WASM
extern fn consoleLog(ptr: [*]const u8, len: usize) void;
extern fn consoleError(ptr: [*]const u8, len: usize) void;

// Buffer to store the result JSON
var result_buffer: [65536]u8 = undefined; // 64KB for results
var result_len: usize = 0;

/// Single entry point: parses HTTPSpec content and returns structured data for JavaScript to execute
export fn parseHttpSpecToJson(content_ptr: [*]const u8, content_len: usize) [*]const u8 {
    const content = content_ptr[0..content_len];
    
    logToConsole("Parsing HTTPSpec content...");
    
    // Parse the HTTPSpec content
    var items = HttpParser.parseContent(allocator, content) catch |err| {
        const error_msg = std.fmt.allocPrint(allocator, "Parse failed: {s}", .{@errorName(err)}) catch "Parse failed";
        defer allocator.free(error_msg);
        logErrorToConsole(error_msg);
        
        const error_json = std.fmt.bufPrint(&result_buffer, 
            \\{{"success": false, "error": "Parse failed: {s}", "requests": []}}
        , .{@errorName(err)}) catch "{{\"success\": false, \"error\": \"JSON format error\", \"requests\": []}}";
        
        result_len = error_json.len;
        return &result_buffer;
    };
    
    const owned_items = items.toOwnedSlice() catch |err| {
        const error_msg = std.fmt.allocPrint(allocator, "Failed to convert items: {s}", .{@errorName(err)}) catch "Failed to convert items";
        defer allocator.free(error_msg);
        logErrorToConsole(error_msg);
        
        const error_json = std.fmt.bufPrint(&result_buffer, 
            \\{{"success": false, "error": "Failed to convert items: {s}", "requests": []}}
        , .{@errorName(err)}) catch "{{\"success\": false, \"error\": \"JSON format error\", \"requests\": []}}";
        
        result_len = error_json.len;
        return &result_buffer;
    };
    defer {
        for (owned_items) |*item| {
            item.deinit(allocator);
        }
        allocator.free(owned_items);
    }
    
    const log_msg = std.fmt.allocPrint(allocator, "Parsed {d} HTTP requests", .{owned_items.len}) catch "Parsed requests";
    defer allocator.free(log_msg);
    logToConsole(log_msg);
    
    // Convert parsed requests to JSON for JavaScript to execute
    const json = formatRequestsAsJson(owned_items) catch "{{\"success\": false, \"error\": \"JSON format error\", \"requests\": []}}";
    result_len = json.len;
    
    logToConsole("HTTPSpec parsing complete");
    
    return &result_buffer;
}

/// Returns the length of the last result
export fn getResultLength() usize {
    return result_len;
}

/// Formats parsed requests as JSON string for JavaScript to execute
/// Uses manual JSON construction because std.json.stringify has issues with complex types in WASM
fn formatRequestsAsJson(requests: []const HttpParser.HttpRequest) ![]const u8 {
    var json_string = std.ArrayList(u8).init(allocator);
    defer json_string.deinit();
    
    var writer = json_string.writer();
    
    try writer.writeAll("{\"success\": true, \"requests\": [");
    
    for (requests, 0..) |request, i| {
        if (i > 0) try writer.writeAll(", ");
        
        try writer.writeAll("{");
        
        // Method
        const method_name = if (request.method) |m| @tagName(m) else "GET";
        try writer.writeAll("\"method\": ");
        try std.json.stringify(method_name, .{}, writer);
        try writer.writeAll(", ");
        
        // URL  
        try writer.writeAll("\"url\": ");
        try std.json.stringify(request.url, .{}, writer);
        try writer.writeAll(", ");
        
        // Headers as object
        try writer.writeAll("\"headers\": {");
        for (request.headers.items, 0..) |header, j| {
            if (j > 0) try writer.writeAll(", ");
            try std.json.stringify(header.name, .{}, writer);
            try writer.writeAll(": ");
            try std.json.stringify(header.value, .{}, writer);
        }
        try writer.writeAll("}, ");
        
        // Body
        try writer.writeAll("\"body\": ");
        if (request.body) |body| {
            try std.json.stringify(body, .{}, writer);
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(", ");
        
        // Assertions
        try writer.writeAll("\"assertions\": [");
        for (request.assertions.items, 0..) |assertion, k| {
            if (k > 0) try writer.writeAll(", ");
            try writer.writeAll("{");
            try writer.writeAll("\"key\": ");
            try std.json.stringify(assertion.key, .{}, writer);
            try writer.writeAll(", \"value\": ");
            try std.json.stringify(assertion.value, .{}, writer);
            try writer.writeAll(", \"type\": ");
            try std.json.stringify(@tagName(assertion.assertion_type), .{}, writer);
            try writer.writeAll("}");
        }
        try writer.writeAll("]");
        
        try writer.writeAll("}");
    }
    
    try writer.writeAll("]}");
    
    // Copy to result buffer
    const json_str = json_string.items;
    if (json_str.len >= result_buffer.len) {
        return std.fmt.bufPrint(&result_buffer, "{{\"success\": false, \"error\": \"JSON too large ({d} bytes), buffer size {d}\", \"requests\": []}}", .{ json_str.len, result_buffer.len });
    }
    
    @memcpy(result_buffer[0..json_str.len], json_str);
    return result_buffer[0..json_str.len];
}

// escapeJsonString function removed - std.json.stringify handles escaping automatically

/// Test function to verify WASM is working
export fn testWasm() i32 {
    consoleLog("WASM module loaded successfully!", 30);
    return 42;
}

/// Logging helper functions for debugging
fn logToConsole(message: []const u8) void {
    consoleLog(message.ptr, message.len);
}

fn logErrorToConsole(message: []const u8) void {
    consoleError(message.ptr, message.len);
}

/// Test function for basic HTTPSpec parsing
export fn testHttpSpecParsing() [*]const u8 {
    const test_content = 
        \\### Test request
        \\GET https://httpbin.org/status/200
        \\
        \\//# status == 200
    ;
    
    return parseHttpSpecToJson(test_content.ptr, test_content.len);
}