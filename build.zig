const // const const
std = @import("std");

pub fn build(b: *std.Build) void {
  const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("editor", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const win32 = b.addTranslateC(.{
        .root_source_file = b.path("src/cimport.h"),
        .target = target,
        .optimize = optimize,
    });
    win32.linkSystemLibrary("d3d11", .{});
    win32.linkSystemLibrary("d3dcompiler_47", .{});
    win32.linkSystemLibrary("d2d1", .{});
    win32.linkSystemLibrary("dwrite", .{});
    win32.linkSystemLibrary("windowscodecs", .{});

    const generate_keymap = b.addExecutable(.{
        .name = "generate_keymap",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/generate_keymap.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_generate_keymap = b.addRunArtifact(generate_keymap);

    const generated_keymap = run_generate_keymap.addOutputFileArg("keymap.zig");

    const exe = b.addExecutable(.{
        .name = "editor",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "editor", .module = mod },
                .{ .name = "win32", .module = win32.createModule() },
                .{
                    .name = "keymap",
                    .module = b.createModule(.{
                        .root_source_file = generated_keymap,
                        .target = target,
                        .optimize = optimize,
                        .imports = &.{.{
                            .name = "commands",
                            .module = b.createModule(.{
                                .root_source_file = b.path("src/commands.zig"),
                                .target = target,
                                .optimize = optimize,
                            }),
                        }},
                    }),
                },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

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
}
