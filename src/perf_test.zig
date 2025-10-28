//=====================================================================
//
// perf_test.zig - Performance and Integration Tests for KCP Protocol
//
// Similar to test.cpp in the original KCP project, this file tests
// KCP performance under simulated network conditions with different modes.
//
//=====================================================================

const std = @import("std");
const kcp = @import("kcp.zig");

// Network packet simulator for delay and packet loss
const DelayPacket = struct {
    data: []u8,
    timestamp: i64,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, buf: []const u8, ts: i64) !DelayPacket {
        const data = try allocator.alloc(u8, buf.len);
        @memcpy(data, buf);
        return DelayPacket{
            .data = data,
            .timestamp = ts,
            .allocator = allocator,
        };
    }

    fn deinit(self: *DelayPacket) void {
        self.allocator.free(self.data);
    }
};

// Network latency simulator with packet loss
const LatencySimulator = struct {
    const Self = @This();

    packets: std.ArrayList(DelayPacket),
    allocator: std.mem.Allocator,
    lostrate: u32, // packet loss rate (0-100)
    rttmin: i64, // minimum RTT in milliseconds
    rttmax: i64, // maximum RTT in milliseconds
    current: i64, // current timestamp in milliseconds
    prng: std.Random.DefaultPrng,

    fn init(allocator: std.mem.Allocator, lostrate: u32, rttmin: i64, rttmax: i64) LatencySimulator {
        return LatencySimulator{
            .packets = .empty,
            .allocator = allocator,
            .lostrate = lostrate,
            .rttmin = rttmin,
            .rttmax = rttmax,
            .current = 0,
            .prng = std.Random.DefaultPrng.init(@bitCast(std.time.milliTimestamp())),
        };
    }

    fn deinit(self: *Self) void {
        for (self.packets.items) |*pkt| {
            pkt.deinit();
        }
        self.packets.deinit(self.allocator);
    }

    // Send a packet through the simulated network
    fn send(self: *Self, buf: []const u8) !void {
        const random = self.prng.random();

        // Simulate packet loss
        if (random.intRangeAtMost(u32, 0, 99) < self.lostrate) {
            return; // Packet lost
        }

        // Calculate random delay
        const delay = if (self.rttmax > self.rttmin)
            random.intRangeAtMost(i64, self.rttmin, self.rttmax)
        else
            self.rttmin;

        const pkt = try DelayPacket.init(self.allocator, buf, self.current + delay);
        try self.packets.append(self.allocator, pkt);
    }

    // Receive packets that have arrived
    fn recv(self: *Self, buf: []u8) ?usize {
        var i: usize = 0;
        while (i < self.packets.items.len) {
            const pkt = &self.packets.items[i];
            if (self.current >= pkt.timestamp) {
                if (pkt.data.len > buf.len) {
                    i += 1;
                    continue;
                }

                const len = pkt.data.len;
                @memcpy(buf[0..len], pkt.data);

                // Remove this packet
                var removed = self.packets.orderedRemove(i);
                removed.deinit();

                return len;
            }
            i += 1;
        }
        return null;
    }

    fn update(self: *Self, current: i64) void {
        self.current = current;
    }
};

// Context for output callback
const TestContext = struct {
    peer_kcp: ?*kcp.Kcp,
    vnet: *LatencySimulator,

    fn output(buf: []const u8, _: *kcp.Kcp, user: ?*anyopaque) !i32 {
        const ctx = @as(*TestContext, @ptrCast(@alignCast(user.?)));
        try ctx.vnet.send(buf);
        return @intCast(buf.len);
    }
};

// Performance test function
fn test_performance(allocator: std.mem.Allocator, mode: u8) !void {
    // Print test mode
    const mode_name = switch (mode) {
        0 => "default",
        1 => "normal",
        else => "fast",
    };
    std.debug.print("\nTesting KCP in {s} mode:\n", .{mode_name});
    std.debug.print("----------------------------------------\n", .{});

    // Create two KCP endpoints
    const kcp1 = try kcp.create(allocator, 0x11223344, null);
    defer kcp.release(kcp1);

    const kcp2 = try kcp.create(allocator, 0x11223344, null);
    defer kcp.release(kcp2);

    // Create virtual network with 2% packet loss and 20-40ms RTT (reduced for faster testing)
    var vnet = LatencySimulator.init(allocator, 2, 20, 40);
    defer vnet.deinit();

    // Set up output callbacks
    var ctx1 = TestContext{ .peer_kcp = kcp2, .vnet = &vnet };
    var ctx2 = TestContext{ .peer_kcp = kcp1, .vnet = &vnet };

    kcp.setOutput(kcp1, &TestContext.output);
    kcp1.user = &ctx1;

    kcp.setOutput(kcp2, &TestContext.output);
    kcp2.user = &ctx2;

    // Configure KCP based on mode
    switch (mode) {
        0 => {
            // Default mode - TCP-like behavior
            kcp.setNodelay(kcp1, 0, 10, 0, 0);
            kcp.setNodelay(kcp2, 0, 10, 0, 0);
        },
        1 => {
            // Normal mode - no flow control
            kcp.setNodelay(kcp1, 0, 10, 0, 1);
            kcp.setNodelay(kcp2, 0, 10, 0, 1);
        },
        else => {
            // Fast mode - all optimizations enabled
            kcp.setNodelay(kcp1, 1, 10, 2, 1);
            kcp.setNodelay(kcp2, 1, 10, 2, 1);
            kcp1.rx_minrto = 10;
            kcp1.fastresend = 1;
        },
    }

    // Set window size
    kcp.wndsize(kcp1, 128, 128);
    kcp.wndsize(kcp2, 128, 128);

    // Test parameters
    const total_packets: u32 = 100; // Reduced for faster testing
    var current: u32 = 0;
    var slap: u32 = current + 20;
    var index: u32 = 0;
    var next: u32 = 0;
    var sumrtt: i64 = 0;
    var count: u32 = 0;
    var maxrtt: i32 = 0;

    var recv_buf: [2000]u8 = undefined;
    var send_buf: [8]u8 = undefined;

    const start_time = std.time.milliTimestamp();

    // Main test loop
    while (true) {
        // Use simulated time (cache the system call result)
        const elapsed = std.time.milliTimestamp() - start_time;
        current = @intCast(elapsed & 0xFFFFFFFF);
        vnet.update(@intCast(elapsed));

        // Update KCP
        try kcp.update(kcp1, current);
        try kcp.update(kcp2, current);

        // Send packets (limit to total_packets)
        while (current >= slap and index < total_packets) : (slap += 20) {
            // Encode packet: [index (4 bytes)][timestamp (4 bytes)]
            @memcpy(send_buf[0..4], std.mem.asBytes(&index));
            @memcpy(send_buf[4..8], std.mem.asBytes(&current));

            _ = kcp.send(kcp1, &send_buf) catch {
                break;
            };

            index += 1;
        }

        // Process network packets for kcp1
        while (vnet.recv(&recv_buf)) |len| {
            _ = try kcp.input(kcp1, recv_buf[0..len]);
        }

        // Process network packets for kcp2
        while (vnet.recv(&recv_buf)) |len| {
            _ = try kcp.input(kcp2, recv_buf[0..len]);
        }

        // Receive and process packets at kcp2
        while (true) {
            const len = kcp.recv(kcp2, &recv_buf) catch break;
            if (len == 8) {
                const recv_index = std.mem.bytesToValue(u32, recv_buf[0..4]);
                _ = std.mem.bytesToValue(u32, recv_buf[4..8]);

                // Echo back
                _ = try kcp.send(kcp2, recv_buf[0..len]);

                // Update statistics if in sequence
                if (recv_index == next) {
                    next += 1;
                }
            }
        }

        // Receive echoed packets at kcp1
        while (true) {
            const len = kcp.recv(kcp1, &recv_buf) catch break;
            if (len == 8) {
                const recv_index = std.mem.bytesToValue(u32, recv_buf[0..4]);
                const send_time = std.mem.bytesToValue(u32, recv_buf[4..8]);
                const rtt: i32 = @intCast(current -% send_time);

                if (rtt >= 0) {
                    sumrtt += rtt;
                    count += 1;
                    if (rtt > maxrtt) maxrtt = rtt;
                }

                // Print progress
                if (recv_index % 25 == 0) { // More frequent updates for smaller test
                    std.debug.print("recv #{d} rtt={d}ms\n", .{ recv_index, rtt });
                }
            }
        }

        // Check if done
        if (next >= total_packets) break;
    }

    // Print statistics
    std.debug.print("----------------------------------------\n", .{});
    std.debug.print("Mode: {s}\n", .{mode_name});
    std.debug.print("Packets sent: {d}\n", .{total_packets});
    std.debug.print("Packets received: {d}\n", .{next});

    if (count > 0) {
        const avgrtt = @divTrunc(sumrtt, @as(i64, @intCast(count)));
        std.debug.print("Average RTT: {d}ms\n", .{avgrtt});
        std.debug.print("Max RTT: {d}ms\n", .{maxrtt});
    }
    std.debug.print("========================================\n", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n", .{});
    std.debug.print("========================================\n", .{});
    std.debug.print("  KCP Performance Test\n", .{});
    std.debug.print("  Network: 2%% loss, 20-40ms RTT\n", .{});
    std.debug.print("  Packets: 100 per mode\n", .{});
    std.debug.print("========================================\n", .{});

    // Test three modes
    try test_performance(allocator, 0); // Default mode
    try test_performance(allocator, 1); // Normal mode
    try test_performance(allocator, 2); // Fast mode
}
