const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const noraylib = b.option(bool, "no-raylib", "disables building raylib") orelse false;

    const mod = b.addModule("debuggraph_zig", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const options = b.addOptions();
    options.addOption(bool, "raylib", !noraylib);
    const optionsMod = options.createModule();

    mod.addImport("options", optionsMod);

    const raylib_dep = b.dependency("raylib_zig", .{
        .target = target,
        .optimize = optimize,
        .config = "-DSUPPORT_FILEFORMAT_JPG=1",
    });

    const raylib = raylib_dep.module("raylib"); // main raylib module
    // const raygui = raylib_dep.module("raygui"); // raygui module
    const raylib_artifact = raylib_dep.artifact("raylib"); // raylib C library
    if (!noraylib) {
        mod.addImport("raylib", raylib);
        mod.linkLibrary(raylib_artifact);
    }

    const exe = b.addExecutable(.{
        .name = "debuggraph_zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "debuggraph_zig", .module = mod },
                .{ .name = "options", .module = optionsMod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    run_cmd.addPassthruArgs();

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    const check_step = b.step("check", "check");
    check_step.dependOn(&exe.step);
}
