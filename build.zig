const std = @import("std");

pub fn build(b: *std.Build) void {
    const exe_name = b.option([]const u8, "exe_name", "Name of the executable") orelse "httpspec";
    const dependencies = [_][]const u8{
        "clap",
        "regex",
        "curl",
    };

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = exe_name,
        .root_module = exe_mod,
    });

    for (dependencies) |dependency| {
        const dep = b.dependency(dependency, .{});
        exe.root_module.addImport(dependency, dep.module(dependency));
    }

    exe.linkLibC();

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Automatically find all Zig files in src/ and subdirectories and add test steps for each
    var zig_files: std.ArrayList([]const u8) = .empty;
    defer zig_files.deinit(b.allocator);
    findZigFiles(b, &zig_files, "src") catch unreachable;

    var test_run_steps: std.ArrayList(*std.Build.Step) = .empty;
    defer test_run_steps.deinit(b.allocator);

    for (zig_files.items) |zig_file| {
        // Skip main.zig since it's already covered by exe_unit_tests
        if (std.mem.endsWith(u8, zig_file, "/main.zig")) continue;
        const test_artifact = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(zig_file),
                .target = target,
                .optimize = optimize,
            }),
        });

        // Add dependencies to individual test artifacts
        for (dependencies) |dependency| {
            const dep = b.dependency(dependency, .{});
            test_artifact.root_module.addImport(dependency, dep.module(dependency));
        }

        const run_test = b.addRunArtifact(test_artifact);
        test_run_steps.append(b.allocator, &run_test.step) catch unreachable;
    }

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
    for (test_run_steps.items) |step| {
        test_step.dependOn(step);
    }
}

fn findZigFiles(b: *std.Build, files: *std.ArrayList([]const u8), dir_path: []const u8) !void {
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".zig")) {
            const full_path = try std.fs.path.join(b.allocator, &[_][]const u8{ dir_path, entry.name });
            try files.append(b.allocator, full_path);
        } else if (entry.kind == .directory and !std.mem.eql(u8, entry.name, ".") and !std.mem.eql(u8, entry.name, "..")) {
            const subdir = try std.fs.path.join(b.allocator, &[_][]const u8{ dir_path, entry.name });
            defer b.allocator.free(subdir);
            try findZigFiles(b, files, subdir);
        }
    }
}
