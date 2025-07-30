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

      // Initialize fetch result buffer
      this.fetchResultBuffer = new ArrayBuffer(65536); // 64KB buffer
      this.fetchResultLength = 0;

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
            
            // HTTP fetch function - required by new WASM implementation
            fetchHttp: (methodPtr, methodLen, urlPtr, urlLen, headersPtr, headersLen, bodyPtr, bodyLen) => {
              return this.performFetch(methodPtr, methodLen, urlPtr, urlLen, headersPtr, headersLen, bodyPtr, bodyLen);
            },
            
            // Get length of last fetch result
            getFetchResultLength: () => {
              return this.fetchResultLength;
            }
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
    
    // Use a safer allocation strategy - allocate at the end but leave space
    const memorySize = this.wasmMemory.buffer.byteLength;
    const safeOffset = 4096; // Leave 4KB buffer at the end
    const ptr = memorySize - bytes.length - safeOffset;
    
    // Ensure we have enough space
    if (ptr < 0) {
      const pagesNeeded = Math.ceil((bytes.length + safeOffset) / 65536);
      this.wasmMemory.grow(pagesNeeded);
      const newSize = this.wasmMemory.buffer.byteLength;
      const newPtr = newSize - bytes.length - safeOffset;
      const wasmBytes = new Uint8Array(this.wasmMemory.buffer, newPtr, bytes.length);
      wasmBytes.set(bytes);
      return { ptr: newPtr, len: bytes.length };
    }
    
    const wasmBytes = new Uint8Array(this.wasmMemory.buffer, ptr, bytes.length);
    wasmBytes.set(bytes);
    return { ptr, len: bytes.length };
  }

  // HTTP fetch implementation called by WASM - this needs to be synchronous-ish
  performFetch(methodPtr, methodLen, urlPtr, urlLen, headersPtr, headersLen, bodyPtr, bodyLen) {
    try {
      const method = this.getStringFromWasm(methodPtr, methodLen);
      const url = this.getStringFromWasm(urlPtr, urlLen);
      const headersJson = this.getStringFromWasm(headersPtr, headersLen);
      const body = bodyLen > 0 ? this.getStringFromWasm(bodyPtr, bodyLen) : null;

      
      // Parse headers from JSON
      let headers = {};
      try {
        headers = JSON.parse(headersJson);
      } catch (e) {
        console.warn('Failed to parse headers JSON:', e);
      }

      // Since WASM expects synchronous behavior but fetch is async,
      // we'll use XMLHttpRequest for synchronous operation
      const xhr = new XMLHttpRequest();
      xhr.open(method, url, false); // false = synchronous
      
      // Set headers
      for (const [key, value] of Object.entries(headers)) {
        xhr.setRequestHeader(key, value);
      }
      
      try {
        xhr.send(body);
        
        // Get response headers
        const responseHeaders = {};
        const headerText = xhr.getAllResponseHeaders();
        if (headerText) {
          headerText.split('\r\n').forEach(line => {
            const parts = line.split(': ');
            if (parts.length === 2) {
              responseHeaders[parts[0].toLowerCase()] = parts[1];
            }
          });
        }
        
        const responseData = {
          status: xhr.status,
          headers: responseHeaders,
          body: xhr.responseText || ''
        };
        
        const responseJson = JSON.stringify(responseData);
        const responseBytes = this.textEncoder.encode(responseJson);
        
        // Store result directly in WASM memory instead of separate buffer
        this.fetchResultLength = responseBytes.length;
        
        // Allocate space in WASM memory for the response
        const memorySize = this.wasmMemory.buffer.byteLength;
        const responsePtr = memorySize - responseBytes.length - 8192; // Leave 8KB buffer
        
        // Copy response into WASM memory
        const wasmView = new Uint8Array(this.wasmMemory.buffer, responsePtr, responseBytes.length);
        wasmView.set(responseBytes);
        
        
        // Return pointer to WASM memory location
        return responsePtr;
        
      } catch (error) {
        console.error('XHR error:', error);
        
        // Store error response in WASM memory
        const errorResponse = JSON.stringify({
          status: 0,
          headers: {},
          body: `Network error: ${error.message}`
        });
        
        const errorBytes = this.textEncoder.encode(errorResponse);
        this.fetchResultLength = errorBytes.length;
        
        const memorySize = this.wasmMemory.buffer.byteLength;
        const errorPtr = memorySize - errorBytes.length - 8192;
        
        const wasmView = new Uint8Array(this.wasmMemory.buffer, errorPtr, errorBytes.length);
        wasmView.set(errorBytes);
        
        return errorPtr;
      }
      
    } catch (error) {
      console.error('performFetch error:', error);
      
      const errorResponse = JSON.stringify({
        status: 500,
        headers: {},
        body: `Fetch setup error: ${error.message}`
      });
      
      const errorBytes = this.textEncoder.encode(errorResponse);
      this.fetchResultLength = errorBytes.length;
      
      const memorySize = this.wasmMemory.buffer.byteLength;
      const errorPtr = memorySize - errorBytes.length - 8192;
      
      const wasmView = new Uint8Array(this.wasmMemory.buffer, errorPtr, errorBytes.length);
      wasmView.set(errorBytes);
      
      return errorPtr;
    }
  }

  /**
   * UNIFIED INTERFACE: Execute HTTPSpec content completely in WASM
   *
   * Now using the new executeHttpSpecComplete function that handles:
   * parsing, HTTP execution (via fetchHttp), assertion checking, and results.
   *
   * This is a true single function call that gives you everything done in WASM.
   */
  async executeHttpSpec(content) {
    if (!this.wasmModule) {
      throw new Error("WASM module not loaded yet");
    }


    try {
      // Single call to WASM that does everything
      const { ptr, len } = this.writeStringToWasm(content);
      const resultPtr = this.wasmModule.exports.executeHttpSpecComplete(ptr, len);
      const resultLen = this.wasmModule.exports.getResultLength();
      const resultJson = this.getStringFromWasm(resultPtr, resultLen);
      const wasmResult = JSON.parse(resultJson);

      if (!wasmResult.success) {
        return {
          success: false,
          error: wasmResult.error,
          total_requests: 0,
          passed_requests: 0,
          failed_requests: 0,
          requests: [],
        };
      }

      // Convert WASM results to our expected format
      const results = wasmResult.results || [];
      const passedCount = results.filter(r => r.passed).length;
      const failedCount = results.length - passedCount;

      const finalResult = {
        success: failedCount === 0,
        total_requests: results.length,
        passed_requests: passedCount,
        failed_requests: failedCount,
        requests: results.map(result => ({
          url: `Request: ${result.name}`,
          method: "WASM",
          status_code: result.status || null,
          success: result.passed,
          error: result.error || null,
          response_body: "",
          assertions: [] // WASM handles assertions internally
        })),
      };


      return finalResult;
    } catch (error) {
      console.error("Failed to execute HTTPSpec in WASM:", error);
      return {
        success: false,
        error: `WASM execution failed: ${error.message}`,
        total_requests: 0,
        passed_requests: 0,
        failed_requests: 0,
        requests: [],
      };
    }
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
