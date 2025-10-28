const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // KCP module for other packages to import
    const kcp_module = b.addModule("kcp", .{
        .root_source_file = b.path("src/kcp.zig"),
    });

    // Unit tests
    const test_step = b.step("test", "Run unit tests");
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/kcp_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);

    // Benchmark
    const bench_step = b.step("bench", "Run performance benchmarks");
    const bench_exe = b.addExecutable(.{
        .name = "benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/benchmark.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "kcp", .module = kcp_module },
            },
        }),
    });

    const run_bench = b.addRunArtifact(bench_exe);
    bench_step.dependOn(&run_bench.step);

    // Performance test (similar to original KCP test.cpp)
    const perf_step = b.step("perf", "Run performance test with simulated network");
    const perf_exe = b.addExecutable(.{
        .name = "perf_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/perf_test.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "kcp", .module = kcp_module },
            },
        }),
    });

    const run_perf = b.addRunArtifact(perf_exe);
    perf_step.dependOn(&run_perf.step);

    // UDP Server Example
    const server_step = b.step("server", "Run UDP KCP server example");
    const server_exe = b.addExecutable(.{
        .name = "udp_server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/udp_server.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "kcp", .module = kcp_module },
            },
        }),
    });

    const run_server = b.addRunArtifact(server_exe);
    if (b.args) |args| {
        run_server.addArgs(args);
    }
    server_step.dependOn(&run_server.step);

    // Install server executable
    b.installArtifact(server_exe);

    // UDP Client Example
    const client_step = b.step("client", "Run UDP KCP client example");
    const client_exe = b.addExecutable(.{
        .name = "udp_client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/udp_client.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "kcp", .module = kcp_module },
            },
        }),
    });

    const run_client = b.addRunArtifact(client_exe);
    if (b.args) |args| {
        run_client.addArgs(args);
    }
    client_step.dependOn(&run_client.step);

    // Install client executable
    b.installArtifact(client_exe);
}
