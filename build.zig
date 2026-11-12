const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // libc supplies localtime_r/TZ handling. LLVM/LLD also handles the .sframe
    // relocations in newer system CRT objects.
    const mod = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = true });
    // Single source of truth for the version: build.zig.zon.
    const options = b.addOptions();
    options.addOption([]const u8, "version", @import("build.zig.zon").version);
    mod.addOptions("build_options", options);
    const exe = b.addExecutable(.{ .name = "zpaper", .root_module = mod, .use_lld = true, .use_llvm = true });
    b.installArtifact(exe);
    const benchmark = b.addExecutable(.{ .name = "zpaper-benchmark", .root_module = b.createModule(.{
        .root_source_file = b.path("src/benchmark.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }), .use_lld = true, .use_llvm = true });
    b.step("bench", "Benchmark shuffle selection at 1k, 10k and 50k images").dependOn(&b.addRunArtifact(benchmark).step);
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run zpaper").dependOn(&run.step);
    const tests = b.addTest(.{ .root_module = mod, .use_lld = true, .use_llvm = true });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
}
