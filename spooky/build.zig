const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // spooky links a prebuilt libghostty-vt rather than depending on the
    // ghostty package so that iterating on spooky never rebuilds ghostty.
    // Build it once from the repo root with `zig build -Demit-lib-vt`.
    const ghostty_root = b.option(
        []const u8,
        "ghostty",
        "Path to the ghostty checkout (default: ..)",
    ) orelse "..";
    const ghostty_include = b.pathJoin(&.{ ghostty_root, "include" });
    const ghostty_lib = b.pathJoin(&.{ ghostty_root, "zig-out", "lib" });

    const c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    c.addIncludePath(.{ .cwd_relative = ghostty_include });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("c", c.createModule());
    exe_mod.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ ghostty_lib, "libghostty-vt.a" }) });
    exe_mod.linkSystemLibrary("util", .{});

    const exe = b.addExecutable(.{
        .name = "spooky",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run spooky").dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = exe_mod });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
}
