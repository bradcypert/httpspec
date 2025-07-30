# From CLI to Web: Adding WebAssembly Support to a Zig Project

Have you ever wanted to take your command-line Zig application and run it in the browser? WebAssembly (WASM) makes this possible, but the journey from a CLI tool to a web-friendly application involves some interesting challenges. In this tutorial, I'll walk you through the process of adding WebAssembly support to HTTPSpec, a command-line HTTP testing tool written in Zig.

## What is WASM

WebAssembly, often abbreviated as WASM, is a low-level binary instruction format designed to run code at near-native speed in web browsers. It’s not a language you write directly (most of the time), but a compilation target for other languages like C, Rust, Zig, or Go.

It starts with your source code written in something like Zig, C, or Rust. That gets compiled into WebAssembly bytecode - a `.wasm` file. That .wasm file is then loaded into the browser using JavaScript. The browser runs it in a secure, sandboxed virtual machine. And the cool part? It’s fast—closer to native performance than JavaScript can usually manage.

But even though it runs in the browser, Wasm isn’t just limited to the web. It’s also being used on the server side in things like Wasmtime, Wasmer, and even for running plugins in some applications.

## When to use WASM

You might reach for WebAssembly when you want to:

- Run performance-critical code in the browser
- Reuse code across frontend and backend
- Port existing native libraries to the web
- Or avoid JavaScript entirely for certain use cases

It also opens the door to new languages on the web that were traditionally locked out—like Go, Rust, and Zig.

## Our Project: HTTPSpec Deep Dive

HTTPSpec started as a simple idea: what if you could take those `.http` files that developers use for API testing and add proper assertions to them? Instead of just sending requests and eyeballing the responses, you could write tests that automatically verify the behavior.

The tool parses files that look like this:

```http
### Test user registration
POST https://api.example.com/users
Content-Type: application/json

{
  "username": "testuser",
  "email": "test@example.com",
  "password": "securepassword123"
}

//# status == 201
//# header["content-type"] contains "application/json"
//# body contains "testuser"
//# body contains "id"
```

Those `//# ` lines are the magic—they're assertions that HTTPSpec evaluates after each request completes. You can check status codes, headers, and body content using a simple but powerful syntax.

### The Original Architecture

When I first built HTTPSpec, I made some assumptions that seemed perfectly reasonable for a CLI tool:

**File System Heavy**: The tool recursively searches directories for `.http` and `.httpspec` files, reads them from disk, and processes them sequentially. This made sense—most integration test suites are organized as collections of files in a project structure.

```zig
// This is how HTTPSpec originally discovered test files
const allocator = std.heap.page_allocator;
var dir = try std.fs.cwd().openIterableDir(".", .{});
defer dir.close();

var walker = try dir.walk(allocator);
defer walker.deinit();

while (try walker.next()) |entry| {
    if (entry.kind == .file) {
        if (std.mem.endsWith(u8, entry.path, ".http") or 
            std.mem.endsWith(u8, entry.path, ".httpspec")) {
            try file_list.append(entry.path);
        }
    }
}
```

**Parallel Execution**: To speed up test suites with dozens of HTTP requests, HTTPSpec uses Zig's thread pool to execute requests in parallel. Each `.http` file gets processed on its own thread, dramatically reducing total execution time.

```zig
var pool: std.Thread.Pool = undefined;
try pool.init(.{ .allocator = allocator, .n_jobs = thread_count });
defer pool.deinit();

for (http_files) |file_path| {
    try pool.spawn(processHttpFile, .{ allocator, file_path });
}
```

**Rich Terminal Output**: HTTPSpec produces colorized output with progress indicators, detailed error messages, and summary statistics. It's designed to integrate smoothly into CI/CD pipelines while providing great developer experience locally.

```zig
// Colorized output using ANSI codes
const stdout = std.io.getStdOut().writer();
try stdout.print("\x1b[32m✓\x1b[0m {s}\n", .{test_name}); // Green checkmark
try stdout.print("\x1b[31m✗\x1b[0m {s}: {s}\n", .{test_name, error_msg}); // Red X
```

**Command Line Interface**: Built with the excellent `clap` library, HTTPSpec accepts file paths, directory paths, and various configuration options:

```bash
httpspec tests/api/              # Run all tests in directory
httpspec user_registration.http # Run specific file
httpspec --threads 10           # Control parallelism
httpspec --verbose              # Detailed output
```

### The WASM Challenge

Here's the problem: every single one of these architectural decisions breaks in a WebAssembly environment.

**No File System**: WASM runs in a sandbox. There's no `std.fs.cwd()`, no directory walking, no file reading. The entire concept of "process these files from disk" doesn't exist.

**No Threading**: WASM is fundamentally single-threaded. There's no `std.Thread.Pool`, no parallel execution, no concurrent HTTP requests. Everything has to happen sequentially.

**No Standard I/O**: There's no stdout, no stderr, no terminal colors. The beautiful CLI output that makes HTTPSpec pleasant to use locally just... doesn't work.

**No Command Line**: There are no command line arguments in a browser. The entire `clap`-based interface needs to be replaced with something web-appropriate.

But here's the thing that kept me motivated: the core value proposition of HTTPSpec—parsing HTTP files and validating assertions—that logic is pure. It doesn't inherently need files or threads or terminals. It just needs strings of HTTP content and the ability to make HTTP requests.

The key insight was realizing I didn't need to port HTTPSpec to WASM. I needed to extract the valuable parts and build a hybrid system where WASM handles what it's good at (parsing, data transformation) and JavaScript handles what it's good at (HTTP requests, DOM manipulation, user interaction).

### What We're Building

Our end goal is a web application where developers can:

1. Paste HTTPSpec content into a text editor
2. Click "Run Tests" and see real HTTP requests execute
3. Get detailed results showing which assertions passed or failed
4. Use the same assertion syntax they know from the CLI tool

The WASM module will handle the parsing—taking raw HTTPSpec content and converting it into structured data that JavaScript can work with. JavaScript will handle everything else: the user interface, making HTTP requests, checking assertions, and displaying results.

This hybrid approach means we get to reuse the battle-tested parsing logic from the original tool while embracing the web platform's strengths. WASM handles the complex parsing and data transformation that would be tedious to reimplement in JavaScript, while JavaScript handles HTTP requests using `fetch()`, UI interactions, and all the web-native capabilities.

None of these work in a WebAssembly environment, which is sandboxed and single-threaded. So how do we bridge this gap? The answer lies in understanding what parts of our application are truly essential and what parts are just implementation details of the CLI experience.

## Step 1: Understand Your Dependencies

Before diving into WASM, we need to audit our existing application and identify what won't work. This isn't just about checking imports—it's about understanding the fundamental assumptions your code makes about its runtime environment.

### The WASM Compatibility Audit

I started by going through HTTPSpec's codebase systematically, categorizing each dependency and feature:

**❌ Definitely Won't Work:**

```zig
// Command line argument parsing
const clap = @import("clap");
const params = comptime clap.parseParamsComptime(/* ... */);
const args = try clap.parse(clap.Help, &params, clap.parsers.default, .{});

// Threading and parallelism
var pool: std.Thread.Pool = undefined;
try pool.init(.{ .allocator = allocator, .n_jobs = thread_count });
defer pool.deinit();

// File system operations
const file = try std.fs.cwd().openFile(path, .{});
var dir = try std.fs.cwd().openIterableDir(".", .{});
const contents = try file.readToEndAlloc(allocator, max_size);

// Standard I/O
const stdout = std.io.getStdOut().writer();
const stderr = std.io.getStdErr().writer();
try stdout.print("Processing {s}...\n", .{filename});
```

**✅ Should Work Fine:**

```zig
// String manipulation and parsing
const parsed = try std.json.parseFromSlice(MyStruct, allocator, json_string);
const index = std.mem.indexOf(u8, haystack, needle);
var lines = std.mem.split(u8, content, "\n");

// Memory management (with caveats)
var list = std.ArrayList(HttpRequest).init(allocator);
const duped = try allocator.dupe(u8, original_string);

// Basic data structures
const map = std.HashMap([]const u8, []const u8, StringContext, 80);
var buffer: [1024]u8 = undefined;
```

**❓ Needs Investigation:**

```zig
// HTTP client - this was the big question mark
var client = std.http.Client{ .allocator = allocator };
defer client.deinit();
const response = try client.fetch(.{
    .location = .{ .url = url },
    .method = .POST,
    .headers = headers,
});
```

### The HTTP Client Reality Check

Here's where I discovered an important limitation: Zig's `std.http.Client` does **not** work reliably in WASM environments when targeting the browser. This was initially disappointing because I had hoped to reuse the existing HTTP client logic.

The fundamental issue is that WASM running in browsers doesn't have access to raw network sockets. All network requests must go through the browser's APIs, which means:

- **No direct HTTP client access**: WASM can't make HTTP requests directly
- **Browser security restrictions**: CORS policies, mixed content restrictions, and other browser security features all apply
- **Different execution model**: Browsers expect async operations, while Zig's HTTP client is designed for blocking I/O

This realization led to a crucial architectural decision: instead of trying to make Zig handle HTTP requests in WASM, the better approach is to let JavaScript handle all HTTP operations using the browser's native `fetch()` API.

### Memory Allocator Considerations

This one caught me off guard. The allocator you choose makes a huge difference in WASM:

```zig
// This works but is slow and can cause issues:
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

// This is much more reliable in WASM:
const allocator = std.heap.page_allocator;

// This doesn't work at all:
const allocator = std.testing.allocator; // Only available in tests
```

The `page_allocator` is specifically designed to work well in constrained environments like WASM. It's less sophisticated than the general-purpose allocator but much more predictable.

### Dependency Tree Analysis

I also had to examine the transitive dependencies. HTTPSpec uses the `clap` library for CLI parsing, but `clap` itself might have dependencies that don't work in WASM:

```zig
// In build.zig.zon, I had to trace through:
.{
    .name = "httpspec",
    .version = "0.1.0",
    .dependencies = .{
        .clap = .{
            .url = "https://github.com/Hejsil/zig-clap/archive/refs/tags/0.8.0.tar.gz",
            .hash = "...",
        },
    },
}
```

Even though I wouldn't use `clap` in the WASM version, I needed to understand whether its presence would cause compilation issues. Fortunately, Zig's dead code elimination meant unused imports wouldn't be a problem.

### The Standard Library Compatibility Matrix

Through experimentation, I built a mental model of what parts of Zig's standard library work in WASM:

**✅ Reliable:**
- `std.mem.*` - Memory utilities
- `std.fmt.*` - String formatting
- `std.json.*` - JSON parsing/serialization
- `std.ArrayList`, `std.HashMap` - Basic data structures
- `std.math.*` - Mathematical operations
- `std.crypto.*` - Cryptographic functions

**⚠️ Partially Supported:**
- `std.http.*` - Works but with browser security limitations
- `std.time.*` - Basic time functions work, but not all timing mechanisms
- `std.rand.*` - Works but entropy sources are different

**❌ Not Available:**
- `std.fs.*` - File system operations
- `std.Thread.*` - Threading primitives
- `std.io.getStdOut()` - Standard I/O streams
- `std.os.*` - Operating system interfaces
- `std.ChildProcess.*` - Process spawning

### Creating a Compatibility Strategy

Based on this audit, I developed a three-tier strategy:

**Tier 1: Direct Reuse** - Code that works identically in both CLI and WASM versions. This includes the core parsing logic, data structures, and string manipulation routines.

**Tier 2: Abstraction Layer** - Code that needs different implementations but can share the same interface. For example, logging functions that use `stdout` in CLI but JavaScript console in WASM.

**Tier 3: Platform-Specific** - Code that's fundamentally different between platforms. File discovery in CLI vs. text area input in WASM, thread pools vs. sequential execution.

This systematic approach meant I could plan the refactoring before writing any WASM-specific code. I knew exactly which parts needed to be extracted into shared modules and which parts needed complete reimplementation.

### Testing Your Assumptions

One crucial step I'd recommend is actually trying to compile your existing code with the WASM target before making any changes:

```bash
zig build-exe src/main.zig -target wasm32-freestanding
```

This will immediately show you compilation errors for incompatible dependencies. In my case, the errors were exactly what I expected—missing file system operations and threading primitives—which validated my audit.

The key insight from this dependency analysis was that WASM support isn't about porting everything; it's about identifying the essential core and building a new interface around it.

## Step 2: Create a Shared Core Module

The key to successful WASM integration is extracting the pure business logic into a shared module. This isn't just about moving code around—it's about fundamentally rethinking your interfaces to work with data instead of resources.

### Designing for Dual Deployment

The original HTTPSpec had functions like this:

```zig
// Original CLI-focused design
pub fn processHttpFile(allocator: std.mem.Allocator, file_path: []const u8) !TestResult {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();
    
    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);
    
    // ... parsing and execution logic
}
```

This design assumes file system access and couples I/O with business logic. For dual deployment, I needed to invert this relationship:

```zig
// src/core.zig - New platform-agnostic design
const std = @import("std");
const HttpParser = @import("./httpfile/parser.zig");
const Client = @import("./httpfile/http_client.zig");
const AssertionChecker = @import("./httpfile/assertion_checker.zig");

pub const TestResult = struct {
    success: bool,
    error_message: ?[]const u8,
    file_path: []const u8,
    request_count: usize,
    execution_time_ms: u64,
    
    // Detailed results for each request
    request_results: []RequestResult,
    
    pub fn init(allocator: std.mem.Allocator, file_path: []const u8) TestResult {
        return .{
            .success = false,
            .error_message = null,
            .file_path = allocator.dupe(u8, file_path) catch file_path,
            .request_count = 0,
            .execution_time_ms = 0,
            .request_results = &[_]RequestResult{},
        };
    }
    
    pub fn deinit(self: *TestResult, allocator: std.mem.Allocator) void {
        if (self.error_message) |msg| {
            allocator.free(msg);
        }
        // Clean up request results
        for (self.request_results) |*result| {
            result.deinit(allocator);
        }
        allocator.free(self.request_results);
        
        // Don't free file_path if it wasn't allocated by us
        if (self.file_path.ptr != allocator.dupe(u8, self.file_path) catch self.file_path.ptr) {
            allocator.free(self.file_path);
        }
    }
};

pub const RequestResult = struct {
    url: []const u8,
    method: []const u8,
    status_code: ?u16,
    response_headers: std.StringHashMap([]const u8),
    response_body: []const u8,
    assertion_results: []AssertionResult,
    execution_time_ms: u64,
    success: bool,
    error_message: ?[]const u8,
    
    pub fn deinit(self: *RequestResult, allocator: std.mem.Allocator) void {
        // Free all allocated strings
        if (self.error_message) |msg| allocator.free(msg);
        allocator.free(self.response_body);
        
        // Free header values
        var iterator = self.response_headers.iterator();
        while (iterator.next()) |entry| {
            allocator.free(entry.value_ptr.*);
        }
        self.response_headers.deinit();
        
        // Free assertion results
        for (self.assertion_results) |*result| {
            result.deinit(allocator);
        }
        allocator.free(self.assertion_results);
    }
};

pub const AssertionResult = struct {
    assertion_text: []const u8,
    expected: []const u8,
    actual: []const u8,
    passed: bool,
    error_message: ?[]const u8,
    
    pub fn deinit(self: *AssertionResult, allocator: std.mem.Allocator) void {
        allocator.free(self.assertion_text);
        allocator.free(self.expected);
        allocator.free(self.actual);
        if (self.error_message) |msg| allocator.free(msg);
    }
};
```

### The Core Execution Function

The heart of the shared module is a function that accepts string content instead of file paths:

```zig
/// Executes HTTP requests from string content - works in both CLI and WASM
pub fn executeHttpSpecFromString(
    allocator: std.mem.Allocator,
    content: []const u8,
    file_path: []const u8, // For reporting purposes only
) !TestResult {
    const start_time = std.time.milliTimestamp();
    var result = TestResult.init(allocator, file_path);
    
    // Parse the HTTPSpec content
    var requests = HttpParser.parseContent(allocator, content) catch |err| {
        result.error_message = try std.fmt.allocPrint(
            allocator, 
            "Failed to parse HTTPSpec content: {s}", 
            .{@errorName(err)}
        );
        return result;
    };
    defer {
        for (requests) |*req| req.deinit(allocator);
        allocator.free(requests);
    }
    
    result.request_count = requests.len;
    
    // Allocate space for individual request results
    result.request_results = try allocator.alloc(RequestResult, requests.len);
    
    // Execute each request sequentially (no threading in WASM)
    var all_passed = true;
    for (requests, 0..) |request, i| {
        const req_start = std.time.milliTimestamp();
        
        var req_result = RequestResult{
            .url = try allocator.dupe(u8, request.url),
            .method = try allocator.dupe(u8, @tagName(request.method)),
            .status_code = null,
            .response_headers = std.StringHashMap([]const u8).init(allocator),
            .response_body = "",
            .assertion_results = &[_]AssertionResult{},
            .execution_time_ms = 0,
            .success = false,
            .error_message = null,
        };
        
        // Execute the HTTP request
        const response = executeHttpRequest(allocator, request) catch |err| {
            req_result.error_message = try std.fmt.allocPrint(
                allocator,
                "HTTP request failed: {s}",
                .{@errorName(err)}
            );
            req_result.execution_time_ms = @intCast(std.time.milliTimestamp() - req_start);
            result.request_results[i] = req_result;
            all_passed = false;
            continue;
        };
        
        // Store response data
        req_result.status_code = response.status_code;
        req_result.response_body = try allocator.dupe(u8, response.body);
        
        // Copy headers
        var header_iter = response.headers.iterator();
        while (header_iter.next()) |entry| {
            try req_result.response_headers.put(
                try allocator.dupe(u8, entry.key_ptr.*),
                try allocator.dupe(u8, entry.value_ptr.*)
            );
        }
        
        // Check assertions
        const assertion_results = try checkAssertions(
            allocator, 
            request.assertions, 
            response
        );
        req_result.assertion_results = assertion_results;
        
        // Determine if this request passed
        req_result.success = true;
        for (assertion_results) |assertion_result| {
            if (!assertion_result.passed) {
                req_result.success = false;
                all_passed = false;
                break;
            }
        }
        
        req_result.execution_time_ms = @intCast(std.time.milliTimestamp() - req_start);
        result.request_results[i] = req_result;
    }
    
    result.success = all_passed;
    result.execution_time_ms = @intCast(std.time.milliTimestamp() - start_time);
    
    return result;
}
```

### Abstraction Layers for Platform Differences

Some operations need different implementations but can share interfaces:

```zig
// Logging abstraction - different implementations for CLI vs WASM
pub const Logger = struct {
    logFn: *const fn(level: LogLevel, message: []const u8) void,
    
    pub const LogLevel = enum { info, warn, err };
    
    pub fn init(logFn: *const fn(LogLevel, []const u8) void) Logger {
        return .{ .logFn = logFn };
    }
    
    pub fn info(self: Logger, message: []const u8) void {
        self.logFn(.info, message);
    }
    
    pub fn warn(self: Logger, message: []const u8) void {
        self.logFn(.warn, message);
    }
    
    pub fn err(self: Logger, message: []const u8) void {
        self.logFn(.err, message);
    }
};

// CLI implementation (in main.zig)
fn cliLogger(level: Logger.LogLevel, message: []const u8) void {
    const stdout = std.io.getStdOut().writer();
    switch (level) {
        .info => stdout.print("ℹ️  {s}\n", .{message}) catch {},
        .warn => stdout.print("⚠️  {s}\n", .{message}) catch {},
        .err => stdout.print("❌ {s}\n", .{message}) catch {},
    }
}

// WASM implementation (in wasm.zig)
fn wasmLogger(level: Logger.LogLevel, message: []const u8) void {
    switch (level) {
        .info => consoleLog(message.ptr, message.len),
        .warn => consoleLog(message.ptr, message.len), // Could use consoleWarn if available
        .err => consoleError(message.ptr, message.len),
    }
}
```

### Handling HTTP Differences

Even though Zig's HTTP client works in WASM, the response handling needs to be abstracted:

```zig
// Platform-agnostic HTTP response structure
pub const HttpResponse = struct {
    status_code: u16,
    headers: std.StringHashMap([]const u8),
    body: []const u8,
    
    pub fn deinit(self: *HttpResponse, allocator: std.mem.Allocator) void {
        var header_iter = self.headers.iterator();
        while (header_iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.headers.deinit();
        allocator.free(self.body);
    }
};

// In the actual implementation, HTTP requests are handled entirely by JavaScript
// The WASM module only converts parsed requests to JSON format for JavaScript to execute
```

### The CLI Adapter

Now the CLI version becomes a thin wrapper around the core module:

```zig
// src/main.zig - CLI version using the core module
const std = @import("std");
const core = @import("core.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    
    if (args.len < 2) {
        std.debug.print("Usage: httpspec <file_or_directory>\n", .{});
        return;
    }
    
    const target_path = args[1];
    
    // Read file content
    const file = try std.fs.cwd().openFile(target_path, .{});
    defer file.close();
    
    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(content);
    
    // Use the shared core logic
    var result = try core.executeHttpSpecFromString(allocator, content, target_path);
    defer result.deinit(allocator);
    
    // Display results using CLI formatting
    displayResults(result);
}

fn displayResults(result: core.TestResult) void {
    const stdout = std.io.getStdOut().writer();
    
    if (result.success) {
        stdout.print("✅ All tests passed ({d} requests in {d}ms)\n", 
                    .{result.request_count, result.execution_time_ms}) catch {};
    } else {
        stdout.print("❌ Some tests failed\n", .{}) catch {};
    }
    
    for (result.request_results) |req_result| {
        if (req_result.success) {
            stdout.print("  ✓ {s} {s}\n", .{req_result.method, req_result.url}) catch {};
        } else {
            stdout.print("  ✗ {s} {s}\n", .{req_result.method, req_result.url}) catch {};
            if (req_result.error_message) |msg| {
                stdout.print("    Error: {s}\n", .{msg}) catch {};
            }
        }
    }
}
```

This design completely separates the platform-specific I/O and presentation logic from the core HTTPSpec functionality. The same parsing, execution, and assertion checking logic works identically in both CLI and WASM environments.

## Step 3: Design the WASM Interface

WASM works best with a simple, focused interface. The key insight is that WASM should do what it's best at—parsing and data transformation—while leaving the complex UI interactions and HTTP requests to JavaScript.

### Understanding WASM's Constraints

Before designing the interface, it's crucial to understand WASM's limitations:

**Memory Model**: WASM has linear memory that's shared with JavaScript. All data exchange happens through this shared memory, using pointers and lengths.

**Type System**: WASM only supports basic numeric types (i32, i64, f32, f64). Strings, arrays, and complex objects must be serialized.

**Function Calls**: Only simple function signatures work reliably. Complex parameter passing requires careful memory management.

**No Garbage Collection**: Unlike JavaScript, WASM doesn't automatically manage memory. Every allocation needs explicit cleanup.

### Designing for Simplicity

Instead of trying to expose the full `TestResult` structure across the WASM boundary, I opted for a simpler approach: WASM parses the HTTPSpec content and returns JSON, which JavaScript can easily consume.

```zig
// src/wasm.zig
const std = @import("std");
const HttpParser = @import("./httpfile/parser.zig");

// Use page allocator - it's most reliable in WASM
const allocator = std.heap.page_allocator;

// External JavaScript functions we can call from WASM
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
        const error_json = std.fmt.bufPrint(&result_buffer, 
            \\{{"success": false, "error": "Parse failed: {s}", "requests": []}}
        , .{@errorName(err)}) catch "{{\"success\": false, \"error\": \"JSON format error\", \"requests\": []}}";
        
        result_len = error_json.len;
        return &result_buffer;
    };
    
    const owned_items = items.toOwnedSlice() catch |err| {
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
    
    // Convert parsed requests to JSON for JavaScript to execute
    const json = formatRequestsAsJson(owned_items) catch "{{\"success\": false, \"error\": \"JSON format error\", \"requests\": []}}";
    result_len = json.len;
    
    return &result_buffer;
}

/// Returns the length of the last result
export fn getResultLength() usize {
    return result_len;
}

/// Test function to verify WASM is working
export fn testWasm() i32 {
    consoleLog("WASM module loaded successfully!", 30);
    return 42;
}
```

### JSON Serialization Strategy

The trickiest part is converting Zig data structures to JSON that JavaScript can parse. HTTPSpec content includes user input that might contain quotes, backslashes, and other characters that break JSON:

```zig
/// Escapes a string for safe JSON inclusion
fn escapeJsonString(input: []const u8, writer: anytype) !void {
    for (input) |char| {
        switch (char) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            '\b' => try writer.writeAll("\\b"),
            '\f' => try writer.writeAll("\\f"),
            // Handle control characters
            0...31 => try writer.print("\\u{:0>4x}", .{char}),
            else => try writer.writeByte(char),
        }
    }
}

fn formatRequestsAsJson(requests: []const HttpParser.HttpRequest) ![]const u8 {
    var json_buffer = std.ArrayList(u8).init(allocator);
    defer json_buffer.deinit();
    
    try json_buffer.appendSlice("{\"success\": true, \"requests\": [");
    
    for (requests, 0..) |request, i| {
        if (i > 0) try json_buffer.appendSlice(", ");
        
        try json_buffer.appendSlice("{");
        
        // Method
        const method_name = if (request.method) |m| @tagName(m) else "GET";
        try json_buffer.appendSlice("\"method\": \"");
        try json_buffer.appendSlice(method_name);
        try json_buffer.appendSlice("\", ");
        
        // URL
        try json_buffer.appendSlice("\"url\": \"");
        const escaped_url = try escapeJsonString(allocator, request.url);
        defer allocator.free(escaped_url);
        try json_buffer.appendSlice(escaped_url);
        try json_buffer.appendSlice("\", ");
        
        // Headers
        try json_buffer.appendSlice("\"headers\": {");
        for (request.headers.items, 0..) |header, j| {
            if (j > 0) try json_buffer.appendSlice(", ");
            try json_buffer.appendSlice("\"");
            const escaped_header_name = try escapeJsonString(allocator, header.name);
            defer allocator.free(escaped_header_name);
            try json_buffer.appendSlice(escaped_header_name);
            try json_buffer.appendSlice("\": \"");
            const escaped_header_value = try escapeJsonString(allocator, header.value);
            defer allocator.free(escaped_header_value);
            try json_buffer.appendSlice(escaped_header_value);
            try json_buffer.appendSlice("\"");
        }
        try json_buffer.appendSlice("}, ");
        
        // Body
        try json_buffer.appendSlice("\"body\": ");
        if (request.body) |body| {
            try json_buffer.appendSlice("\"");
            const escaped_body = try escapeJsonString(allocator, body);
            defer allocator.free(escaped_body);
            try json_buffer.appendSlice(escaped_body);
            try json_buffer.appendSlice("\"");
        } else {
            try json_buffer.appendSlice("null");
        }
        try json_buffer.appendSlice(", ");
        
        // Assertions (simplified format based on actual parser)
        try json_buffer.appendSlice("\"assertions\": [");
        for (request.assertions.items, 0..) |assertion, k| {
            if (k > 0) try json_buffer.appendSlice(", ");
            try json_buffer.appendSlice("{\"key\": \"");
            const escaped_key = try escapeJsonString(allocator, assertion.key);
            defer allocator.free(escaped_key);
            try json_buffer.appendSlice(escaped_key);
            try json_buffer.appendSlice("\", \"value\": \"");
            const escaped_value = try escapeJsonString(allocator, assertion.value);
            defer allocator.free(escaped_value);
            try json_buffer.appendSlice(escaped_value);
            try json_buffer.appendSlice("\", \"type\": \"");
            try json_buffer.appendSlice(@tagName(assertion.assertion_type));
            try json_buffer.appendSlice("\"}");
        }
        try json_buffer.appendSlice("]");
        
        try json_buffer.appendSlice("}");
    }
    
    try json_buffer.appendSlice("]}");
    
    // Copy to result buffer
    const json_str = json_buffer.items;
    if (json_str.len >= result_buffer.len) {
        return std.fmt.bufPrint(&result_buffer, "{{\"success\": false, \"error\": \"JSON too large ({d} bytes), buffer size {d}\", \"requests\": []}}", .{ json_str.len, result_buffer.len });
    }
    
    @memcpy(result_buffer[0..json_str.len], json_str);
    return result_buffer[0..json_str.len];
}
```

### Error Handling Strategy

In WASM, error handling is more constrained than in native code. You can't easily propagate complex error types across the boundary. Instead, I use a defensive approach:

```zig
/// Wrapper that catches all errors and converts them to JSON error responses
fn safeParseHttpSpec(content: []const u8) []const u8 {
    return parseHttpSpecInner(content) catch |err| {
        // Log the actual error for debugging
        const error_msg = std.fmt.bufPrint(
            &result_buffer[32000..], // Use end of buffer for temp message
            "Internal error: {s}",
            .{@errorName(err)}
        ) catch "Unknown internal error";
        consoleError(error_msg.ptr, error_msg.len);
        
        // Return a safe JSON error
        const json_error = std.fmt.bufPrint(&result_buffer,
            \\{{"success": false, "error": "Internal processing error", "requests": []}}
        , .{}) catch 
            \\{{"success": false, "error": "Critical error", "requests": []}}
        ;
        
        result_len = json_error.len;
        return json_error;
    };
}

fn parseHttpSpecInner(content: []const u8) ![]const u8 {
    // The actual parsing logic that can throw errors
    // ...
}
```

### Memory Management Considerations

WASM memory management requires careful attention. I use several strategies:

**Static Buffers**: For the result buffer, I use a compile-time allocated array. This avoids dynamic allocation issues but limits response size.

**Allocator Choice**: The page allocator is most reliable in WASM, even though it's less efficient than other allocators.

**Cleanup Strategy**: Since JavaScript will immediately copy the JSON result, I don't need to worry about lifetime management across the boundary.

```zig
// Memory usage pattern that works well in WASM
var temp_buffer: [4096]u8 = undefined; // For temporary operations
var result_buffer: [65536]u8 = undefined; // For final JSON result

fn processWithBoundedMemory(input: []const u8) ![]const u8 {
    // Use stack-allocated buffers where possible
    var local_buffer: [1024]u8 = undefined;
    
    // Only use the allocator for complex data structures
    var parsed_data = try allocator.alloc(SomeStruct, input.len / 100);
    defer allocator.free(parsed_data);
    
    // Process and write to result_buffer
    // ...
    
    return result_buffer[0..actual_length];
}
```

### Testing the WASM Interface

Before moving to JavaScript integration, it's crucial to test the WASM interface:

```zig
// Test function that can be called from JavaScript console
export fn testBasicParsing() [*]const u8 {
    const test_content = 
        \\### Test request
        \\GET https://httpbin.org/get
        \\
        \\//# status == 200
    ;
    
    return parseHttpSpec(test_content.ptr, test_content.len);
}

export fn testComplexContent() [*]const u8 {
    const test_content = 
        \\### Test with quotes and escapes
        \\POST https://httpbin.org/post
        \\Content-Type: application/json
        \\
        \\{"message": "Hello \"world\"", "data": "line1\nline2"}
        \\
        \\//# status == 200
        \\//# header["content-type"] contains "json"
        \\//# body contains "Hello"
    ;
    
    return parseHttpSpec(test_content.ptr, test_content.len);
}
```

This interface design prioritizes simplicity and reliability over performance or feature completeness. The WASM module does one thing well: parse HTTPSpec content and return structured JSON data that JavaScript can easily work with.

## Step 4: Handle the JSON Escaping Problem

One of the most challenging aspects of the WASM integration turned out to be properly handling user input that contains characters which break JSON syntax. This isn't immediately obvious—until your application crashes because someone included quotes in their HTTP headers.

### The Scope of the Problem

HTTPSpec syntax includes several places where JSON-breaking characters commonly appear:

```http
### Test with problematic characters
POST https://api.example.com/users
Content-Type: application/json
Authorization: Bearer "my-token-with-quotes"

{
  "message": "Hello \"world\"",
  "data": "line1\nline2\ttab",
  "path": "C:\\Windows\\System32"
}

//# header["content-type"] == "application/json"
//# body contains "Hello \"world\""
//# body contains "C:\\Windows"
```

Every one of these elements can break JSON if not properly escaped:
- Header names and values with quotes
- Request bodies with embedded JSON
- Assertion targets with bracket notation
- Expected values with quotes and backslashes

### The Naive Approach (That Doesn't Work)

My first attempt was simple string replacement:

```zig
// This approach is broken and dangerous
fn badEscapeString(input: []const u8, buffer: []u8) ![]const u8 {
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();
    
    // This misses many edge cases and can double-escape
    const with_quotes = try std.mem.replaceOwned(u8, allocator, input, "\"", "\\\"");
    defer allocator.free(with_quotes);
    
    const with_backslashes = try std.mem.replaceOwned(u8, allocator, with_quotes, "\\", "\\\\");
    defer allocator.free(with_backslashes);
    
    return with_backslashes; // This is already freed!
}
```

This approach has multiple problems:
1. **Order matters**: Escaping backslashes after quotes can double-escape already-escaped quotes
2. **Unicode issues**: Doesn't handle control characters or non-ASCII text properly  
3. **Memory management**: Complex allocation patterns prone to leaks
4. **Incomplete**: Missing many JSON escape sequences

### The Robust Solution

The correct approach is to process the string character by character, handling each case explicitly:

```zig
/// Escapes a string for safe JSON inclusion
/// Returns the number of bytes written to the output buffer
fn escapeJsonString(input: []const u8, output_buffer: []u8) !usize {
    var output_pos: usize = 0;
    
    for (input) |char| {
        // Ensure we don't overflow the output buffer
        const bytes_needed = switch (char) {
            '"', '\\', '/', '\b', '\f', '\n', '\r', '\t' => 2,
            0...31 => 6, // \uXXXX format
            else => 1,
        };
        
        if (output_pos + bytes_needed > output_buffer.len) {
            return error.BufferTooSmall;
        }
        
        switch (char) {
            '"' => {
                output_buffer[output_pos] = '\\';
                output_buffer[output_pos + 1] = '"';
                output_pos += 2;
            },
            '\\' => {
                output_buffer[output_pos] = '\\';
                output_buffer[output_pos + 1] = '\\';
                output_pos += 2;
            },
            '/' => {
                // Forward slash can be escaped but doesn't have to be
                output_buffer[output_pos] = '\\';
                output_buffer[output_pos + 1] = '/';
                output_pos += 2;
            },
            '\b' => {
                output_buffer[output_pos] = '\\';
                output_buffer[output_pos + 1] = 'b';
                output_pos += 2;
            },
            '\f' => {
                output_buffer[output_pos] = '\\';
                output_buffer[output_pos + 1] = 'f';
                output_pos += 2;
            },
            '\n' => {
                output_buffer[output_pos] = '\\';
                output_buffer[output_pos + 1] = 'n';
                output_pos += 2;
            },
            '\r' => {
                output_buffer[output_pos] = '\\';
                output_buffer[output_pos + 1] = 'r';
                output_pos += 2;
            },
            '\t' => {
                output_buffer[output_pos] = '\\';
                output_buffer[output_pos + 1] = 't';
                output_pos += 2;
            },
            // Handle control characters with Unicode escape sequences
            0...31 => {
                const escaped = std.fmt.bufPrint(
                    output_buffer[output_pos..output_pos + 6],
                    "\\u{:0>4x}",
                    .{char}
                ) catch return error.BufferTooSmall;
                output_pos += escaped.len;
            },
            // Regular characters pass through unchanged
            else => {
                output_buffer[output_pos] = char;
                output_pos += 1;
            },
        }
    }
    
    return output_pos;
}
```

### Integration with JSON Generation

The escaping function needs to integrate cleanly with the JSON generation logic. I use a writer-based approach for efficiency:

```zig
fn writeEscapedJsonString(input: []const u8, writer: anytype) !void {
    // Use a reasonably sized buffer for escaping
    var escape_buffer: [2048]u8 = undefined;
    
    // Handle strings longer than our buffer by processing in chunks
    var remaining = input;
    while (remaining.len > 0) {
        // Process as much as fits in our buffer when escaped
        // Worst case: every character needs 6 bytes (Unicode escape)
        const chunk_size = @min(remaining.len, escape_buffer.len / 6);
        const chunk = remaining[0..chunk_size];
        
        const escaped_len = try escapeJsonString(chunk, &escape_buffer);
        try writer.writeAll(escape_buffer[0..escaped_len]);
        
        remaining = remaining[chunk_size..];
    }
}

fn formatRequestsAsJson(requests: []const HttpParser.HttpRequest) ![]const u8 {
    var stream = std.io.fixedBufferStream(&result_buffer);
    var writer = stream.writer();
    
    try writer.writeAll("{\"success\": true, \"requests\": [");
    
    for (requests, 0..) |request, i| {
        if (i > 0) try writer.writeAll(", ");
        
        try writer.writeAll("{\"method\": \"");
        try writer.writeAll(@tagName(request.method));
        try writer.writeAll("\", \"url\": \"");
        try writeEscapedJsonString(request.url, writer);
        try writer.writeAll("\", \"headers\": {");
        
        // Headers are particularly tricky because both keys and values need escaping
        for (request.headers.items, 0..) |header, header_idx| {
            if (header_idx > 0) try writer.writeAll(", ");
            try writer.writeAll("\"");
            try writeEscapedJsonString(header.name, writer);
            try writer.writeAll("\": \"");
            try writeEscapedJsonString(header.value, writer);
            try writer.writeAll("\"");
        }
        
        try writer.writeAll("}, \"body\": ");
        if (request.body) |body| {
            try writer.writeAll("\"");
            try writeEscapedJsonString(body, writer);
            try writer.writeAll("\"");
        } else {
            try writer.writeAll("null");
        }
        
        // Assertions require special attention because they often contain quotes
        try writer.writeAll(", \"assertions\": [");
        for (request.assertions.items, 0..) |assertion, assertion_idx| {
            if (assertion_idx > 0) try writer.writeAll(", ");
            
            try writer.writeAll("{\"type\": \"");
            try writer.writeAll(@tagName(assertion.assertion_type));
            try writer.writeAll("\", \"target\": \"");
            try writeEscapedJsonString(assertion.target, writer);
            try writer.writeAll("\", \"operator\": \"");
            try writer.writeAll(@tagName(assertion.operator));
            try writer.writeAll("\", \"expected\": \"");
            try writeEscapedJsonString(assertion.expected_value, writer);
            try writer.writeAll("\"}");
        }
        try writer.writeAll("]}");
    }
    
    try writer.writeAll("]}");
    
    const bytes_written = stream.getWritten();
    return bytes_written;
}
```

### Testing Edge Cases

Proper JSON escaping requires thorough testing with edge cases that commonly appear in HTTP content:

```zig
// Test function for validating JSON escaping
export fn testJsonEscaping() [*]const u8 {
    const problematic_content = 
        \\### Test with all the problematic characters
        \\POST https://api.example.com/test
        \\Content-Type: application/json
        \\Authorization: Bearer "token-with-quotes"
        \\X-Custom: value with\ttabs and\nnewlines
        \\
        \\{"message": "Hello \"world\"", "path": "C:\\Windows\\System32", "data": "\u0001\u0002\u0003"}
        \\
        \\//# status == 200
        \\//# header["content-type"] == "application/json"
        \\//# body contains "Hello \"world\""
        \\//# body contains "C:\\Windows"
        \\//# body not_contains "\u0000"
    ;
    
    return parseHttpSpec(problematic_content.ptr, problematic_content.len);
}

// You can call this from the browser console to test:
// wasmModule.exports.testJsonEscaping()
// JSON.parse(getStringFromWasm(result_pointer, result_length))
```

### Debugging JSON Issues

When JSON parsing fails in JavaScript, it's often due to escaping issues. I added debugging helpers:

```zig
// Export a function that returns the raw JSON for debugging
export fn getLastResultAsString() [*]const u8 {
    return &result_buffer;
}

// Export a function that validates the JSON before returning it
fn validateJsonResult(json: []const u8) bool {
    // Simple validation: count braces and brackets
    var brace_count: i32 = 0;
    var bracket_count: i32 = 0;
    var in_string = false;
    var escape_next = false;
    
    for (json) |char| {
        if (escape_next) {
            escape_next = false;
            continue;
        }
        
        switch (char) {
            '\\' => if (in_string) escape_next = true,
            '"' => in_string = !in_string,
            '{' => if (!in_string) brace_count += 1,
            '}' => if (!in_string) brace_count -= 1,
            '[' => if (!in_string) bracket_count += 1,
            ']' => if (!in_string) bracket_count -= 1,
            else => {},
        }
    }
    
    return brace_count == 0 and bracket_count == 0 and !in_string;
}
```

Proper JSON escaping is critical for the WASM-JavaScript interface to work reliably. The investment in robust escaping logic pays off by preventing mysterious failures when users include quotes, backslashes, or control characters in their HTTPSpec files.

The actual WASM implementation focuses purely on parsing and JSON generation, with proper error handling and memory management suited for the WASM environment.
```

## Step 5: Update Your Build System

Add WASM compilation to your `build.zig`:

```zig
pub fn build(b: *std.Build) void {
    // ... existing CLI build code ...

    // Add WASM build target
    const wasm = b.addExecutable(.{
        .name = "httpspec",
        .root_source_file = b.path("src/wasm.zig"),
        .target = b.resolveTargetQuery(.{
            .cpu_arch = .wasm32,
            .os_tag = .freestanding,
        }),
        .optimize = optimize,
    });

    // Add dependencies to WASM build
    for (dependencies) |dependency| {
        const dep = b.dependency(dependency, .{});
        wasm.root_module.addImport(dependency, dep.module(dependency));
    }

    // Configure WASM-specific build options
    wasm.entry = .disabled;  // No main function
    wasm.rdynamic = true;    // Export symbols

    const wasm_step = b.step("wasm", "Build WebAssembly module");
    wasm_step.dependOn(&b.addInstallArtifact(wasm, .{
        .dest_dir = .{ .override = .{ .custom = "web" } },
    }).step);
}
```

Now you can build with: `zig build wasm`

## Step 6: Create the JavaScript Integration

The JavaScript side needs to load the WASM module and handle the communication:

```javascript
class HTTPSpecRunner {
    constructor() {
        this.wasmModule = null;
        this.wasmMemory = null;
        this.textEncoder = new TextEncoder();
        this.textDecoder = new TextDecoder();
        this.loadWasm();
    }

    async loadWasm() {
        const wasmModule = await WebAssembly.instantiateStreaming(
            fetch('./httpspec.wasm'),
            {
                env: {
                    consoleLog: (ptr, len) => {
                        const message = this.getStringFromWasm(ptr, len);
                        console.log('WASM Log:', message);
                    },
                    consoleError: (ptr, len) => {
                        const message = this.getStringFromWasm(ptr, len);
                        console.error('WASM Error:', message);
                    }
                }
            }
        );

        this.wasmModule = wasmModule.instance;
        this.wasmMemory = this.wasmModule.exports.memory;
    }

    getStringFromWasm(ptr, len) {
        const bytes = new Uint8Array(this.wasmMemory.buffer, ptr, len);
        return this.textDecoder.decode(bytes);
    }

    writeStringToWasm(str) {
        const bytes = this.textEncoder.encode(str);
        // Simple allocation strategy - in production you'd want proper memory management
        const currentSize = this.wasmMemory.buffer.byteLength;
        const needed = Math.ceil((currentSize + bytes.length) / 65536) * 65536;
        if (needed > currentSize) {
            this.wasmMemory.grow((needed - currentSize) / 65536);
        }
        
        const ptr = currentSize;
        const wasmBytes = new Uint8Array(this.wasmMemory.buffer, ptr, bytes.length);
        wasmBytes.set(bytes);
        return { ptr, len: bytes.length };
    }

    async runTests(content) {
        // Write content to WASM memory
        const { ptr, len } = this.writeStringToWasm(content);

        // Call WASM function
        const resultPtr = this.wasmModule.exports.parseHttpSpecToJson(ptr, len);
        const resultLen = this.wasmModule.exports.getResultLength();

        // Read JSON result
        const resultJson = this.getStringFromWasm(resultPtr, resultLen);
        const parseResult = JSON.parse(resultJson);

        // Execute HTTP requests using browser's fetch API
        const results = [];
        for (const request of parseResult.requests) {
            const result = await this.executeRequest(request);
            results.push(result);
        }

        return results;
    }

    async executeRequest(request) {
        try {
            const options = {
                method: request.method,
                headers: request.headers,
            };

            if (request.body && request.method !== 'GET') {
                options.body = request.body;
            }

            const response = await fetch(request.url, options);
            const responseText = await response.text();

            // Check assertions
            const assertionResults = [];
            let allPassed = true;

            for (const assertion of request.assertions) {
                const result = this.checkAssertion(assertion, response, responseText);
                assertionResults.push(result);
                if (!result.passed) allPassed = false;
            }

            return {
                success: allPassed,
                url: request.url,
                method: request.method,
                status: response.status,
                assertions: assertionResults
            };
        } catch (error) {
            return {
                success: false,
                url: request.url,
                error: error.message
            };
        }
    }
}
```

## Step 7: Handle the Division of Labor

One key insight is that you don't need to port everything to WASM. In our final implementation:

- **WASM handles**: Parsing HTTPSpec syntax into structured JSON (leverages existing Zig parser)
- **JavaScript handles**: HTTP requests using the browser's fetch API (handles CORS, timeouts, modern web standards)
- **JavaScript handles**: Assertion checking (implemented in JS for simplicity and web integration)
- **JavaScript handles**: UI interactions, result display, and user experience

This hybrid approach gives you the best of both worlds: the robust, battle-tested parsing logic from Zig and the web-native HTTP capabilities and UI flexibility from JavaScript. WASM does what it's best at (parsing and data transformation) while JavaScript handles everything that requires browser integration.

## Step 8: Create a Web Interface

Finally, create a simple HTML interface:

```html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>HTTPSpec Web Runner</title>
    <style>
        /* Clean, responsive styling */
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; }
        .container { max-width: 1200px; margin: 0 auto; padding: 20px; }
        .main-content { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; }
        #httpspec-editor { width: 100%; height: 400px; font-family: monospace; }
        .result-item { padding: 15px; margin: 10px 0; border-radius: 4px; }
        .result-item.success { background: #d5f4e6; border-left: 4px solid #27ae60; }
        .result-item.error { background: #fdf2f2; border-left: 4px solid #e74c3c; }
    </style>
</head>
<body>
    <div class="container">
        <h1>HTTPSpec Web Runner</h1>
        <div class="main-content">
            <div>
                <h3>HTTPSpec Editor</h3>
                <textarea id="httpspec-editor" placeholder="Enter your HTTPSpec content..."></textarea>
                <button id="run-tests">Run Tests</button>
            </div>
            <div>
                <h3>Results</h3>
                <div id="results"></div>
            </div>
        </div>
    </div>
    <script src="httpspec-runner.js"></script>
</body>
</html>
```

## Common Pitfalls and Solutions

Through the process of porting HTTPSpec to WASM, I encountered numerous subtle issues that can derail a project. Here are the most significant ones, with detailed explanations and solutions.

### 1. Memory Management Nightmares

**The Problem**: WASM memory management is fundamentally different from native applications. What works perfectly in your CLI tool can cause mysterious crashes in WASM.

**What Goes Wrong**: 

```zig
// This works fine in native code but causes issues in WASM
var gpa = std.heap.GeneralPurposeAllocator(.{
    .safety = true,
    .verbose_log = true,
}){};
const allocator = gpa.allocator();

// WASM doesn't handle the safety checks well
const data = try allocator.alloc(u8, large_size);
defer allocator.free(data); // May not work as expected
```

**The Solution**: Use the page allocator and change your allocation patterns:

```zig
// This works reliably in WASM
const allocator = std.heap.page_allocator;

// Prefer stack allocation where possible
var buffer: [4096]u8 = undefined;
const result = try processData(input, &buffer);

// For dynamic allocation, use simpler patterns
const data = try allocator.alloc(u8, size);
// Don't rely on defer in WASM - clean up explicitly
defer allocator.free(data);

// Better: use fixed-size buffers and avoid dynamic allocation
var fixed_buffer: [65536]u8 = undefined;
const result = try processIntoBuffer(input, &fixed_buffer);
```

**Why This Happens**: WASM's linear memory model doesn't support all the debugging and safety features that work in native code. The general-purpose allocator's safety checks can interfere with WASM's memory management.

### 2. String Encoding Hell

**The Problem**: JavaScript uses UTF-16 internally, while Zig strings are UTF-8. The boundary between WASM and JavaScript becomes a minefield of encoding issues.

**What Goes Wrong**:

```javascript
// This breaks with non-ASCII characters
const wasmString = "Hello 世界";
const bytes = new TextEncoder().encode(wasmString);
const ptr = writeToWasm(bytes);
// WASM receives corrupted data for Unicode characters
```

**The Solution**: Implement robust encoding/decoding helpers:

```javascript
class WasmStringInterface {
    constructor(wasmModule) {
        this.wasmModule = wasmModule;
        this.textEncoder = new TextEncoder();
        this.textDecoder = new TextDecoder('utf-8', { fatal: true });
    }
    
    // Safely write string to WASM memory
    writeString(str) {
        try {
            const bytes = this.textEncoder.encode(str);
            
            // Allocate WASM memory (simplified - you'd want proper allocation)
            const ptr = this.wasmModule.exports.allocate(bytes.length);
            const wasmMemory = new Uint8Array(
                this.wasmModule.exports.memory.buffer, 
                ptr, 
                bytes.length
            );
            wasmMemory.set(bytes);
            
            return { ptr, len: bytes.length };
        } catch (error) {
            console.error('String encoding failed:', error);
            throw new Error(`Failed to encode string: ${error.message}`);
        }
    }
    
    // Safely read string from WASM memory  
    readString(ptr, len) {
        try {
            const bytes = new Uint8Array(
                this.wasmModule.exports.memory.buffer, 
                ptr, 
                len
            );
            return this.textDecoder.decode(bytes);
        } catch (error) {
            console.error('String decoding failed:', error);
            // Return a safe fallback instead of crashing
            return '[ENCODING ERROR]';
        }
    }
    
    // Test with problematic strings
    testEncoding() {
        const testStrings = [
            "Simple ASCII",
            "Unicode: 世界 🌍 🚀",
            "Quotes: \"Hello\" and 'World'",
            "Control chars: \n\t\r",
            "Null bytes: \x00\x01\x02"
        ];
        
        for (const str of testStrings) {
            try {
                const { ptr, len } = this.writeString(str);
                const recovered = this.readString(ptr, len);
                console.log(`Original: ${str}`);
                console.log(`Recovered: ${recovered}`);
                console.log(`Match: ${str === recovered}\n`);
            } catch (error) {
                console.error(`Failed with string: ${str}`, error);
            }
        }
    }
}
```

### 3. WASM Compilation Target Confusion

**The Problem**: Zig has multiple WASM targets, and choosing the wrong one causes subtle failures.

**What Goes Wrong**:

```zig
// In build.zig - this might not work as expected
const wasm = b.addExecutable(.{
    .name = "httpspec",
    .root_source_file = b.path("src/wasm.zig"),
    .target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi, // WRONG for browser WASM
    }),
    .optimize = .ReleaseFast,
});
```

**The Solution**: Use the correct target and build configuration:

```zig
// Correct WASM target for browsers
const wasm = b.addExecutable(.{
    .name = "httpspec",
    .root_source_file = b.path("src/wasm.zig"),
    .target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding, // Correct for browser WASM
    }),
    .optimize = .ReleaseFast,
});

// Essential WASM-specific configuration
wasm.entry = .disabled; // No main function in WASM modules
wasm.rdynamic = true;    // Export all symbols marked with 'export'

// Strip debug info for smaller file size
wasm.strip = true;

// Don't link libc (not available in WASM)
wasm.linkLibC = false;
```

### 4. HTTP Request Timing Issues

**The Problem**: WASM doesn't handle HTTP request timeouts the same way as native code, leading to hanging requests.

**What Goes Wrong**:

```zig
// This might hang indefinitely in WASM
var client = std.http.Client{ .allocator = allocator };
const response = try client.fetch(.{
    .location = .{ .url = "https://slow-api.example.com/endpoint" },
    .method = .GET,
    // No timeout specified - can hang forever
});
```

**The Solution**: Implement timeouts and fallback strategies:

```javascript
// JavaScript side - wrap requests with timeouts
class HttpClient {
    constructor(timeoutMs = 10000) {
        this.timeoutMs = timeoutMs;
    }
    
    async fetchWithTimeout(url, options = {}) {
        const controller = new AbortController();
        const timeoutId = setTimeout(() => controller.abort(), this.timeoutMs);
        
        try {
            const response = await fetch(url, {
                ...options,
                signal: controller.signal
            });
            clearTimeout(timeoutId);
            return response;
        } catch (error) {
            clearTimeout(timeoutId);
            if (error.name === 'AbortError') {
                throw new Error(`Request timeout after ${this.timeoutMs}ms`);
            }
            throw error;
        }
    }
    
    // Execute request with retry logic
    async executeWithRetry(request, maxRetries = 3) {
        let lastError;
        
        for (let attempt = 1; attempt <= maxRetries; attempt++) {
            try {
                console.log(`Attempting request (${attempt}/${maxRetries}): ${request.url}`);
                
                const response = await this.fetchWithTimeout(request.url, {
                    method: request.method,
                    headers: request.headers,
                    body: request.body
                });
                
                return {
                    success: true,
                    status: response.status,
                    headers: Object.fromEntries(response.headers.entries()),
                    body: await response.text()
                };
                
            } catch (error) {
                lastError = error;
                console.warn(`Request attempt ${attempt} failed:`, error.message);
                
                if (attempt < maxRetries) {
                    // Exponential backoff
                    const delay = Math.min(1000 * Math.pow(2, attempt - 1), 5000);
                    await new Promise(resolve => setTimeout(resolve, delay));
                }
            }
        }
        
        return {
            success: false,
            error: `All ${maxRetries} attempts failed. Last error: ${lastError.message}`
        };
    }
}
```

### 5. CORS Policy Nightmares

**The Problem**: Your WASM application can't make requests to arbitrary URLs due to browser CORS policies, but this limitation isn't obvious during development.

**The Solution**: Build CORS awareness into your application:

```javascript
class CorsAwareHttpClient {
    constructor() {
        this.corsProxyUrl = null; // Optional CORS proxy
        this.knownCorsIssues = new Set();
    }
    
    async makeRequest(url, options) {
        try {
            // Try the direct request first
            return await this.attemptDirectRequest(url, options);
        } catch (error) {
            if (this.isCorsError(error)) {
                return await this.handleCorsError(url, options, error);
            }
            throw error;
        }
    }
    
    async attemptDirectRequest(url, options) {
        const response = await fetch(url, options);
        return await this.processResponse(response);
    }
    
    isCorsError(error) {
        // CORS errors can be tricky to detect
        return error.message.includes('CORS') ||
               error.message.includes('cross-origin') ||
               error.name === 'TypeError' && 
               error.message.includes('Failed to fetch');
    }
    
    async handleCorsError(url, options, originalError) {
        this.knownCorsIssues.add(new URL(url).origin);
        
        // Try CORS proxy if configured
        if (this.corsProxyUrl) {
            try {
                const proxiedUrl = `${this.corsProxyUrl}/${url}`;
                console.warn(`CORS blocked, trying proxy: ${proxiedUrl}`);
                return await this.attemptDirectRequest(proxiedUrl, options);
            } catch (proxyError) {
                console.error('Proxy request also failed:', proxyError);
            }
        }
        
        // Return a helpful error message
        return {
            success: false,
            error: `CORS policy blocked request to ${url}. ` +
                  `This is a browser security restriction. ` +
                  `Try: 1) Use a CORS proxy, 2) Configure the server to allow cross-origin requests, ` +
                  `or 3) Test with same-origin requests.`,
            corsBlocked: true,
            suggestions: this.getCorsWorkarounds(url)
        };
    }
    
    getCorsWorkarounds(url) {
        const domain = new URL(url).hostname;
        return [
            `Configure ${domain} to send proper CORS headers`,
            `Use a CORS proxy service`,
            `Run your web app from the same domain as ${domain}`,
            `Use browser extensions that disable CORS (development only)`
        ];
    }
    
    // Display CORS issues in the UI
    displayCorsReport() {
        if (this.knownCorsIssues.size > 0) {
            console.warn('CORS issues detected with these domains:');
            for (const domain of this.knownCorsIssues) {
                console.warn(`- ${domain}`);
            }
        }
    }
}
```

### 6. Debugging WASM Issues

**The Problem**: When something goes wrong in WASM, error messages are often cryptic or missing entirely.

**The Solution**: Build comprehensive debugging infrastructure:

```zig
// Enhanced debugging for WASM
const DEBUG_ENABLED = true;

fn debugLog(comptime fmt: []const u8, args: anytype) void {
    if (!DEBUG_ENABLED) return;
    
    var buffer: [1024]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, fmt, args) catch {
        consoleError("Debug message too long".ptr, "Debug message too long".len);
        return;
    };
    consoleLog(message.ptr, message.len);
}

// Enhanced error reporting
fn reportError(comptime context: []const u8, err: anyerror, details: []const u8) void {
    var buffer: [2048]u8 = undefined;
    const error_msg = std.fmt.bufPrint(&buffer, 
        "ERROR in {s}: {s} - Details: {s}", 
        .{ context, @errorName(err), details }
    ) catch {
        consoleError("Error message formatting failed".ptr, "Error message formatting failed".len);
        return;
    };
    consoleError(error_msg.ptr, error_msg.len);
}

// Memory usage tracking
var allocation_count: usize = 0;
var total_allocated: usize = 0;

fn trackingAlloc(size: usize) ![]u8 {
    const result = allocator.alloc(u8, size) catch |err| {
        reportError("trackingAlloc", err, "Failed to allocate memory");
        return err;
    };
    
    allocation_count += 1;
    total_allocated += size;
    
    debugLog("Allocated {d} bytes (total: {d} bytes, count: {d})", 
            .{ size, total_allocated, allocation_count });
    
    return result;
}

export fn getMemoryStats() i32 {
    debugLog("Memory stats - Allocations: {d}, Total: {d} bytes", 
            .{ allocation_count, total_allocated });
    return @intCast(allocation_count);
}
```

### 7. Build System Gotchas

**The Problem**: The Zig build system for WASM has several non-obvious requirements that can cause builds to fail silently or produce non-working modules.

**The Solution**: A complete, tested build configuration:

```zig
// Complete build.zig for WASM
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    
    // CLI version (existing)
    const exe = b.addExecutable(.{
        .name = "httpspec",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    // Add dependencies for CLI version
    const clap_dep = b.dependency("clap", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("clap", clap_dep.module("clap"));
    
    b.installArtifact(exe);
    
    // WASM version - separate target
    const wasm = b.addExecutable(.{
        .name = "httpspec",
        .root_source_file = b.path("src/wasm.zig"),
        .target = b.resolveTargetQuery(.{
            .cpu_arch = .wasm32,
            .os_tag = .freestanding,
        }),
        .optimize = optimize,
    });
    
    // Critical WASM-specific settings
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    wasm.strip = optimize != .Debug;
    
    // Don't add CLI dependencies to WASM
    // wasm.root_module.addImport("clap", clap_dep.module("clap")); // DON'T DO THIS
    
    // Install WASM to custom directory
    const wasm_step = b.step("wasm", "Build WebAssembly module");
    wasm_step.dependOn(&b.addInstallArtifact(wasm, .{
        .dest_dir = .{ .override = .{ .custom = "web" } },
    }).step);
    
    // Add a step to run a local server for testing
    const serve_cmd = b.addSystemCommand(&[_][]const u8{
        "python3", "-m", "http.server", "8000"
    });
    serve_cmd.cwd = b.path("web");
    
    const serve_step = b.step("serve", "Serve the web interface locally");
    serve_step.dependOn(wasm_step);
    serve_step.dependOn(&serve_cmd.step);
    
    // Add tests
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/core.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
```

These pitfalls represent hours of debugging and experimentation. Each one taught me something important about the differences between native and WASM environments. The key insight is that WASM isn't just a different compilation target—it's a fundamentally different runtime environment that requires careful consideration of memory management, I/O patterns, and error handling.

## Building and Testing

```bash
# Build WASM module
zig build wasm

# Copy to web directory
cp zig-out/web/httpspec.wasm web/

# Serve locally (required for WASM loading)
cd web && python3 -m http.server 8000

# Open http://localhost:8000
```

## Conclusion

After working through the entire process of porting HTTPSpec from a CLI tool to a web application using WebAssembly, I've learned that successful WASM integration is less about technical wizardry and more about understanding the fundamental differences between runtime environments.

### The Key Insights

**WASM isn't a magic bullet**. It's not going to make your existing code "just work" in the browser. Instead, it's a tool for bridging two different worlds—native performance and web accessibility—each with their own strengths and constraints.

The most important lesson I learned is that **WASM works best as part of a hybrid architecture**. Don't try to port everything to WASM. Instead, identify the core value proposition of your application (in HTTPSpec's case, the parsing logic) and move that to WASM while embracing web-native solutions for everything else.

### Architectural Principles That Work

**1. Design for Data, Not Resources**
Traditional CLI tools work with files, directories, and streams. WASM applications work with strings, arrays, and structured data. The shift from `processFile(path)` to `processContent(data)` isn't just a technical change—it's a fundamental architectural improvement that makes your code more testable and reusable.

**2. Embrace the Boundaries**
The JavaScript-WASM boundary might seem like a limitation, but it's actually a feature. It forces you to design clean interfaces with clear data contracts. The JSON serialization layer that initially felt cumbersome turned out to be one of the most valuable parts of the system—it's debuggable, language-agnostic, and self-documenting.

**3. Plan for Failure**
Native applications often fail fast and loudly. WASM applications need to fail gracefully and informatively. The investment in comprehensive error handling, logging, and debugging infrastructure pays dividends when something goes wrong in production.

### When WASM Makes Sense

Based on this experience, WASM is particularly valuable when you have:

- **Complex parsing or computation logic** that would be expensive to reimplement in JavaScript
- **Performance-critical algorithms** where JavaScript's overhead is measurable
- **Existing codebases** with substantial logic you want to reuse
- **Cross-platform requirements** where the same logic needs to run on CLI, web, and potentially other environments

WASM is less valuable when your application is primarily about I/O, UI manipulation, or integration with web APIs. For those use cases, JavaScript's ecosystem and browser integration are superior.

### Performance Considerations

The performance benefits of WASM aren't automatic. In HTTPSpec's case, the parsing logic is faster in WASM than equivalent JavaScript, but the overhead of JSON serialization and the JavaScript-WASM boundary means the overall performance gain is modest for small inputs.

However, the performance characteristics are more predictable. JavaScript's garbage collector can cause unpredictable pauses, while WASM's manual memory management provides consistent performance. For interactive applications where responsiveness matters more than raw throughput, this predictability is valuable.

### Development Experience Lessons

**Debugging is harder**: When something goes wrong in WASM, you often get less information than you would in native code or JavaScript. Invest early in logging and debugging infrastructure.

**Build systems are complex**: Managing dual compilation targets, dependencies, and deployment artifacts adds significant complexity to your build process. Document everything and automate as much as possible.

**Testing requires more effort**: You need to test both the native and WASM versions, plus the integration between WASM and JavaScript. Don't assume that code working in one environment will work in the other.

### Looking Forward

The HTTPSpec web interface now provides capabilities that weren't possible with just the CLI tool:

- **Instant feedback**: Edit HTTPSpec content and see results immediately
- **Visual assertion checking**: Color-coded results show exactly which assertions passed or failed  
- **Shareable test cases**: Copy a URL to share a complete HTTPSpec test with colleagues
- **Browser developer tools integration**: Network tab shows actual HTTP requests, console shows detailed logging

These features emerged naturally from the hybrid architecture. WASM handles the parsing with the same reliability as the CLI tool, while JavaScript provides rich interactivity that would be impractical to implement in a terminal application.

### Practical Recommendations

If you're considering adding WASM support to your own CLI tool:

**Start small**: Pick one core function and get it working in WASM before attempting to port the entire application.

**Design the interface first**: Spend time thinking about how data flows between JavaScript and WASM. A well-designed interface makes everything else easier.

**Plan for debugging**: Add logging, error reporting, and diagnostic functions from the beginning. You'll need them.

**Test incrementally**: Don't wait until everything is "done" to test in the browser. Get basic functionality working and iterate.

**Document the differences**: Keep notes about what works differently between native and WASM versions. Future contributors (including yourself) will thank you.

### The Bigger Picture

WebAssembly represents a significant shift in how we think about web applications. Instead of choosing between native performance and web accessibility, we can increasingly have both. The HTTPSpec project demonstrates that with careful architecture and a hybrid approach, you can bring the reliability and performance of systems programming languages to the web without sacrificing the things that make web applications great.

The future of web development isn't about replacing JavaScript with WASM—it's about using each technology for what it does best. WASM handles the computationally intensive, algorithmically complex, or performance-critical parts of your application, while JavaScript manages the UI, integrates with web APIs, and provides the developer experience that makes the web platform so productive.

HTTPSpec's journey from CLI tool to web application shows that this future is already here. The combination of Zig's type safety and performance with JavaScript's ecosystem and browser integration creates possibilities that neither technology could achieve alone.