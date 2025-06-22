# Httpspec

Httpspec is a tool that expands upon HTTP Files by adding assertions to them, to be used for integration tests. HTTPSpec is also intended
to be a test suite runner for these extended HTTP Files.

Httpspec takes in an .http (or .httpspec) file (or a directory containing those files, defaulting to CWD if none is provided), runs those requests in sequence with optional assertions that are checked along the way. Let's take the following specfile:

```
### Make a simple 200 request to HTTP Bin
GET http://httpbin.org/status/200
Content-Type: application/json

### Make a simple 404 request to HTTP Bin
GET http://httpbin.org/status/404
Content-Type: application/json
//# status == 403

### Make a simple 201 request to HTTP Bin
GET http://httpbin.org/status/201
Content-Type: application/json
```

Httpspec takes this file, executes the first request (/status/200 in this case), and since there's no assertions for this request, as long as the request succeeds, it continues on. Then, we'd run the /status/404 request but we're asserting that the status returned is a 403 -- which it is not. In this case, the request is made and we check the response against those assertions, which fail. Since these assertions fail, we do not continue to make the 201 request.

The idea behind Httpspec is to allow you to specify a series of HTTP requests (with assertions) to model a sequence of test steps. For example, the first request in your file may create a user in your API which is then needed by future requests. You may then make another request, using those user credentials, to create an order for that user -- again, this is just an example.

# How to Use

```bash
httpspec ./test_files/httpbin_test.http # or whatever your filepath is to your .http or .httpspec file

# Sample output
Running test 1: ./test_files/httpbin_test.http
[Fail] Expected status code 403, got 404
All 1 tests ran successfully!

Pass: 0
Fail: 1
```

There are some gaps in this implementation at this point (these are things I plan to address):

1. There is not currently a way to pipe the response from a previous request into the next request. This is limiting as you often may need an ID from a previous request to make the next request.
2. Not all of the assertion types specified in the [specification](./HTTPSpec.md) are implemented yet.

# Configuration

Do you have the need for speed? Tests are ran against a thread-pool and you can configure the number of jobs in said pool! Use the `HTTP_THREAD_COUNT` env var to specify the number of jobs in the pool.

Example:
```bash
HTTP_THREAD_COUNT=4 httpspec ./my_project/httptests/
```