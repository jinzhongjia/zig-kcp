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

    // Handle infinite or NaN values
    if (std.math.isInf(result.ops_per_sec) or std.math.isNan(result.ops_per_sec)) {
        std.debug.print("{s:>15} ops/sec", .{"N/A"});
    } else {
        std.debug.print("{d:>15.2} ops/sec", .{result.ops_per_sec});
    }

    if (result.throughput_mbps > 0) {
        std.debug.print("  {d:>10.2} MB/s", .{result.throughput_mbps});
    }
    std.debug.print("\n", .{});
}

fn buildPacket(
    allocator: std.mem.Allocator,
    conv: u32,
    cmd: u8,
    frg: u8,
    wnd: u16,
    ts: u32,
    sn: u32,
    una: u32,
    payload_len: usize,
) ![]u8 {
    const header_len = @as(usize, @intCast(kcp.OVERHEAD));
    const total = header_len + payload_len;
    var buf = try allocator.alloc(u8, total);

    var offset: usize = 0;
    offset = kcp.encode32u(buf, offset, conv);
    offset = kcp.encode8u(buf, offset, cmd);
    offset = kcp.encode8u(buf, offset, frg);
    offset = kcp.encode16u(buf, offset, wnd);
    offset = kcp.encode32u(buf, offset, ts);
    offset = kcp.encode32u(buf, offset, sn);
    offset = kcp.encode32u(buf, offset, una);
    offset = kcp.encode32u(buf, offset, @as(u32, @intCast(payload_len)));

    if (payload_len > 0) {
        @memset(buf[offset .. offset + payload_len], 0x57);
    }

    return buf;
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

fn benchmarkInputReordered(allocator: std.mem.Allocator, segment_count: usize) !BenchmarkResult {
    const conv: u32 = 0x778899AA;
    const kcp_inst = try kcp.create(allocator, conv, null);
    defer kcp.release(kcp_inst);

    const wnd: u32 = @as(u32, @intCast(segment_count + 32));
    kcp.wndsize(kcp_inst, wnd, wnd);
    kcp.setNodelay(kcp_inst, 1, 10, 2, 1);

    var packets: std.ArrayList([]u8) = .empty;
    defer {
        for (packets.items) |pkt| {
            allocator.free(pkt);
        }
        packets.deinit(allocator);
    }
    try packets.ensureTotalCapacity(allocator, segment_count);

    var order = try allocator.alloc(usize, segment_count);
    defer allocator.free(order);

    var prng = std.Random.DefaultPrng.init(0x1234_5678_9ABC_DEF0);
    var random = prng.random();
    const wnd_header: u16 = @intCast(@min(kcp_inst.rcv_wnd, 0xFFFF));

    for (0..segment_count) |i| {
        order[i] = i;
        const sn = @as(u32, @intCast(i));
        const packet = try buildPacket(allocator, conv, kcp.CMD_PUSH, 0, wnd_header, sn, sn, 0, 32);
        try packets.append(allocator, packet);
    }

    var idx = segment_count;
    while (idx > 1) {
        idx -= 1;
        const j = random.intRangeAtMost(usize, 0, idx);
        const tmp = order[idx];
        order[idx] = order[j];
        order[j] = tmp;
    }

    var timer = try std.time.Timer.start();
    for (order) |packet_idx| {
        _ = try kcp.input(kcp_inst, packets.items[packet_idx]);
    }
    const elapsed = timer.read();

    const iterations = @as(u64, @intCast(segment_count));
    const ops_per_sec = if (elapsed == 0)
        0
    else
        @as(f64, @floatFromInt(iterations)) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0);

    const name_fmt = try std.fmt.allocPrint(allocator, "Input reordered {d} seg", .{segment_count});
    defer allocator.free(name_fmt);

    return BenchmarkResult{
        .name = try allocator.dupe(u8, name_fmt),
        .duration_ns = elapsed,
        .operations = iterations,
        .ops_per_sec = ops_per_sec,
        .throughput_mbps = 0,
    };
}

fn benchmarkInputAckBurst(allocator: std.mem.Allocator, segment_count: usize) !BenchmarkResult {
    const conv: u32 = 0xAABBCCDD;
    const kcp_inst = try kcp.create(allocator, conv, null);
    defer kcp.release(kcp_inst);

    const wnd: u32 = @as(u32, @intCast(segment_count + 32));
    kcp.wndsize(kcp_inst, wnd, wnd);
    kcp.setNodelay(kcp_inst, 1, 10, 2, 1);

    const Sink = struct {
        fn output(buf: []const u8, _: *Kcp, _: ?*anyopaque) !i32 {
            return @as(i32, @intCast(buf.len));
        }
    };
    kcp.setOutput(kcp_inst, &Sink.output);

    var payload: [32]u8 = undefined;
    @memset(payload[0..], 0x33);

    var time: u32 = 0;
    for (0..segment_count) |_| {
        _ = try kcp.send(kcp_inst, payload[0..]);
        try kcp.update(kcp_inst, time);
        time += 10;
    }
    try kcp.update(kcp_inst, time);

    var packets: std.ArrayList([]u8) = .empty;
    defer {
        for (packets.items) |pkt| {
            allocator.free(pkt);
        }
        packets.deinit(allocator);
    }

    try packets.ensureTotalCapacity(allocator, kcp_inst.snd_buf.items.len);
    const wnd_header: u16 = @intCast(@min(kcp_inst.rcv_wnd, 0xFFFF));

    for (kcp_inst.snd_buf.items) |seg| {
        const ack = try buildPacket(allocator, conv, kcp.CMD_ACK, 0, wnd_header, seg.ts, seg.sn, seg.sn + 1, 0);
        try packets.append(allocator, ack);
    }

    const ack_count = packets.items.len;
    var timer = try std.time.Timer.start();
    for (packets.items) |pkt| {
        _ = try kcp.input(kcp_inst, pkt);
    }
    const elapsed = timer.read();

    const ops_per_sec = if (elapsed == 0 or ack_count == 0)
        0
    else
        @as(f64, @floatFromInt(ack_count)) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0);

    const name_fmt = try std.fmt.allocPrint(allocator, "ACK burst {d} seg", .{ack_count});
    defer allocator.free(name_fmt);

    return BenchmarkResult{
        .name = try allocator.dupe(u8, name_fmt),
        .duration_ns = elapsed,
        .operations = @as(u64, @intCast(ack_count)),
        .ops_per_sec = ops_per_sec,
        .throughput_mbps = 0,
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
    const packet_sizes = [_]usize{ 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768 };
    for (packet_sizes) |size| {
        const result = try benchmarkSendRecv(allocator, size);
        defer allocator.free(result.name);
        printResult(result);
    }

    // Input path benchmarks
    {
        const result = try benchmarkInputReordered(allocator, 512);
        defer allocator.free(result.name);
        printResult(result);
    }

    {
        const result = try benchmarkInputAckBurst(allocator, 2048);
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
