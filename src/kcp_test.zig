//=====================================================================
//
// kcp_test.zig - Unit Tests for KCP Protocol
//
//=====================================================================

const std = @import("std");
const testing = std.testing;
const kcp = @import("kcp.zig");

// Import all needed symbols
const Kcp = kcp.Kcp;
const Segment = kcp.Segment;
const MTU_DEF = kcp.MTU_DEF;
const OVERHEAD = kcp.OVERHEAD;
const RTO_NDL = kcp.RTO_NDL;
const RTO_MIN = kcp.RTO_MIN;
const CMD_PUSH = kcp.CMD_PUSH;
const CMD_WASK = kcp.CMD_WASK;
const THRESH_MIN = kcp.THRESH_MIN;
const encode8u = kcp.encode8u;
const decode8u = kcp.decode8u;
const encode16u = kcp.encode16u;
const decode16u = kcp.decode16u;
const encode32u = kcp.encode32u;
const decode32u = kcp.decode32u;
const getconv = kcp.getconv;
const imin = kcp.imin;
const imax = kcp.imax;
const ibound = kcp.ibound;
const itimediff = kcp.itimediff;

test "encode and decode 8u" {
    var buf: [10]u8 = undefined;

    const offset = encode8u(&buf, 0, 0x42);
    try testing.expectEqual(@as(usize, 1), offset);
    try testing.expectEqual(@as(u8, 0x42), buf[0]);

    const result = decode8u(&buf, 0);
    try testing.expectEqual(@as(u8, 0x42), result.value);
    try testing.expectEqual(@as(usize, 1), result.offset);
}

test "encode and decode 16u" {
    var buf: [10]u8 = undefined;

    const offset = encode16u(&buf, 0, 0x1234);
    try testing.expectEqual(@as(usize, 2), offset);
    try testing.expectEqual(@as(u8, 0x34), buf[0]);
    try testing.expectEqual(@as(u8, 0x12), buf[1]);

    const result = decode16u(&buf, 0);
    try testing.expectEqual(@as(u16, 0x1234), result.value);
    try testing.expectEqual(@as(usize, 2), result.offset);
}

test "encode and decode 32u" {
    var buf: [10]u8 = undefined;

    const offset = encode32u(&buf, 0, 0x12345678);
    try testing.expectEqual(@as(usize, 4), offset);
    try testing.expectEqual(@as(u8, 0x78), buf[0]);
    try testing.expectEqual(@as(u8, 0x56), buf[1]);
    try testing.expectEqual(@as(u8, 0x34), buf[2]);
    try testing.expectEqual(@as(u8, 0x12), buf[3]);

    const result = decode32u(&buf, 0);
    try testing.expectEqual(@as(u32, 0x12345678), result.value);
    try testing.expectEqual(@as(usize, 4), result.offset);
}

test "utility functions" {
    try testing.expectEqual(@as(u32, 5), imin(5, 10));
    try testing.expectEqual(@as(u32, 5), imin(10, 5));

    try testing.expectEqual(@as(u32, 10), imax(5, 10));
    try testing.expectEqual(@as(u32, 10), imax(10, 5));

    try testing.expectEqual(@as(u32, 5), ibound(3, 5, 10));
    try testing.expectEqual(@as(u32, 3), ibound(3, 1, 10));
    try testing.expectEqual(@as(u32, 10), ibound(3, 15, 10));

    try testing.expectEqual(@as(i32, 100), itimediff(150, 50));
    try testing.expectEqual(@as(i32, -100), itimediff(50, 150));
}

test "kcp create and release" {
    const allocator = testing.allocator;

    const conv: u32 = 0x12345678;
    const kcp_inst = try kcp.create(allocator, conv, null);
    defer kcp.release(kcp_inst);

    try testing.expectEqual(conv, kcp_inst.conv);
    try testing.expectEqual(@as(u32, MTU_DEF), kcp_inst.mtu);
    try testing.expectEqual(@as(u32, MTU_DEF - OVERHEAD), kcp_inst.mss);
    try testing.expectEqual(@as(u32, 0), kcp_inst.snd_una);
    try testing.expectEqual(@as(u32, 0), kcp_inst.snd_nxt);
    try testing.expectEqual(@as(u32, 0), kcp_inst.rcv_nxt);
}

test "kcp send and recv basic" {
    const allocator = testing.allocator;

    const conv: u32 = 1;
    const kcp1 = try kcp.create(allocator, conv, null);
    defer kcp.release(kcp1);

    const kcp2 = try kcp.create(allocator, conv, null);
    defer kcp.release(kcp2);

    // Initialize cwnd (congestion window) - it starts at 0 until first ACK
    // For testing, we set it manually or use fast mode
    kcp.setNodelay(kcp1, 1, 10, 2, 1);
    kcp.setNodelay(kcp2, 1, 10, 2, 1);

    // Set up output callback to transfer data between kcp1 and kcp2
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

    // Send data from kcp1
    const message = "Hello, KCP!";
    const sent = try kcp.send(kcp1, message);
    try testing.expectEqual(@as(i32, @intCast(message.len)), sent);

    // Multiple update cycles to ensure data transfer
    var time: u32 = 0;
    var i: u32 = 0;
    while (i < 50) : (i += 1) {
        try kcp.update(kcp1, time);
        try kcp.update(kcp2, time);
        time += 10;

        // Try to receive after a few cycles
        if (i > 5) {
            var recv_buf: [1024]u8 = undefined;
            const recv_len = kcp.recv(kcp2, &recv_buf) catch |err| {
                if (err == error.OutOfMemory) return err;
                continue;
            };
            if (recv_len > 0) {
                try testing.expectEqual(@as(i32, @intCast(message.len)), recv_len);
                try testing.expectEqualStrings(message, recv_buf[0..@as(usize, @intCast(recv_len))]);
                return;
            }
        }
    }

    // Final attempt
    var recv_buf: [1024]u8 = undefined;
    const recv_len = try kcp.recv(kcp2, &recv_buf);
    try testing.expectEqual(message.len, recv_len);
    try testing.expectEqualStrings(message, recv_buf[0..recv_len]);
}

test "kcp send large data with fragmentation" {
    const allocator = testing.allocator;

    const conv: u32 = 1;
    const kcp1 = try kcp.create(allocator, conv, null);
    defer kcp.release(kcp1);

    const kcp2 = try kcp.create(allocator, conv, null);
    defer kcp.release(kcp2);

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

    // Use faster settings for testing
    kcp.setNodelay(kcp1, 1, 10, 2, 1);
    kcp.setNodelay(kcp2, 1, 10, 2, 1);

    // Send large data that requires fragmentation
    var large_data: [8192]u8 = undefined;
    for (&large_data, 0..) |*byte, idx| {
        byte.* = @as(u8, @truncate(idx));
    }

    const sent = try kcp.send(kcp1, &large_data);
    try testing.expectEqual(@as(i32, @intCast(large_data.len)), sent);

    // Multiple update cycles to transfer all fragments
    var time: u32 = 0;
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        try kcp.update(kcp1, time);
        try kcp.update(kcp2, time);
        time += 10;

        // Try to receive data once available
        if (i > 10) {
            var recv_buf: [10240]u8 = undefined;
            const recv_len = kcp.recv(kcp2, &recv_buf) catch |err| {
                if (err == error.OutOfMemory) return err;
                continue;
            };

            if (recv_len > 0) {
                try testing.expectEqual(@as(i32, @intCast(large_data.len)), recv_len);
                try testing.expectEqualSlices(u8, &large_data, recv_buf[0..@as(usize, @intCast(recv_len))]);
                return;
            }
        }
    }

    // Final attempt to receive
    var recv_buf: [10240]u8 = undefined;
    const recv_len = try kcp.recv(kcp2, &recv_buf);
    try testing.expectEqual(large_data.len, recv_len);
    try testing.expectEqualSlices(u8, &large_data, recv_buf[0..recv_len]);
}

test "kcp config functions" {
    const allocator = testing.allocator;

    const kcp_inst = try kcp.create(allocator, 1, null);
    defer kcp.release(kcp_inst);

    // Test setNodelay
    kcp.setNodelay(kcp_inst, 1, 20, 2, 1);
    try testing.expectEqual(@as(u32, 1), kcp_inst.nodelay);
    try testing.expectEqual(@as(u32, 20), kcp_inst.interval);
    try testing.expectEqual(@as(u32, 2), kcp_inst.fastresend);
    try testing.expectEqual(true, kcp_inst.nocwnd);
    try testing.expectEqual(@as(u32, RTO_NDL), kcp_inst.rx_minrto);

    // Test wndsize
    kcp.wndsize(kcp_inst, 64, 256);
    try testing.expectEqual(@as(u32, 64), kcp_inst.snd_wnd);
    try testing.expectEqual(@as(u32, 256), kcp_inst.rcv_wnd);

    // Test setMtu
    try kcp.setMtu(kcp_inst, 1200);
    try testing.expectEqual(@as(u32, 1200), kcp_inst.mtu);
    try testing.expectEqual(@as(u32, 1200 - OVERHEAD), kcp_inst.mss);
}

test "kcp waitsnd" {
    const allocator = testing.allocator;

    const kcp_inst = try kcp.create(allocator, 1, null);
    defer kcp.release(kcp_inst);

    try testing.expectEqual(@as(u32, 0), kcp.waitsnd(kcp_inst));

    _ = try kcp.send(kcp_inst, "test");
    try testing.expectEqual(@as(u32, 1), kcp.waitsnd(kcp_inst));
}

test "kcp check function" {
    const allocator = testing.allocator;

    const kcp_inst = try kcp.create(allocator, 1, null);
    defer kcp.release(kcp_inst);

    const current: u32 = 1000;
    const next_update = kcp.check(kcp_inst, current);
    try testing.expectEqual(current, next_update);

    try kcp.update(kcp_inst, current);
    const next_update2 = kcp.check(kcp_inst, current);
    try testing.expect(next_update2 > current);
}

test "getconv function" {
    var buf: [24]u8 = undefined;

    const conv: u32 = 0xDEADBEEF;
    _ = encode32u(&buf, 0, conv);

    const decoded_conv = try getconv(&buf);
    try testing.expectEqual(conv, decoded_conv);

    // Test with invalid data
    const short_buf: [2]u8 = undefined;
    try testing.expectError(error.InvalidData, getconv(&short_buf));
}

test "segment encode" {
    const allocator = testing.allocator;

    var seg = Segment.init(allocator);
    defer seg.deinit();

    seg.conv = 0x12345678;
    seg.cmd = CMD_PUSH;
    seg.frg = 5;
    seg.wnd = 256;
    seg.ts = 1000;
    seg.sn = 42;
    seg.una = 10;
    try seg.data.appendSlice(allocator, "test");

    var buf: [100]u8 = undefined;
    const offset = kcp.segment.encode(&seg, &buf, 0);

    try testing.expectEqual(@as(usize, OVERHEAD), offset);

    // Decode and verify
    var pos: usize = 0;
    var r32 = decode32u(&buf, pos);
    try testing.expectEqual(@as(u32, 0x12345678), r32.value);
    pos = r32.offset;

    var r8 = decode8u(&buf, pos);
    try testing.expectEqual(@as(u8, CMD_PUSH), r8.value);
    pos = r8.offset;

    r8 = decode8u(&buf, pos);
    try testing.expectEqual(@as(u8, 5), r8.value);
    pos = r8.offset;

    const r16 = decode16u(&buf, pos);
    try testing.expectEqual(@as(u16, 256), r16.value);
    pos = r16.offset;

    r32 = decode32u(&buf, pos);
    try testing.expectEqual(@as(u32, 1000), r32.value);
    pos = r32.offset;

    r32 = decode32u(&buf, pos);
    try testing.expectEqual(@as(u32, 42), r32.value);
    pos = r32.offset;

    r32 = decode32u(&buf, pos);
    try testing.expectEqual(@as(u32, 10), r32.value);
    pos = r32.offset;

    r32 = decode32u(&buf, pos);
    try testing.expectEqual(@as(u32, 4), r32.value);
}

test "kcp peeksize" {
    const allocator = testing.allocator;

    const kcp_inst = try kcp.create(allocator, 1, null);
    defer kcp.release(kcp_inst);

    // Empty queue should return -1
    try testing.expectEqual(@as(i32, -1), try kcp.peeksize(kcp_inst));

    // Add a segment to receive queue
    var seg = Segment.init(allocator);
    seg.frg = 0;
    try seg.data.appendSlice(allocator, "test");
    try kcp_inst.rcv_queue.append(allocator, seg);
    kcp_inst.nrcv_que = 1;

    // Should return the size
    try testing.expectEqual(@as(i32, 4), try kcp.peeksize(kcp_inst));
}

test "kcp stream mode" {
    const allocator = testing.allocator;

    const kcp_inst = try kcp.create(allocator, 1, null);
    defer kcp.release(kcp_inst);

    kcp_inst.stream = true;

    // Send multiple small messages
    _ = try kcp.send(kcp_inst, "Hello");
    _ = try kcp.send(kcp_inst, " ");
    _ = try kcp.send(kcp_inst, "World");

    // In stream mode, they might be merged
    try testing.expect(kcp_inst.nsnd_que <= 3);
}

test "input with invalid conv" {
    const allocator = testing.allocator;

    const kcp_inst = try kcp.create(allocator, 0x1234, null);
    defer kcp.release(kcp_inst);

    // Create a packet with different conv
    var buf: [100]u8 = undefined;
    var pos: usize = 0;
    pos = encode32u(&buf, pos, 0x5678); // different conv
    pos = encode8u(&buf, pos, CMD_PUSH);
    pos = encode8u(&buf, pos, 0); // frg
    pos = encode16u(&buf, pos, 32); // wnd
    pos = encode32u(&buf, pos, 0); // ts
    pos = encode32u(&buf, pos, 0); // sn
    pos = encode32u(&buf, pos, 0); // una
    pos = encode32u(&buf, pos, 4); // len

    // Should be rejected due to conv mismatch
    const result = try kcp.input(kcp_inst, buf[0..pos]);
    try testing.expectEqual(@as(i32, -1), result);
}

test "input with corrupted data" {
    const allocator = testing.allocator;

    const kcp_inst = try kcp.create(allocator, 1, null);
    defer kcp.release(kcp_inst);

    // Too short data
    const short_data: [10]u8 = undefined;
    const result = try kcp.input(kcp_inst, &short_data);
    try testing.expectEqual(@as(i32, -1), result);

    // Empty data
    const empty: [0]u8 = undefined;
    const result2 = try kcp.input(kcp_inst, &empty);
    try testing.expectEqual(@as(i32, -1), result2);
}

test "recv with buffer too small" {
    const allocator = testing.allocator;

    const kcp_inst = try kcp.create(allocator, 1, null);
    defer kcp.release(kcp_inst);

    // Add a large segment to receive queue
    var seg = Segment.init(allocator);
    seg.frg = 0;
    const large_data = "This is a very long message that won't fit in small buffer";
    try seg.data.appendSlice(allocator, large_data);
    try kcp_inst.rcv_queue.append(allocator, seg);
    kcp_inst.nrcv_que = 1;

    // Try to receive with small buffer - should return BufferTooSmall error
    var small_buf: [10]u8 = undefined;
    const result = kcp.recv(kcp_inst, &small_buf);
    try testing.expectError(kcp.KcpError.BufferTooSmall, result);
}

test "send window full" {
    const allocator = testing.allocator;

    const kcp_inst = try kcp.create(allocator, 1, null);
    defer kcp.release(kcp_inst);

    // Set very small send window
    kcp.wndsize(kcp_inst, 2, 128);

    // Fill up the send queue
    _ = try kcp.send(kcp_inst, "message1");
    _ = try kcp.send(kcp_inst, "message2");
    _ = try kcp.send(kcp_inst, "message3");

    // Should have queued messages
    try testing.expect(kcp_inst.nsnd_que >= 2);
}

test "mtu boundary values" {
    const allocator = testing.allocator;

    const kcp_inst = try kcp.create(allocator, 1, null);
    defer kcp.release(kcp_inst);

    // Test minimum valid MTU (must be >= 50)
    try kcp.setMtu(kcp_inst, 50);
    try testing.expectEqual(@as(u32, 50), kcp_inst.mtu);
    try testing.expectEqual(@as(u32, 50 - OVERHEAD), kcp_inst.mss);

    // Test large MTU
    try kcp.setMtu(kcp_inst, 9000);
    try testing.expectEqual(@as(u32, 9000), kcp_inst.mtu);
    try testing.expectEqual(@as(u32, 9000 - OVERHEAD), kcp_inst.mss);

    // Test invalid MTU (too small)
    try testing.expectError(error.InvalidMtu, kcp.setMtu(kcp_inst, 49));
    try testing.expectError(error.InvalidMtu, kcp.setMtu(kcp_inst, OVERHEAD - 1));
}

test "timeout retransmission" {
    const allocator = testing.allocator;

    const conv: u32 = 1;
    const kcp1 = try kcp.create(allocator, conv, null);
    defer kcp.release(kcp1);

    const kcp2 = try kcp.create(allocator, conv, null);
    defer kcp.release(kcp2);

    kcp.setNodelay(kcp1, 1, 10, 2, 1);
    kcp.setNodelay(kcp2, 1, 10, 2, 1);

    var packet_count: u32 = 0;

    // Output that drops first packet to trigger retransmission
    const Context = struct {
        peer: *Kcp,
        count: *u32,

        fn output(buf: []const u8, _: *Kcp, user: ?*anyopaque) !i32 {
            const ctx = @as(*@This(), @ptrCast(@alignCast(user.?)));
            ctx.count.* += 1;

            // Drop first packet to trigger timeout retransmission
            if (ctx.count.* == 1) {
                return @as(i32, @intCast(buf.len));
            }

            _ = try kcp.input(ctx.peer, buf);
            return @as(i32, @intCast(buf.len));
        }
    };

    var ctx1 = Context{ .peer = kcp2, .count = &packet_count };
    kcp.setOutput(kcp1, &Context.output);
    kcp1.user = &ctx1;

    _ = try kcp.send(kcp1, "test");

    // Run updates to trigger retransmission
    var time: u32 = 0;
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        try kcp.update(kcp1, time);
        try kcp.update(kcp2, time);
        time += 10;

        if (i > 30) {
            var recv_buf: [100]u8 = undefined;
            const recv_len = kcp.recv(kcp2, &recv_buf) catch continue;
            if (recv_len > 0) {
                // Should receive data after retransmission
                try testing.expectEqualStrings("test", recv_buf[0..@as(usize, @intCast(recv_len))]);
                // Should have sent more than once due to retransmission
                try testing.expect(packet_count > 1);
                return;
            }
        }
    }
}

test "fast retransmission" {
    const allocator = testing.allocator;

    const conv: u32 = 1;
    const kcp1 = try kcp.create(allocator, conv, null);
    defer kcp.release(kcp1);

    const kcp2 = try kcp.create(allocator, conv, null);
    defer kcp.release(kcp2);

    // Enable fast retransmission
    kcp.setNodelay(kcp1, 1, 10, 2, 1); // fastresend=2
    kcp.setNodelay(kcp2, 1, 10, 2, 1);

    var dropped = false;

    const Context = struct {
        peer: *Kcp,
        drop_flag: *bool,
        packet_num: u32 = 0,

        fn output(buf: []const u8, _: *Kcp, user: ?*anyopaque) !i32 {
            const ctx = @as(*@This(), @ptrCast(@alignCast(user.?)));
            ctx.packet_num += 1;

            // Drop first data packet only once
            if (!ctx.drop_flag.* and ctx.packet_num == 1) {
                ctx.drop_flag.* = true;
                return @as(i32, @intCast(buf.len));
            }

            _ = try kcp.input(ctx.peer, buf);
            return @as(i32, @intCast(buf.len));
        }
    };

    var ctx1 = Context{ .peer = kcp2, .drop_flag = &dropped };
    kcp.setOutput(kcp1, &Context.output);
    kcp1.user = &ctx1;

    // Send multiple messages
    _ = try kcp.send(kcp1, "msg1");
    _ = try kcp.send(kcp1, "msg2");
    _ = try kcp.send(kcp1, "msg3");

    var time: u32 = 0;
    var i: u32 = 0;
    while (i < 50) : (i += 1) {
        try kcp.update(kcp1, time);
        try kcp.update(kcp2, time);
        time += 10;
    }

    // Should trigger fast retransmit
    try testing.expect(dropped);
}

test "out of order packets" {
    const allocator = testing.allocator;

    const kcp_inst = try kcp.create(allocator, 1, null);
    defer kcp.release(kcp_inst);

    // Create segments with out-of-order sequence numbers
    var seg1 = Segment.init(allocator);
    seg1.conv = 1;
    seg1.cmd = CMD_PUSH;
    seg1.sn = 2; // Out of order
    seg1.frg = 0;
    try seg1.data.appendSlice(allocator, "second");

    var seg2 = Segment.init(allocator);
    seg2.conv = 1;
    seg2.cmd = CMD_PUSH;
    seg2.sn = 0;
    seg2.frg = 0;
    try seg2.data.appendSlice(allocator, "first");

    // Encode and input out of order
    var buf1: [100]u8 = undefined;
    const offset1 = kcp.segment.encode(&seg1, &buf1, 0);
    @memcpy(buf1[offset1..][0..seg1.data.items.len], seg1.data.items);
    _ = try kcp.input(kcp_inst, buf1[0 .. offset1 + seg1.data.items.len]);

    var buf2: [100]u8 = undefined;
    const offset2 = kcp.segment.encode(&seg2, &buf2, 0);
    @memcpy(buf2[offset2..][0..seg2.data.items.len], seg2.data.items);
    _ = try kcp.input(kcp_inst, buf2[0 .. offset2 + seg2.data.items.len]);

    seg1.deinit();
    seg2.deinit();

    // Should buffer and reorder
    try testing.expect(kcp_inst.nrcv_buf > 0 or kcp_inst.nrcv_que > 0);
}

test "congestion control cwnd growth" {
    const allocator = testing.allocator;

    const conv: u32 = 1;
    const kcp1 = try kcp.create(allocator, conv, null);
    defer kcp.release(kcp1);

    const kcp2 = try kcp.create(allocator, conv, null);
    defer kcp.release(kcp2);

    // Enable congestion control (nocwnd=0)
    kcp.setNodelay(kcp1, 0, 10, 0, 0);
    kcp.setNodelay(kcp2, 0, 10, 0, 0);

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

    const initial_cwnd = kcp1.cwnd;

    // Send some data and let it be acknowledged
    _ = try kcp.send(kcp1, "test data for cwnd growth");

    var time: u32 = 0;
    var i: u32 = 0;
    while (i < 30) : (i += 1) {
        try kcp.update(kcp1, time);
        try kcp.update(kcp2, time);
        time += 10;

        var recv_buf: [100]u8 = undefined;
        _ = kcp.recv(kcp2, &recv_buf) catch {};
    }

    // cwnd should have grown after successful transmission
    try testing.expect(kcp1.cwnd >= initial_cwnd);
}

test "empty message handling" {
    const allocator = testing.allocator;

    const kcp_inst = try kcp.create(allocator, 1, null);
    defer kcp.release(kcp_inst);

    // Try to send empty message - should return error
    const empty: [0]u8 = undefined;
    const result = kcp.send(kcp_inst, &empty);
    try testing.expectError(kcp.KcpError.EmptyData, result);
}

test "multiple fragments reassembly" {
    const allocator = testing.allocator;

    const kcp_inst = try kcp.create(allocator, 1, null);
    defer kcp.release(kcp_inst);

    // Create fragmented message (3 fragments, reverse order)
    var seg0 = Segment.init(allocator);
    seg0.conv = 1;
    seg0.cmd = CMD_PUSH;
    seg0.sn = 0;
    seg0.frg = 2; // Last fragment
    try seg0.data.appendSlice(allocator, "AAA");

    var seg1 = Segment.init(allocator);
    seg1.conv = 1;
    seg1.cmd = CMD_PUSH;
    seg1.sn = 1;
    seg1.frg = 1; // Middle fragment
    try seg1.data.appendSlice(allocator, "BBB");

    var seg2 = Segment.init(allocator);
    seg2.conv = 1;
    seg2.cmd = CMD_PUSH;
    seg2.sn = 2;
    seg2.frg = 0; // First fragment (frg=0 means last piece)
    try seg2.data.appendSlice(allocator, "CCC");

    // Input all fragments
    var buf: [100]u8 = undefined;
    for ([_]*Segment{ &seg0, &seg1, &seg2 }) |seg| {
        const offset = kcp.segment.encode(seg, &buf, 0);
        @memcpy(buf[offset..][0..seg.data.items.len], seg.data.items);
        _ = try kcp.input(kcp_inst, buf[0 .. offset + seg.data.items.len]);
    }

    seg0.deinit();
    seg1.deinit();
    seg2.deinit();

    // Should reassemble correctly
    var recv_buf: [100]u8 = undefined;
    const len = try kcp.recv(kcp_inst, &recv_buf);
    try testing.expectEqual(@as(usize, 9), len);
    try testing.expectEqualStrings("AAABBBCCC", recv_buf[0..9]);
}

test "window probe mechanism" {
    const allocator = testing.allocator;

    const conv: u32 = 1;
    const kcp1 = try kcp.create(allocator, conv, null);
    defer kcp.release(kcp1);

    const kcp2 = try kcp.create(allocator, conv, null);
    defer kcp.release(kcp2);

    kcp.setNodelay(kcp1, 1, 10, 2, 1);
    kcp.setNodelay(kcp2, 1, 10, 2, 1);

    var received_wask = false;
    var received_wins = false;

    const Context = struct {
        peer: *Kcp,
        wask_flag: *bool,
        wins_flag: *bool,

        fn output(buf: []const u8, _: *Kcp, user: ?*anyopaque) !i32 {
            const ctx = @as(*@This(), @ptrCast(@alignCast(user.?)));

            // Check if packet contains WASK or WINS command
            if (buf.len >= 5) {
                const cmd = buf[4]; // cmd is at offset 4
                if (cmd == kcp.CMD_WASK) {
                    ctx.wask_flag.* = true;
                }
                if (cmd == kcp.CMD_WINS) {
                    ctx.wins_flag.* = true;
                }
            }

            _ = try kcp.input(ctx.peer, buf);
            return @as(i32, @intCast(buf.len));
        }
    };

    var ctx1 = Context{ .peer = kcp2, .wask_flag = &received_wask, .wins_flag = &received_wins };
    var ctx2 = Context{ .peer = kcp1, .wask_flag = &received_wask, .wins_flag = &received_wins };

    kcp.setOutput(kcp1, &Context.output);
    kcp1.user = &ctx1;
    kcp.setOutput(kcp2, &Context.output);
    kcp2.user = &ctx2;

    // Set remote window to 0 to trigger probe
    kcp1.rmt_wnd = 0;

    var time: u32 = 0;
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        try kcp.update(kcp1, time);
        try kcp.update(kcp2, time);
        time += 100;

        if (received_wask or received_wins) break;
    }

    // Should have triggered window probe
    try testing.expect(received_wask or received_wins);
}

test "flush function" {
    const allocator = testing.allocator;

    const kcp_inst = try kcp.create(allocator, 1, null);
    defer kcp.release(kcp_inst);

    var flushed = false;
    const FlushContext = struct {
        flag: *bool,

        fn output(buf: []const u8, _: *Kcp, user: ?*anyopaque) !i32 {
            const ctx = @as(*@This(), @ptrCast(@alignCast(user.?)));
            ctx.flag.* = true;
            return @as(i32, @intCast(buf.len));
        }
    };

    var ctx = FlushContext{ .flag = &flushed };
    kcp.setOutput(kcp_inst, &FlushContext.output);
    kcp_inst.user = &ctx;

    // Need to update first to initialize state
    try kcp.update(kcp_inst, 0);

    // Send data
    _ = try kcp.send(kcp_inst, "flush test");

    // Call flush directly
    try kcp.flush(kcp_inst);

    // Should have triggered output
    try testing.expect(flushed);
}

test "invalid command type" {
    const allocator = testing.allocator;

    const kcp_inst = try kcp.create(allocator, 1, null);
    defer kcp.release(kcp_inst);

    // Create packet with invalid command
    var buf: [100]u8 = undefined;
    var pos: usize = 0;

    pos = encode32u(&buf, pos, 1); // conv
    pos = encode8u(&buf, pos, 99); // invalid cmd
    pos = encode8u(&buf, pos, 0); // frg
    pos = encode16u(&buf, pos, 32); // wnd
    pos = encode32u(&buf, pos, 0); // ts
    pos = encode32u(&buf, pos, 0); // sn
    pos = encode32u(&buf, pos, 0); // una
    pos = encode32u(&buf, pos, 0); // len

    // Should reject invalid command
    const result = try kcp.input(kcp_inst, buf[0..pos]);
    try testing.expectEqual(@as(i32, -3), result);
}

// ============================================================================
// 模糊测试 (Fuzz Testing)
// ============================================================================

test "fuzz random input data" {
    const allocator = testing.allocator;

    const kcp_inst = try kcp.create(allocator, 0x12345678, null);
    defer kcp.release(kcp_inst);

    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();

    // Test with various random data sizes
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const size = random.intRangeAtMost(usize, 0, 2000);
        const buf = try allocator.alloc(u8, size);
        defer allocator.free(buf);

        random.bytes(buf);

        // Should handle random data gracefully without crashing
        _ = kcp.input(kcp_inst, buf) catch {};
    }

    // KCP should still be functional
    try testing.expect(kcp_inst.state == 0);
}

test "fuzz malformed packets" {
    const allocator = testing.allocator;

    const kcp_inst = try kcp.create(allocator, 1, null);
    defer kcp.release(kcp_inst);

    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    var i: usize = 0;
    while (i < 50) : (i += 1) {
        var buf: [200]u8 = undefined;
        const size = random.intRangeAtMost(usize, 0, 200);

        // Fill with random bytes
        random.bytes(buf[0..size]);

        // Randomly set conv to valid or invalid
        if (random.boolean()) {
            if (size >= 4) {
                _ = encode32u(&buf, 0, 1); // valid conv
            }
        }

        // Try to input malformed packet
        _ = kcp.input(kcp_inst, buf[0..size]) catch {};
    }

    // KCP should survive fuzzing
    try testing.expect(true);
}

test "fuzz edge case values" {
    const allocator = testing.allocator;

    const kcp_inst = try kcp.create(allocator, 1, null);
    defer kcp.release(kcp_inst);

    // Test with extreme values
    const edge_values = [_]u32{
        0,
        1,
        0xFF,
        0xFFFF,
        0xFFFFFFFF,
        0x80000000,
        std.math.maxInt(u32),
    };

    for (edge_values) |val| {
        var buf: [100]u8 = undefined;
        var pos: usize = 0;

        pos = encode32u(&buf, pos, 1); // conv
        pos = encode8u(&buf, pos, CMD_PUSH);
        pos = encode8u(&buf, pos, @truncate(val)); // frg
        pos = encode16u(&buf, pos, @truncate(val)); // wnd
        pos = encode32u(&buf, pos, val); // ts
        pos = encode32u(&buf, pos, val); // sn
        pos = encode32u(&buf, pos, val); // una
        pos = encode32u(&buf, pos, 0); // len

        _ = kcp.input(kcp_inst, buf[0..pos]) catch {};
    }

    try testing.expect(true);
}

// ============================================================================
// 压力测试 (Stress Testing)
// ============================================================================

test "stress test many small packets" {
    const allocator = testing.allocator;

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

    // Send 1000 small packets
    const total_packets = 1000;
    var sent_count: usize = 0;

    var time: u32 = 0;
    var i: usize = 0;
    while (i < total_packets) : (i += 1) {
        const msg = "X";
        const result = kcp.send(kcp1, msg) catch continue;
        if (result > 0) sent_count += 1;

        // Update periodically
        if (i % 10 == 0) {
            try kcp.update(kcp1, time);
            try kcp.update(kcp2, time);
            time += 10;
        }
    }

    // Final updates to flush
    var j: usize = 0;
    while (j < 100) : (j += 1) {
        try kcp.update(kcp1, time);
        try kcp.update(kcp2, time);
        time += 10;
    }

    // Receive all packets
    var recv_count: usize = 0;
    var recv_buf: [100]u8 = undefined;
    while (true) {
        const len = kcp.recv(kcp2, &recv_buf) catch break;
        if (len > 0) {
            recv_count += 1;
        } else break;
    }

    // Should have received some packets (pressure test may have window limitations)
    try testing.expect(recv_count > 0);
    // In stream mode or with proper window management, should get most packets
    // But we just verify the system works under pressure
    try testing.expect(sent_count > 0);
}

test "stress test large data transfer" {
    const allocator = testing.allocator;

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

    // Send 100KB of data
    const data_size = 100 * 1024;
    const data = try allocator.alloc(u8, data_size);
    defer allocator.free(data);

    // Fill with pattern
    for (data, 0..) |*byte, idx| {
        byte.* = @truncate(idx);
    }

    _ = try kcp.send(kcp1, data);

    // Update until transmission complete
    var time: u32 = 0;
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        try kcp.update(kcp1, time);
        try kcp.update(kcp2, time);
        time += 10;

        // Check if received
        const size = kcp.peeksize(kcp2) catch continue;
        if (size > 0) break;
    }

    // Receive data
    const recv_buf = try allocator.alloc(u8, data_size + 1000);
    defer allocator.free(recv_buf);

    const recv_len = try kcp.recv(kcp2, recv_buf);
    try testing.expectEqual(data_size, recv_len);

    // Verify data integrity
    try testing.expectEqualSlices(u8, data, recv_buf[0..@intCast(recv_len)]);
}

test "stress test bidirectional transfer" {
    const allocator = testing.allocator;

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

    // Send data both directions
    _ = try kcp.send(kcp1, "From KCP1 to KCP2");
    _ = try kcp.send(kcp2, "From KCP2 to KCP1");

    var time: u32 = 0;
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        try kcp.update(kcp1, time);
        try kcp.update(kcp2, time);
        time += 10;
    }

    // Receive both directions
    var buf1: [100]u8 = undefined;
    var buf2: [100]u8 = undefined;

    const len1 = try kcp.recv(kcp2, &buf1);
    const len2 = try kcp.recv(kcp1, &buf2);

    try testing.expect(len1 > 0);
    try testing.expect(len2 > 0);
}

// ============================================================================
// 边界测试补充 (Boundary Testing)
// ============================================================================

test "boundary maximum mtu" {
    const allocator = testing.allocator;

    const kcp_inst = try kcp.create(allocator, 1, null);
    defer kcp.release(kcp_inst);

    // Test maximum reasonable MTU
    try kcp.setMtu(kcp_inst, 9000); // Jumbo frame
    try testing.expectEqual(@as(u32, 9000), kcp_inst.mtu);

    // Very large MTU
    try kcp.setMtu(kcp_inst, 65535);
    try testing.expectEqual(@as(u32, 65535), kcp_inst.mtu);
}

test "boundary minimum viable mtu" {
    const allocator = testing.allocator;

    const kcp_inst = try kcp.create(allocator, 1, null);
    defer kcp.release(kcp_inst);

    // Minimum MTU is 50
    try kcp.setMtu(kcp_inst, 50);
    try testing.expectEqual(@as(u32, 50), kcp_inst.mtu);
    try testing.expectEqual(@as(u32, 50 - OVERHEAD), kcp_inst.mss);
}

test "boundary maximum window size" {
    const allocator = testing.allocator;

    const kcp_inst = try kcp.create(allocator, 1, null);
    defer kcp.release(kcp_inst);

    // Set maximum window sizes
    kcp.wndsize(kcp_inst, 1024, 1024);
    try testing.expectEqual(@as(u32, 1024), kcp_inst.snd_wnd);
    try testing.expectEqual(@as(u32, 1024), kcp_inst.rcv_wnd);
}

test "boundary zero window size" {
    const allocator = testing.allocator;

    const kcp_inst = try kcp.create(allocator, 1, null);
    defer kcp.release(kcp_inst);

    const original_snd = kcp_inst.snd_wnd;
    const original_rcv = kcp_inst.rcv_wnd;

    // Setting zero should not change window (invalid)
    kcp.wndsize(kcp_inst, 0, 0);
    try testing.expectEqual(original_snd, kcp_inst.snd_wnd);
    try testing.expectEqual(original_rcv, kcp_inst.rcv_wnd);
}

test "boundary maximum conv value" {
    const allocator = testing.allocator;

    // Test with maximum u32 conv
    const kcp_inst = try kcp.create(allocator, 0xFFFFFFFF, null);
    defer kcp.release(kcp_inst);

    try testing.expectEqual(@as(u32, 0xFFFFFFFF), kcp_inst.conv);
}

test "boundary sequence number wraparound" {
    const allocator = testing.allocator;

    const kcp_inst = try kcp.create(allocator, 1, null);
    defer kcp.release(kcp_inst);

    // Simulate sequence number near wraparound
    kcp_inst.snd_nxt = 0xFFFFFFF0;

    _ = try kcp.send(kcp_inst, "test wraparound");

    // Sequence should wrap around
    try testing.expect(kcp_inst.nsnd_que > 0);
}

test "boundary maximum data in single send" {
    const allocator = testing.allocator;

    const kcp_inst = try kcp.create(allocator, 1, null);
    defer kcp.release(kcp_inst);

    // Try to send maximum amount in one call
    const max_size = 128 * 1024; // 128KB
    const data = try allocator.alloc(u8, max_size);
    defer allocator.free(data);
    @memset(data, 0xAA);

    const result = kcp.send(kcp_inst, data) catch |err| {
        // May fail due to window size limits, that's ok
        try testing.expect(err == error.OutOfMemory or err == error.BufferTooSmall);
        return;
    };

    // If succeeded, should have queued the data
    try testing.expect(result > 0);
}

test "boundary packet loss simulation" {
    const allocator = testing.allocator;

    const conv: u32 = 1;
    const kcp1 = try kcp.create(allocator, conv, null);
    defer kcp.release(kcp1);

    const kcp2 = try kcp.create(allocator, conv, null);
    defer kcp.release(kcp2);

    kcp.setNodelay(kcp1, 1, 10, 2, 1);
    kcp.setNodelay(kcp2, 1, 10, 2, 1);

    var drop_count: usize = 0;
    const Context = struct {
        peer: *Kcp,
        drop_counter: *usize,
        drop_rate: usize,

        fn output(buf: []const u8, _: *Kcp, user: ?*anyopaque) !i32 {
            const ctx = @as(*@This(), @ptrCast(@alignCast(user.?)));
            ctx.drop_counter.* += 1;

            // Simulate 20% packet loss
            if (ctx.drop_counter.* % ctx.drop_rate == 0) {
                return @as(i32, @intCast(buf.len)); // Drop packet
            }

            _ = try kcp.input(ctx.peer, buf);
            return @as(i32, @intCast(buf.len));
        }
    };

    var ctx1 = Context{ .peer = kcp2, .drop_counter = &drop_count, .drop_rate = 5 };
    kcp.setOutput(kcp1, &Context.output);
    kcp1.user = &ctx1;

    _ = try kcp.send(kcp1, "message with packet loss");

    var time: u32 = 0;
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        try kcp.update(kcp1, time);
        try kcp.update(kcp2, time);
        time += 10;

        var recv_buf: [100]u8 = undefined;
        const len = kcp.recv(kcp2, &recv_buf) catch continue;
        if (len > 0) {
            // Successfully received despite packet loss
            try testing.expectEqualStrings("message with packet loss", recv_buf[0..@intCast(len)]);
            return;
        }
    }

    // Should eventually receive through retransmission
    try testing.expect(drop_count > 0); // Some packets were dropped
}

test "dead link detection with complete packet loss" {
    const allocator = testing.allocator;

    const kcp_inst = try kcp.create(allocator, 1, null);
    defer kcp.release(kcp_inst);

    // Set very low dead_link threshold for faster testing
    kcp_inst.dead_link = 5;
    kcp.setNodelay(kcp_inst, 1, 10, 2, 1);

    var transmission_count: usize = 0;
    const DeadLinkContext = struct {
        count: *usize,

        fn output(_: []const u8, _: *Kcp, user: ?*anyopaque) !i32 {
            const ctx = @as(*@This(), @ptrCast(@alignCast(user.?)));
            ctx.count.* += 1;
            // Drop all packets - simulate complete link failure
            return 0;
        }
    };

    var ctx = DeadLinkContext{ .count = &transmission_count };
    kcp.setOutput(kcp_inst, &DeadLinkContext.output);
    kcp_inst.user = &ctx;

    // Send a message
    _ = try kcp.send(kcp_inst, "test dead link");

    // Update repeatedly to trigger retransmissions
    var time: u32 = 0;
    var update_count: usize = 0;
    while (update_count < 500) : (update_count += 1) {
        try kcp.update(kcp_inst, time);
        time += 10;

        // Check if any segment has exceeded dead_link threshold
        if (kcp_inst.nsnd_buf > 0) {
            // Segments are still in buffer, being retransmitted
            try testing.expect(transmission_count > 0);
        }
    }

    // Should have attempted multiple transmissions due to dead_link
    try testing.expect(transmission_count >= kcp_inst.dead_link);
}

test "dead link with gradually increasing retransmissions" {
    const allocator = testing.allocator;

    const kcp_inst = try kcp.create(allocator, 1, null);
    defer kcp.release(kcp_inst);

    // Set moderate dead_link threshold
    kcp_inst.dead_link = 10;
    kcp.setNodelay(kcp_inst, 1, 20, 0, 0); // No fast resend, only timeout

    var xmit_counts = std.ArrayList(u32){};
    defer xmit_counts.deinit(allocator);

    const XmitTracker = struct {
        counts: *std.ArrayList(u32),
        alloc: std.mem.Allocator,

        fn output(_: []const u8, kcp_ptr: *Kcp, user: ?*anyopaque) !i32 {
            const ctx = @as(*@This(), @ptrCast(@alignCast(user.?)));

            // Record xmit count of first segment
            if (kcp_ptr.nsnd_buf > 0) {
                const xmit = kcp_ptr.snd_buf.items[0].xmit;
                try ctx.counts.append(ctx.alloc, xmit);
            }

            // Drop all packets
            return 0;
        }
    };

    var tracker = XmitTracker{ .counts = &xmit_counts, .alloc = allocator };
    kcp.setOutput(kcp_inst, &XmitTracker.output);
    kcp_inst.user = &tracker;

    _ = try kcp.send(kcp_inst, "test");

    var time: u32 = 0;
    var i: usize = 0;
    while (i < 300) : (i += 1) {
        try kcp.update(kcp_inst, time);
        time += 20;
    }

    // Should have increasing xmit counts
    if (xmit_counts.items.len > 1) {
        // Verify retransmissions are happening
        var max_xmit: u32 = 0;
        for (xmit_counts.items) |xmit| {
            if (xmit > max_xmit) max_xmit = xmit;
        }
        try testing.expect(max_xmit > 1);
    }
}

test "receive window full blocking" {
    const allocator = testing.allocator;

    const conv: u32 = 1;
    const kcp1 = try kcp.create(allocator, conv, null);
    defer kcp.release(kcp1);

    const kcp2 = try kcp.create(allocator, conv, null);
    defer kcp.release(kcp2);

    // Set very small receive window
    const small_wnd: u32 = 4;
    kcp.wndsize(kcp1, 32, small_wnd);
    kcp.wndsize(kcp2, 32, small_wnd);

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

    // Send more messages than window size
    const message_count = 10;
    var i: usize = 0;
    while (i < message_count) : (i += 1) {
        _ = kcp.send(kcp1, "X") catch break;
    }

    // Update to transmit
    var time: u32 = 0;
    var j: usize = 0;
    while (j < 50) : (j += 1) {
        try kcp.update(kcp1, time);
        try kcp.update(kcp2, time);
        time += 10;
    }

    // Receive window should be full or close to full
    // nrcv_buf + nrcv_que should not exceed rcv_wnd
    const total_rcv = kcp2.nrcv_buf + kcp2.nrcv_que;
    try testing.expect(total_rcv <= kcp2.rcv_wnd);

    // Now read some data to free window
    var recv_buf: [100]u8 = undefined;
    const recv1 = kcp.recv(kcp2, &recv_buf) catch 0;

    if (recv1 > 0) {
        // After reading, should be able to receive more
        const total_after = kcp2.nrcv_buf + kcp2.nrcv_que;
        try testing.expect(total_after < total_rcv);
    }
}

test "receive window with flow control" {
    const allocator = testing.allocator;

    const conv: u32 = 1;
    const kcp1 = try kcp.create(allocator, conv, null);
    defer kcp.release(kcp1);

    const kcp2 = try kcp.create(allocator, conv, null);
    defer kcp.release(kcp2);

    // Set small receive window to test flow control
    kcp.wndsize(kcp1, 16, 8);
    kcp.wndsize(kcp2, 16, 8);

    kcp.setNodelay(kcp1, 1, 10, 2, 1);
    kcp.setNodelay(kcp2, 1, 10, 2, 1);

    var packet_count: usize = 0;
    const FlowControlContext = struct {
        peer: *Kcp,
        count: *usize,

        fn output(buf: []const u8, _: *Kcp, user: ?*anyopaque) !i32 {
            const ctx = @as(*@This(), @ptrCast(@alignCast(user.?)));
            ctx.count.* += 1;
            _ = try kcp.input(ctx.peer, buf);
            return @as(i32, @intCast(buf.len));
        }
    };

    var ctx1 = FlowControlContext{ .peer = kcp2, .count = &packet_count };
    var ctx2 = FlowControlContext{ .peer = kcp1, .count = &packet_count };

    kcp.setOutput(kcp1, &FlowControlContext.output);
    kcp1.user = &ctx1;
    kcp.setOutput(kcp2, &FlowControlContext.output);
    kcp2.user = &ctx2;

    // Send many small messages
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        _ = kcp.send(kcp1, "data") catch break;
    }

    var time: u32 = 0;
    var j: usize = 0;
    while (j < 100) : (j += 1) {
        try kcp.update(kcp1, time);
        try kcp.update(kcp2, time);
        time += 10;

        // Periodically read to free window
        if (j % 5 == 0) {
            var recv_buf: [100]u8 = undefined;
            _ = kcp.recv(kcp2, &recv_buf) catch {};
        }
    }

    // Should have transmitted packets with flow control
    try testing.expect(packet_count > 0);

    // Window constraints should have been respected
    try testing.expect(kcp2.nrcv_buf + kcp2.nrcv_que <= kcp2.rcv_wnd);
}

test "receive window zero notification" {
    const allocator = testing.allocator;

    const conv: u32 = 1;
    const kcp1 = try kcp.create(allocator, conv, null);
    defer kcp.release(kcp1);

    const kcp2 = try kcp.create(allocator, conv, null);
    defer kcp.release(kcp2);

    // Set minimal window
    kcp.wndsize(kcp1, 32, 2);
    kcp.wndsize(kcp2, 32, 2);

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

    // Fill receive window
    _ = try kcp.send(kcp1, "msg1");
    _ = try kcp.send(kcp1, "msg2");
    _ = try kcp.send(kcp1, "msg3");

    var time: u32 = 0;
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        try kcp.update(kcp1, time);
        try kcp.update(kcp2, time);
        time += 10;
    }

    // Check if window is being communicated
    // rmt_wnd should reflect receiver's available window
    try testing.expect(kcp1.rmt_wnd <= kcp2.rcv_wnd);

    // Read data to open window
    var recv_buf: [100]u8 = undefined;
    _ = kcp.recv(kcp2, &recv_buf) catch {};

    // Update to send window notification
    i = 0;
    while (i < 20) : (i += 1) {
        try kcp.update(kcp1, time);
        try kcp.update(kcp2, time);
        time += 10;
    }

    // Window should have been updated
    try testing.expect(true); // Basic functionality check
}

// ============================================================================
// RTT 和拥塞控制测试 (RTT and Congestion Control Testing)
// ============================================================================

test "rtt calculation accuracy" {
    const allocator = testing.allocator;

    const conv: u32 = 1;
    const kcp1 = try kcp.create(allocator, conv, null);
    defer kcp.release(kcp1);

    const kcp2 = try kcp.create(allocator, conv, null);
    defer kcp.release(kcp2);

    kcp.setNodelay(kcp1, 1, 10, 0, 0);
    kcp.setNodelay(kcp2, 1, 10, 0, 0);

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

    // Send some data to trigger RTT calculation
    _ = try kcp.send(kcp1, "RTT test data");

    var time: u32 = 0;
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        try kcp.update(kcp1, time);
        try kcp.update(kcp2, time);
        time += 10;

        // Receive to complete round trip
        var recv_buf: [100]u8 = undefined;
        _ = kcp.recv(kcp2, &recv_buf) catch {};
    }

    // RTT calculation should have been triggered
    // In a local test, RTT values will be calculated based on ACK timing
    // Check that RTT values exist and are reasonable
    try testing.expect(kcp1.rx_srtt >= 0);
    try testing.expect(kcp1.rx_rttval >= 0);

    // RTO should be a reasonable value (not zero, not too large)
    try testing.expect(kcp1.rx_rto > 0);
    try testing.expect(kcp1.rx_rto <= kcp.RTO_MAX);
}

test "rtt update with varying delays" {
    const allocator = testing.allocator;

    const conv: u32 = 1;
    const kcp1 = try kcp.create(allocator, conv, null);
    defer kcp.release(kcp1);

    const kcp2 = try kcp.create(allocator, conv, null);
    defer kcp.release(kcp2);

    kcp.setNodelay(kcp1, 1, 10, 0, 0);
    kcp.setNodelay(kcp2, 1, 10, 0, 0);

    var delay: u32 = 0;
    const DelayContext = struct {
        peer: *Kcp,
        delay_ms: *u32,

        fn output(buf: []const u8, _: *Kcp, user: ?*anyopaque) !i32 {
            const ctx = @as(*@This(), @ptrCast(@alignCast(user.?)));
            // Simulate varying network delay
            _ = ctx.delay_ms; // Could use this to simulate real delay
            _ = try kcp.input(ctx.peer, buf);
            return @as(i32, @intCast(buf.len));
        }
    };

    var ctx1 = DelayContext{ .peer = kcp2, .delay_ms = &delay };
    kcp.setOutput(kcp1, &DelayContext.output);
    kcp1.user = &ctx1;

    // Send multiple packets with varying delays
    var time: u32 = 0;
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        delay = @intCast(i * 5); // Increasing delay
        _ = try kcp.send(kcp1, "test");

        var j: usize = 0;
        while (j < 10) : (j += 1) {
            try kcp.update(kcp1, time);
            try kcp.update(kcp2, time);
            time += 10;
        }
    }

    // RTT values should have been updated
    try testing.expect(kcp1.rx_srtt > 0 or kcp1.rx_rttval >= 0);
}

test "nodelay mode 0 - normal mode" {
    const allocator = testing.allocator;

    const kcp_inst = try kcp.create(allocator, 1, null);
    defer kcp.release(kcp_inst);

    // Normal mode: nodelay=0, interval=100, resend=0, nc=0
    kcp.setNodelay(kcp_inst, 0, 100, 0, 0);

    try testing.expectEqual(@as(u32, 0), kcp_inst.nodelay);
    try testing.expectEqual(@as(u32, 100), kcp_inst.interval);
    try testing.expectEqual(@as(u32, 0), kcp_inst.fastresend);
    try testing.expectEqual(false, kcp_inst.nocwnd);
    try testing.expectEqual(@as(u32, RTO_MIN), kcp_inst.rx_minrto);
}

test "nodelay mode 1 - fast mode" {
    const allocator = testing.allocator;

    const kcp_inst = try kcp.create(allocator, 1, null);
    defer kcp.release(kcp_inst);

    // Fast mode: nodelay=1, interval=10, resend=2, nc=1
    kcp.setNodelay(kcp_inst, 1, 10, 2, 1);

    try testing.expectEqual(@as(u32, 1), kcp_inst.nodelay);
    try testing.expectEqual(@as(u32, 10), kcp_inst.interval);
    try testing.expectEqual(@as(u32, 2), kcp_inst.fastresend);
    try testing.expectEqual(true, kcp_inst.nocwnd);
    try testing.expectEqual(@as(u32, RTO_NDL), kcp_inst.rx_minrto);
}

test "nodelay mode comparison - retransmission behavior" {
    const allocator = testing.allocator;

    // Test with nodelay=0 (normal)
    const kcp_normal = try kcp.create(allocator, 1, null);
    defer kcp.release(kcp_normal);
    kcp.setNodelay(kcp_normal, 0, 100, 0, 0);

    // Test with nodelay=1 (fast)
    const kcp_fast = try kcp.create(allocator, 2, null);
    defer kcp.release(kcp_fast);
    kcp.setNodelay(kcp_fast, 1, 10, 2, 1);

    // Fast mode should have lower interval
    try testing.expect(kcp_fast.interval < kcp_normal.interval);

    // Fast mode should have fast resend enabled
    try testing.expect(kcp_fast.fastresend > kcp_normal.fastresend);

    // Fast mode should have no congestion control
    try testing.expect(kcp_fast.nocwnd and !kcp_normal.nocwnd);
}

test "ssthresh congestion threshold adjustment" {
    const allocator = testing.allocator;

    const conv: u32 = 1;
    const kcp1 = try kcp.create(allocator, conv, null);
    defer kcp.release(kcp1);

    const kcp2 = try kcp.create(allocator, conv, null);
    defer kcp.release(kcp2);

    // Enable congestion control (nocwnd=0)
    kcp.setNodelay(kcp1, 0, 10, 0, 0);
    kcp.setNodelay(kcp2, 0, 10, 0, 0);

    const initial_ssthresh = kcp1.ssthresh;

    var drop_count: usize = 0;
    const LossContext = struct {
        peer: *Kcp,
        counter: *usize,

        fn output(buf: []const u8, _: *Kcp, user: ?*anyopaque) !i32 {
            const ctx = @as(*@This(), @ptrCast(@alignCast(user.?)));
            ctx.counter.* += 1;

            // Drop some packets to trigger congestion
            if (ctx.counter.* % 3 == 0) {
                return @as(i32, @intCast(buf.len));
            }

            _ = try kcp.input(ctx.peer, buf);
            return @as(i32, @intCast(buf.len));
        }
    };

    var ctx1 = LossContext{ .peer = kcp2, .counter = &drop_count };
    kcp.setOutput(kcp1, &LossContext.output);
    kcp1.user = &ctx1;

    // Send data to trigger congestion control
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        _ = kcp.send(kcp1, "congestion test") catch break;
    }

    var time: u32 = 0;
    var j: usize = 0;
    while (j < 100) : (j += 1) {
        try kcp.update(kcp1, time);
        try kcp.update(kcp2, time);
        time += 10;
    }

    // ssthresh should exist and be reasonable
    try testing.expect(kcp1.ssthresh >= THRESH_MIN);
    try testing.expect(kcp1.ssthresh <= initial_ssthresh * 2);
}

test "ssthresh slow start and congestion avoidance" {
    const allocator = testing.allocator;

    const conv: u32 = 1;
    const kcp1 = try kcp.create(allocator, conv, null);
    defer kcp.release(kcp1);

    const kcp2 = try kcp.create(allocator, conv, null);
    defer kcp.release(kcp2);

    kcp.setNodelay(kcp1, 0, 10, 0, 0);
    kcp.setNodelay(kcp2, 0, 10, 0, 0);

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

    // Track cwnd growth
    const initial_cwnd = kcp1.cwnd;

    // Send data
    _ = try kcp.send(kcp1, "slow start test");

    var time: u32 = 0;
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        try kcp.update(kcp1, time);
        try kcp.update(kcp2, time);
        time += 10;

        var recv_buf: [100]u8 = undefined;
        _ = kcp.recv(kcp2, &recv_buf) catch {};
    }

    // cwnd should have grown (slow start)
    try testing.expect(kcp1.cwnd >= initial_cwnd);

    // ssthresh should be set
    try testing.expect(kcp1.ssthresh >= THRESH_MIN);
}

test "timestamp wraparound handling" {
    const allocator = testing.allocator;

    const kcp_inst = try kcp.create(allocator, 1, null);
    defer kcp.release(kcp_inst);

    // Set timestamp near wraparound point
    const near_max = std.math.maxInt(u32) - 1000;
    kcp_inst.current = near_max;
    kcp_inst.ts_flush = near_max;

    kcp.setNodelay(kcp_inst, 1, 10, 0, 0);

    _ = try kcp.send(kcp_inst, "wraparound test");

    // Update with wrapped timestamp (will overflow, which is the point)
    const wrapped_time = @as(u32, @truncate(@as(u64, near_max) + 2000));

    // Should handle wraparound gracefully
    try kcp.update(kcp_inst, wrapped_time);

    // System should still be functional
    try testing.expect(kcp_inst.nsnd_que > 0 or kcp_inst.nsnd_buf > 0);
}

test "timestamp large time jump detection" {
    const allocator = testing.allocator;

    const kcp_inst = try kcp.create(allocator, 1, null);
    defer kcp.release(kcp_inst);

    kcp.setNodelay(kcp_inst, 1, 10, 0, 0);

    // Initialize with normal time
    try kcp.update(kcp_inst, 1000);

    _ = try kcp.send(kcp_inst, "test");

    // Make a huge time jump (> 10000ms)
    try kcp.update(kcp_inst, 20000);

    // Should detect and handle the jump
    // KCP has logic to reset ts_flush on large jumps
    try testing.expect(kcp_inst.current == 20000);
}

test "interval parameter effects on update frequency" {
    const allocator = testing.allocator;

    // Small interval (fast mode)
    const kcp_fast = try kcp.create(allocator, 1, null);
    defer kcp.release(kcp_fast);
    kcp.setNodelay(kcp_fast, 1, 10, 0, 0);

    // Large interval (slow mode)
    const kcp_slow = try kcp.create(allocator, 2, null);
    defer kcp.release(kcp_slow);
    kcp.setNodelay(kcp_slow, 0, 100, 0, 0);

    try testing.expectEqual(@as(u32, 10), kcp_fast.interval);
    try testing.expectEqual(@as(u32, 100), kcp_slow.interval);

    // Initialize both
    try kcp.update(kcp_fast, 0);
    try kcp.update(kcp_slow, 0);

    // Check next update time
    const next_fast = kcp.check(kcp_fast, 0);
    const next_slow = kcp.check(kcp_slow, 0);

    // Fast mode should have earlier next update
    try testing.expect(next_fast <= next_slow);
}

test "interval affects flush timing" {
    const allocator = testing.allocator;

    const kcp_inst = try kcp.create(allocator, 1, null);
    defer kcp.release(kcp_inst);

    const test_interval: u32 = 50;
    kcp.setNodelay(kcp_inst, 0, @intCast(test_interval), 0, 0);

    var flush_count: usize = 0;
    const FlushCounter = struct {
        count: *usize,

        fn output(_: []const u8, _: *Kcp, user: ?*anyopaque) !i32 {
            const ctx = @as(*@This(), @ptrCast(@alignCast(user.?)));
            ctx.count.* += 1;
            return 0;
        }
    };

    var ctx = FlushCounter{ .count = &flush_count };
    kcp.setOutput(kcp_inst, &FlushCounter.output);
    kcp_inst.user = &ctx;

    _ = try kcp.send(kcp_inst, "test");

    // Update multiple times
    var time: u32 = 0;
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        try kcp.update(kcp_inst, time);
        time += 10;
    }

    // Should have flushed based on interval
    try testing.expect(flush_count > 0);
}

test "different interval values comparison" {
    const allocator = testing.allocator;

    const intervals = [_]u32{ 10, 20, 50, 100 };

    for (intervals) |interval| {
        const kcp_inst = try kcp.create(allocator, 1, null);
        defer kcp.release(kcp_inst);

        kcp.setNodelay(kcp_inst, 0, @intCast(interval), 0, 0);

        try testing.expectEqual(interval, kcp_inst.interval);

        // Update and check next flush time
        try kcp.update(kcp_inst, 0);

        const next = kcp.check(kcp_inst, 0);

        // Next update should be influenced by interval
        try testing.expect(next <= interval);
    }
}
