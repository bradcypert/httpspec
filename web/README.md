# HTTPSpec Web Runner

A web-based interface for running HTTPSpec tests directly in your browser using WebAssembly.

## Quick Start

1. **Build the WebAssembly module:**
   ```bash
   zig build wasm
   cp zig-out/web/httpspec.wasm web/
   ```

2. **Serve the web files:**
   Since the browser needs to load the WASM file, you need to serve the files over HTTP (not file://).
   
   **Option A: Using Python (recommended for local testing):**
   ```bash
   cd web
   python3 -m http.server 8000
   ```
   
   **Option B: Using Node.js:**
   ```bash
   cd web
   npx serve .
   ```
   
   **Option C: Using any other static file server**

3. **Open in browser:**
   Navigate to `http://localhost:8000` in your web browser.

## Features

- **HTTPSpec Syntax Support**: Full support for HTTPSpec syntax including all assertion types
- **Real-time Parsing**: Uses WebAssembly-compiled Zig parser for accurate syntax validation  
- **HTTP Execution**: Executes actual HTTP requests using the browser's fetch API
- **Assertion Checking**: Validates responses against your defined assertions
- **Example Templates**: Pre-loaded examples to get you started quickly

## Supported Assertions

- `status == 200` - Check response status code
- `header["content-type"] contains "json"` - Check response headers
- `body contains "expected text"` - Check response body content
- `body == "exact match"` - Exact body matching
- Support for `!=`, `not_contains`, `starts_with`, `ends_with` operators

## CORS Considerations

Since the web version runs in a browser, it's subject to CORS (Cross-Origin Resource Sharing) policies:

- ✅ **Same-origin requests** (same domain/port) work without issues
- ✅ **CORS-enabled APIs** that send proper headers work fine
- ✅ **Public APIs** like JSONPlaceholder work great for testing
- ❌ **CORS-restricted APIs** will be blocked by the browser

### Workarounds for CORS:
1. Test against CORS-enabled APIs
2. Use browser flags to disable CORS (development only): `--disable-web-security`
3. Set up a local proxy server
4. Use the CLI version for unrestricted testing

## File Structure

```
web/
├── index.html           # Main web interface
├── httpspec-runner.js   # JavaScript WASM integration
├── httpspec.wasm       # Compiled WebAssembly module
└── README.md           # This file
```

## Development

To rebuild the WASM module after making changes to the Zig code:

```bash
zig build wasm
cp zig-out/web/httpspec.wasm web/
```

The web interface will automatically reload the WASM module on page refresh.