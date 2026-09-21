const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zhtml_module = b.addModule("zhtml", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    const test_step = b.step("test", "Run library unit tests");
    test_step.dependOn(&run_lib_tests.step);

    const semantic_behavior_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/semantic_behavior_e2e.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zhtml", .module = zhtml_module },
            },
        }),
    });
    const run_semantic_behavior_tests = b.addRunArtifact(semantic_behavior_tests);
    const semantic_behavior_step = b.step(
        "test-semantic-behavior",
        "Run SemanticBehavior end-to-end tests",
    );
    semantic_behavior_step.dependOn(&run_semantic_behavior_tests.step);

    const html5lib_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/tokenizer-html5lib.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zhtml", .module = zhtml_module },
            },
        }),
    });
    const run_html5lib_tests = b.addRunArtifact(html5lib_tests);
    const html5lib_test_step = b.step("test-html5lib", "Run the tests from html5lib/html5lib-tests");
    html5lib_test_step.dependOn(&run_html5lib_tests.step);
}
