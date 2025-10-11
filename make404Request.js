// make404Request.js
// Task: Make a simple 404 request to HTTP Bin
// Expected: status == 403

async function make404Request() {
  const url = "http://httpbin.org/status/404";
  const response = await fetch(url, {
    method: "GET",
    headers: {
      "Content-Type": "application/json",
    },
  });

  console.log("Requested URL:", url);
  console.log("Received status:", response.status);

  if (response.status === 403) {
    console.log("✅ Test passed: Status is 403");
  } else {
    console.log(`❌ Test failed: Expected 403 but got ${response.status}`);
  }
}

make404Request();
