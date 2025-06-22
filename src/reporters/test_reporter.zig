const std = @import("std");

pub const BasicReporter = struct {
    test_count: usize,
    test_pass: usize,
    test_fail: usize,
    test_invalid: usize,
    m: std.Thread.Mutex,

    pub fn init() BasicReporter {
        return .{
            .test_count = 0,
            .test_pass = 0,
            .test_fail = 0,
            .test_invalid = 0,
            .m = std.Thread.Mutex{},
        };
    }

    pub fn report(self: *BasicReporter, writer: anytype) void {
        writer.print(
            \\
            \\All {d} tests ran successfully!
            \\
            \\Pass: {d}
            \\Fail: {d}
            \\Invalid: {d}
            \\
        , .{ self.test_count, self.test_pass, self.test_fail, self.test_invalid }) catch |err| {
            std.debug.print("Error writing to stdout: {}\n", .{err});
        };
    }

    pub fn incTestCount(self: *BasicReporter) void {
        self.m.lock();
        defer self.m.unlock();
        self.test_count += 1;
    }
    pub fn incTestPass(self: *BasicReporter) void {
        self.m.lock();
        defer self.m.unlock();
        self.test_pass += 1;
    }
    pub fn incTestFail(self: *BasicReporter) void {
        self.m.lock();
        defer self.m.unlock();
        self.test_fail += 1;
    }
    pub fn incTestInvalid(self: *BasicReporter) void {
        self.m.lock();
        defer self.m.unlock();
        self.test_invalid += 1;
    }
};
