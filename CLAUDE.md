# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

HTTPSpec is a command-line tool written in Zig that extends HTTP files with assertions for integration testing. It parses `.http` or `.httpspec` files, executes HTTP requests sequentially, and validates responses against user-defined assertions.

## Key Commands

- **Build**: `zig build`
- **Run**: `zig build run -- [file_or_directory]`
- **Test**: `zig build test`
- **Install**: `zig build install`

## Architecture

### Core Components

- **`src/main.zig`**: Entry point with CLI parsing, file discovery, and parallel test execution using thread pools
- **`src/httpfile/parser.zig`**: Parses `.http`/`.httpspec` files into structured HttpRequest objects with assertions
- **`src/httpfile/http_client.zig`**: HTTP client for executing requests and capturing responses
- **`src/httpfile/assertion_checker.zig`**: Validates responses against assertions (status codes, headers, body content)
- **`src/reporters/test_reporter.zig`**: Test result reporting and statistics

### File Format

HTTPSpec extends standard `.http` files with assertion syntax:
```
### Request name
GET https://example.com/api/endpoint
Header: value

//# status == 200
//# header["content-type"] == "application/json"
//# body contains "expected"
```

### Assertion Types
- **Status**: `status == 200`, `status != 404`
- **Headers**: `header["content-type"] == "application/json"`
- **Body**: `body == "exact match"`, `body contains "substring"`
- **Not equals**: Uses `!=` or `not_contains` operators

### Configuration

- **Threading**: Set `HTTP_THREAD_COUNT` environment variable to control parallel execution
- **File Discovery**: Recursively finds `.http`/`.httpspec` files when no specific files are provided

### Dependencies

- **clap**: Command-line argument parsing (defined in `build.zig.zon`)

## Testing Strategy

The build system automatically discovers and tests all `.zig` files in the `src/` directory. Tests are run in parallel for better performance.