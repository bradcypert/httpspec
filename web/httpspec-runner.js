/**
 * Improved HTTPSpec Runner - Single Interface Approach
 *
 * This demonstrates a cleaner architecture where:
 * 1. WASM handles HTTPSpec parsing (single function call)
 * 2. JavaScript handles HTTP execution and assertion checking
 * 3. Single function call gives you complete end-to-end results
 *
 * The key improvement is that from the JavaScript perspective, there's
 * just one function call to get complete results, even though internally
 * it's a hybrid WASM+JS approach.
 */

class ImprovedHTTPSpecRunner {
  constructor() {
    this.wasmModule = null;
    this.wasmMemory = null;
    this.textEncoder = new TextEncoder();
    this.textDecoder = new TextDecoder();
    this.loadWasm();
  }

  async loadWasm() {
    try {
      console.log("Loading WASM module...");

      const wasmModule = await WebAssembly.instantiateStreaming(
        fetch("./httpspec.wasm"),
        {
          env: {
            // JavaScript functions that WASM can call for logging
            consoleLog: (ptr, len) => {
              const message = this.getStringFromWasm(ptr, len);
              console.log("WASM:", message);
            },
            consoleError: (ptr, len) => {
              const message = this.getStringFromWasm(ptr, len);
              console.error("WASM Error:", message);
            },
          },
        }
      );

      this.wasmModule = wasmModule.instance;
      this.wasmMemory = this.wasmModule.exports.memory;

      console.log("WASM module loaded successfully");

      // Test the module
      const testResult = this.wasmModule.exports.testWasm();
      console.log("WASM test result:", testResult);
    } catch (error) {
      console.error("Failed to load WASM module:", error);
      throw error;
    }
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

  /**
   * SINGLE INTERFACE: Execute HTTPSpec content and get complete results
   *
   * This is the key improvement - one function call gives you everything:
   * parsing, HTTP execution, assertion checking, and formatted results.
   *
   * Internally it uses WASM for parsing and JS for HTTP, but from the
   * caller's perspective it's just one simple function.
   */
  async executeHttpSpec(content) {
    if (!this.wasmModule) {
      throw new Error("WASM module not loaded yet");
    }

    console.log("Starting complete HTTPSpec execution...");
    console.log("Content length:", content.length, "characters");

    try {
      // Step 1: Parse with WASM (single function call)
      const { ptr, len } = this.writeStringToWasm(content);
      const resultPtr = this.wasmModule.exports.parseHttpSpecToJson(ptr, len);
      const resultLen = this.wasmModule.exports.getResultLength();
      const parseJson = this.getStringFromWasm(resultPtr, resultLen);
      const parseResult = JSON.parse(parseJson);

      if (!parseResult.success) {
        return {
          success: false,
          error: parseResult.error,
          total_requests: 0,
          passed_requests: 0,
          failed_requests: 0,
          requests: [],
        };
      }

      console.log("Parsed", parseResult.requests.length, "requests");

      // Step 2: Execute all HTTP requests using JavaScript's fetch
      const executionResults = [];
      let passedCount = 0;
      let failedCount = 0;

      for (const request of parseResult.requests) {
        console.log(`🌐 Executing ${request.method} ${request.url}`);
        const result = await this.executeRequest(request);
        executionResults.push(result);

        if (result.success) {
          passedCount++;
        } else {
          failedCount++;
        }
      }

      // Step 3: Return comprehensive results
      const finalResult = {
        success: failedCount === 0,
        total_requests: executionResults.length,
        passed_requests: passedCount,
        failed_requests: failedCount,
        requests: executionResults,
      };

      console.log("Execution complete:", {
        success: finalResult.success,
        total: finalResult.total_requests,
        passed: finalResult.passed_requests,
        failed: finalResult.failed_requests,
      });

      return finalResult;
    } catch (error) {
      console.error("Failed to execute HTTPSpec:", error);
      return {
        success: false,
        error: `Execution failed: ${error.message}`,
        total_requests: 0,
        passed_requests: 0,
        failed_requests: 0,
        requests: [],
      };
    }
  }

  /**
   * Execute a single HTTP request and check its assertions
   */
  async executeRequest(request) {
    try {
      // Prepare fetch options
      const options = {
        method: request.method,
        headers: request.headers || {},
      };

      // Add body for non-GET requests
      if (request.body && request.method !== "GET") {
        options.body = request.body;
      }

      // Add timeout
      const controller = new AbortController();
      const timeoutId = setTimeout(() => controller.abort(), 10000);
      options.signal = controller.signal;

      // Execute the HTTP request
      const response = await fetch(request.url, options);
      clearTimeout(timeoutId);

      const responseText = await response.text();
      const responseHeaders = Object.fromEntries(response.headers.entries());

      // Check all assertions
      const assertionResults = [];
      let allPassed = true;

      for (const assertion of request.assertions) {
        const result = this.checkAssertion(
          assertion,
          response,
          responseText,
          responseHeaders
        );
        assertionResults.push(result);
        if (!result.passed) {
          allPassed = false;
        }
      }

      return {
        url: request.url,
        method: request.method,
        status_code: response.status,
        success: allPassed,
        error: null,
        response_body:
          responseText.length > 500
            ? responseText.substring(0, 500) + "..."
            : responseText,
        assertions: assertionResults,
      };
    } catch (error) {
      // Handle timeout and other errors
      let errorMessage = error.message;
      if (error.name === "AbortError") {
        errorMessage = "Request timeout (10 seconds)";
      } else if (error.message.includes("Failed to fetch")) {
        errorMessage = "Network error or CORS issue";
      }

      return {
        url: request.url,
        method: request.method,
        status_code: null,
        success: false,
        error: errorMessage,
        response_body: "",
        assertions: [],
      };
    }
  }

  /**
   * Check a single assertion against the HTTP response
   */
  checkAssertion(assertion, response, responseText, responseHeaders) {
    const key = assertion.key.toLowerCase();
    const expected = assertion.value;
    const type = assertion.type;

    let actual = "";
    let passed = false;

    try {
      if (key === "status") {
        actual = response.status.toString();
        switch (type) {
          case "equal":
            passed = actual === expected;
            break;
          case "not_equal":
            passed = actual !== expected;
            break;
          case "contains":
            passed = actual.includes(expected);
            break;
          case "not_contains":
            passed = !actual.includes(expected);
            break;
        }
      } else if (key === "body") {
        actual =
          responseText.length > 200
            ? responseText.substring(0, 200) + "..."
            : responseText;
        switch (type) {
          case "equal":
            passed = responseText === expected;
            break;
          case "not_equal":
            passed = responseText !== expected;
            break;
          case "contains":
            passed = responseText.includes(expected);
            break;
          case "not_contains":
            passed = !responseText.includes(expected);
            break;
        }
      } else if (key.startsWith("header[") && key.endsWith("]")) {
        // Extract header name from header["name"] format
        const headerName = key.slice(8, -2).toLowerCase();
        const headerValue = responseHeaders[headerName] || "";
        actual = headerValue;

        switch (type) {
          case "equal":
            passed = headerValue.toLowerCase() === expected.toLowerCase();
            break;
          case "not_equal":
            passed = headerValue.toLowerCase() !== expected.toLowerCase();
            break;
          case "contains":
            passed = headerValue.toLowerCase().includes(expected.toLowerCase());
            break;
          case "not_contains":
            passed = !headerValue
              .toLowerCase()
              .includes(expected.toLowerCase());
            break;
        }
      } else {
        // Unsupported assertion key
        actual = "unsupported assertion key";
        passed = false;
      }
    } catch (error) {
      actual = `error: ${error.message}`;
      passed = false;
    }

    return {
      key: assertion.key,
      expected: expected,
      actual: actual,
      passed: passed,
      type: type,
    };
  }

  /**
   * Display results in a user-friendly format
   */
  displayResults(results, containerId = "results") {
    const container = document.getElementById(containerId);
    if (!container) {
      console.error("Results container not found:", containerId);
      return;
    }

    let html = "";

    // Summary
    const summaryClass = results.success ? "success" : "error";
    html += `
            <div class="summary ${summaryClass}">
                <h3>${results.success ? "✅" : "❌"} HTTPSpec Results</h3>
                <p>
                    <strong>${results.total_requests}</strong> total requests,
                    <strong>${results.passed_requests}</strong> passed,
                    <strong>${results.failed_requests}</strong> failed
                </p>
                ${
                  results.error
                    ? `<p class="error-message">Error: ${results.error}</p>`
                    : ""
                }
            </div>
        `;

    // Individual request results
    if (results.requests && results.requests.length > 0) {
      html += '<div class="request-results">';

      for (const request of results.requests) {
        const requestClass = request.success ? "success" : "error";

        html += `
                    <div class="request-result ${requestClass}">
                        <div class="request-header">
                            <span class="method">${request.method}</span>
                            <span class="url">${request.url}</span>
                            <span class="status">${
                              request.status_code || "N/A"
                            }</span>
                            <span class="result">${
                              request.success ? "✅" : "❌"
                            }</span>
                        </div>
                        
                        ${
                          request.error
                            ? `<div class="error">Error: ${request.error}</div>`
                            : ""
                        }
                        
                        ${
                          request.response_body
                            ? `
                            <div class="response-body">
                                <strong>Response:</strong>
                                <pre>${this.escapeHtml(
                                  request.response_body
                                )}</pre>
                            </div>
                        `
                            : ""
                        }
                        
                        ${
                          request.assertions && request.assertions.length > 0
                            ? `
                            <div class="assertions">
                                <strong>Assertions:</strong>
                                ${request.assertions
                                  .map(
                                    (assertion) => `
                                    <div class="assertion ${
                                      assertion.passed ? "passed" : "failed"
                                    }">
                                        <span class="assertion-type">${
                                          assertion.type
                                        }</span>
                                        <span class="assertion-key">${
                                          assertion.key
                                        }</span>
                                        <span class="assertion-expected">expected: ${this.escapeHtml(
                                          assertion.expected
                                        )}</span>
                                        <span class="assertion-actual">actual: ${this.escapeHtml(
                                          assertion.actual
                                        )}</span>
                                        <span class="assertion-result">${
                                          assertion.passed ? "✅" : "❌"
                                        }</span>
                                    </div>
                                `
                                  )
                                  .join("")}
                            </div>
                        `
                            : ""
                        }
                    </div>
                `;
      }

      html += "</div>";
    }

    container.innerHTML = html;
  }

  escapeHtml(text) {
    const div = document.createElement("div");
    div.textContent = text;
    return div.innerHTML;
  }

  /**
   * Test with a sample HTTPSpec
   */
  async runSampleTest() {
    const sampleHttpSpec = `
### Test HTTP status endpoint
GET https://httpbin.org/status/200

//# status == 200

### Test JSON endpoint  
GET https://httpbin.org/json

//# status == 200
//# header["content-type"] contains "application/json"
//# body contains "slideshow"

### Test POST endpoint
POST https://httpbin.org/post
Content-Type: application/json

{"message": "Hello from HTTPSpec!", "test": true}

//# status == 200
//# body contains "Hello from HTTPSpec!"
        `.trim();

    console.log("🧪 Running sample HTTPSpec test...");
    const results = await this.executeHttpSpec(sampleHttpSpec);
    this.displayResults(results);
    return results;
  }
}

// Auto-initialize when page loads
let httpSpecRunner;

document.addEventListener("DOMContentLoaded", async () => {
  try {
    httpSpecRunner = new ImprovedHTTPSpecRunner();

    // Wait a bit for WASM to load, then enable the interface
    setTimeout(() => {
      const runButton = document.getElementById("run-tests");
      if (runButton) {
        runButton.disabled = false;
        runButton.textContent = "Run Tests";
      }
    }, 1000);
  } catch (error) {
    console.error("Failed to initialize HTTPSpec runner:", error);
  }
});

// Make it available globally for the HTML interface
window.httpSpecRunner = () => httpSpecRunner;
