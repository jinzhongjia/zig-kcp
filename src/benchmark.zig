//=====================================================================
//
// benchmark.zig - Performance Benchmarks for KCP
//
//=====================================================================

const std = @import("std");
const kcp = @import("kcp.zig");
const Kcp = kcp.Kcp;

const BenchmarkResult = struct {
    name: []const u8,
    duration_ns: u64,
    operations: u64,
    ops_per_sec: f64,
    throughput_mbps: f64,
};

fn printResult(result: BenchmarkResult) void {
    std.debug.print("  {s:<40} ", .{result.name});
    std.debug.print("{d:>10.2} ops/sec  ", .{result.ops_per_sec});
    if (result.throughput_mbps > 0) {
        std.debug.print("{d:>8.2} MB/s", .{result.throughput_mbps});
    }
    std.debug.print("\n", .{});
}

fn benchmarkCreateRelease(allocator: std.mem.Allocator) !BenchmarkResult {
    const iterations: u64 = 10000;
    var timer = try std.time.Timer.start();

    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        const kcp_inst = try kcp.create(allocator, @intCast(i), null);
        kcp.release(kcp_inst);
    }

    const elapsed = timer.read();
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0);

    return BenchmarkResult{
        .name = "Create and Release",
        .duration_ns = elapsed,
        .operations = iterations,
        .ops_per_sec = ops_per_sec,
        .throughput_mbps = 0,
    };
}

fn benchmarkSendRecv(allocator: std.mem.Allocator, packet_size: usize) !BenchmarkResult {
    const iterations: u64 = 1000;
    const conv: u32 = 1;

    const kcp1 = try kcp.create(allocator, conv, null);
    defer kcp.release(kcp1);

    const kcp2 = try kcp.create(allocator, conv, null);
    defer kcp.release(kcp2);

    kcp.setNodelay(kcp1, 1, 10, 2, 1);
    kcp.setNodelay(kcp2, 1, 10, 2, 1);

    const Context = struct {
        peer: *Kcp,

        fn output(buf: []const u8, _: *Kcp, user: ?*anyopaque) !i32 {
            const ctx = @as(*@This(), @ptrCast(@alignCast(user.?)));
            _ = try kcp.input(ctx.peer, buf);
            return @as(i32, @intCast(buf.len));
        }
    };

    var ctx1 = Context{ .peer = kcp2 };
    var ctx2 = Context{ .peer = kcp1 };

    kcp.setOutput(kcp1, &Context.output);
    kcp1.user = &ctx1;
    kcp.setOutput(kcp2, &Context.output);
    kcp2.user = &ctx2;

    const data = try allocator.alloc(u8, packet_size);
    defer allocator.free(data);
    @memset(data, 0xAA);

    const recv_buf = try allocator.alloc(u8, packet_size * 2);
    defer allocator.free(recv_buf);

    var timer = try std.time.Timer.start();

    var time: u32 = 0;
    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        _ = try kcp.send(kcp1, data);

        var attempts: u32 = 0;
        while (attempts < 100) : (attempts += 1) {
            try kcp.update(kcp1, time);
            try kcp.update(kcp2, time);
            time += 10; // Match KCP interval

            const recv_len = kcp.recv(kcp2, recv_buf) catch continue;
            if (recv_len > 0) break;
        }
    }

    const elapsed = timer.read();
    const total_bytes = iterations * packet_size;
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0);
    const throughput_mbps = (@as(f64, @floatFromInt(total_bytes)) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0)) / (1024.0 * 1024.0);

    const name = try std.fmt.allocPrint(allocator, "Send/Recv {d} bytes", .{packet_size});
    defer allocator.free(name);

    return BenchmarkResult{
        .name = try allocator.dupe(u8, name),
        .duration_ns = elapsed,
        .operations = iterations,
        .ops_per_sec = ops_per_sec,
        .throughput_mbps = throughput_mbps,
    };
}

fn benchmarkEncodeDecode(allocator: std.mem.Allocator) !BenchmarkResult {
    const iterations: u64 = 1000000;
    var buf: [100]u8 = undefined;

    var timer = try std.time.Timer.start();

    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        var pos: usize = 0;
        pos = kcp.encode32u(&buf, pos, @intCast(i));
        pos = kcp.encode32u(&buf, pos, @intCast(i + 1));
        pos = kcp.encode16u(&buf, pos, @intCast(i & 0xFFFF));
        pos = kcp.encode8u(&buf, pos, @intCast(i & 0xFF));

        pos = 0;
        var r32 = kcp.decode32u(&buf, pos);
        pos = r32.offset;
        r32 = kcp.decode32u(&buf, pos);
        pos = r32.offset;
        const r16 = kcp.decode16u(&buf, pos);
        pos = r16.offset;
        const r8 = kcp.decode8u(&buf, pos);
        _ = r8.offset;
    }

    const elapsed = timer.read();
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0);

    _ = allocator;
    return BenchmarkResult{
        .name = "Encode/Decode",
        .duration_ns = elapsed,
        .operations = iterations,
        .ops_per_sec = ops_per_sec,
        .throughput_mbps = 0,
    };
}

fn benchmarkUpdate(allocator: std.mem.Allocator) !BenchmarkResult {
    const iterations: u64 = 100000;

    const kcp_inst = try kcp.create(allocator, 1, null);
    defer kcp.release(kcp_inst);

    kcp.setNodelay(kcp_inst, 1, 10, 2, 1);

    var timer = try std.time.Timer.start();

    var time: u32 = 0;
    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        try kcp.update(kcp_inst, time);
        time += 10;
    }

    const elapsed = timer.read();
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0);

    return BenchmarkResult{
        .name = "Update (no data)",
        .duration_ns = elapsed,
        .operations = iterations,
        .ops_per_sec = ops_per_sec,
        .throughput_mbps = 0,
    };
}

fn benchmarkFragmentation(allocator: std.mem.Allocator) !BenchmarkResult {
    const iterations: u64 = 100;
    const large_size: usize = 64 * 1024; // 64KB
    const conv: u32 = 1;

    const kcp1 = try kcp.create(allocator, conv, null);
    defer kcp.release(kcp1);

    const kcp2 = try kcp.create(allocator, conv, null);
    defer kcp.release(kcp2);

    kcp.setNodelay(kcp1, 1, 10, 2, 1);
    kcp.setNodelay(kcp2, 1, 10, 2, 1);

    const Context = struct {
        peer: *Kcp,

        fn output(buf: []const u8, _: *Kcp, user: ?*anyopaque) !i32 {
            const ctx = @as(*@This(), @ptrCast(@alignCast(user.?)));
            _ = try kcp.input(ctx.peer, buf);
            return @as(i32, @intCast(buf.len));
        }
    };

    var ctx1 = Context{ .peer = kcp2 };
    var ctx2 = Context{ .peer = kcp1 };

    kcp.setOutput(kcp1, &Context.output);
    kcp1.user = &ctx1;
    kcp.setOutput(kcp2, &Context.output);
    kcp2.user = &ctx2;

    const data = try allocator.alloc(u8, large_size);
    defer allocator.free(data);
    @memset(data, 0xBB);

    const recv_buf = try allocator.alloc(u8, large_size * 2);
    defer allocator.free(recv_buf);

    var timer = try std.time.Timer.start();

    var time: u32 = 0;
    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        _ = try kcp.send(kcp1, data);

        var attempts: u32 = 0;
        while (attempts < 200) : (attempts += 1) {
            try kcp.update(kcp1, time);
            try kcp.update(kcp2, time);
            time += 10; // Match KCP interval

            const recv_len = kcp.recv(kcp2, recv_buf) catch continue;
            if (recv_len > 0) break;
        }
    }

    const elapsed = timer.read();
    const total_bytes = iterations * large_size;
    const ops_per_sec = @as(f64, @floatFromInt(iterations)) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0);
    const throughput_mbps = (@as(f64, @floatFromInt(total_bytes)) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0)) / (1024.0 * 1024.0);

    return BenchmarkResult{
        .name = "Large packets (64KB fragmentation)",
        .duration_ns = elapsed,
        .operations = iterations,
        .ops_per_sec = ops_per_sec,
        .throughput_mbps = throughput_mbps,
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n", .{});
    std.debug.print("==============================================\n", .{});
    std.debug.print("  KCP Performance Benchmarks\n", .{});
    std.debug.print("==============================================\n\n", .{});

    // Create/Release benchmark
    {
        const result = try benchmarkCreateRelease(allocator);
        printResult(result);
    }

    // Encode/Decode benchmark
    {
        const result = try benchmarkEncodeDecode(allocator);
        printResult(result);
    }

    // Update benchmark
    {
        const result = try benchmarkUpdate(allocator);
        printResult(result);
    }

    // Send/Recv benchmarks with different packet sizes
    const packet_sizes = [_]usize{ 64, 256, 1024, 4096 };
    for (packet_sizes) |size| {
        const result = try benchmarkSendRecv(allocator, size);
        defer allocator.free(result.name);
        printResult(result);
    }

    // Fragmentation benchmark
    {
        const result = try benchmarkFragmentation(allocator);
        printResult(result);
    }

    std.debug.print("\n", .{});
}
