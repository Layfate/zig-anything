const std = @import("std");

const version = "0.1.1";

/// Targets produced by `zig build release`.
const release_targets = [_]std.Target.Query{
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
    .{ .cpu_arch = .x86_64, .os_tag = .macos },
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
    .{ .cpu_arch = .x86_64, .os_tag = .windows },
    .{ .cpu_arch = .aarch64, .os_tag = .windows },
};

fn makeExe(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize, opts: *std.Build.Step.Options) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = if (optimize == .debug) null else true,
    });
    mod.addOptions("build_options", opts);
    return b.addExecutable(.{ .name = "zig-anything", .root_module = mod });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const opts = b.addOptions();
    opts.addOption([]const u8, "version", version);

    // ---- main executable
    const exe = makeExe(b, target, optimize, opts);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run zig-anything").dependOn(&run_cmd.step);

    // ---- unit tests: CLI modules and the runtime copied into port units
    const test_step = b.step("test", "Run unit tests");
    const unit_tests = b.addTest(.{ .root_module = exe.root_module });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    const rt_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/assets/rt.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    test_step.dependOn(&b.addRunArtifact(rt_tests).step);
    const napi_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/assets/napi.zig"),
            .target = target,
            .optimize = optimize,
            // The addon finds N-API with dlsym outside Windows.
            .link_libc = target.result.os.tag != .windows,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(napi_tests).step);

    // ---- end-to-end tests: drive the real binary through full workflows
    const e2e = b.addExecutable(.{
        .name = "e2e",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/e2e.zig"),
            .target = b.graph.host,
            .optimize = .debug,
        }),
    });
    const run_e2e = b.addRunArtifact(e2e);
    run_e2e.addArtifactArg(exe);
    run_e2e.addDirectoryArg(b.path("tests/fixtures"));
    run_e2e.addDirectoryArg(b.path("examples"));
    run_e2e.has_side_effects = true;
    b.step("e2e", "Run end-to-end tests (needs node and python on PATH)").dependOn(&run_e2e.step);

    // ---- micro benchmarks of the tool's own hot paths
    const micro = b.addExecutable(.{
        .name = "microbench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/microbench.zig"),
            .target = target,
            .optimize = .fast,
        }),
    });
    micro.root_module.addImport("zig_anything_src", b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = .fast,
    }));
    const run_micro = b.addRunArtifact(micro);
    run_micro.has_side_effects = true;
    b.step("microbench", "Benchmark scanning, generation and comparison").dependOn(&run_micro.step);

    // ---- release binaries for every supported platform
    const release_step = b.step("release", "Build size-optimized binaries for all release targets");
    for (release_targets) |q| {
        const rt = b.resolveTargetQuery(q);
        const rexe = makeExe(b, rt, .small, opts);
        const triple = q.zigTriple(b.allocator) catch @panic("OOM");
        const inst = b.addInstallArtifact(rexe, .{ .dest_dir = .{ .override = .{ .custom = b.fmt("release/{s}", .{triple}) } } });
        release_step.dependOn(&inst.step);
    }
}
