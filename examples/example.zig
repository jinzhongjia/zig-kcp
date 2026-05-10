const std = @import("std");
const kcp = @import("kcp");
const compat = kcp.compat;

// Example output callback function
fn outputCallback(buf: []const u8, k: *kcp.Kcp, user: ?*anyopaque) !i32 {
    _ = k;
    _ = user;

    // In real applications, this should send data through UDP socket
    std.debug.print("Output {} bytes\n", .{buf.len});

    return @as(i32, @intCast(buf.len));
}

pub fn main() !void {
    var gpa: compat.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create KCP instance
    const conv: u32 = 0x12345678; // Conversation ID, must be the same on both sides
    const kcp_inst = try kcp.create(allocator, conv, null);
    defer kcp.release(kcp_inst);

    // Set output callback
    kcp.setOutput(kcp_inst, &outputCallback);

    // Configure KCP parameters
    // Parameters: nodelay, interval, resend, nc
    // Fastest mode: setNodelay(1, 10, 2, 1)
    kcp.setNodelay(kcp_inst, 1, 10, 2, 1);

    // Set window size
    kcp.wndsize(kcp_inst, 128, 128);

    std.debug.print("KCP instance created successfully!\n", .{});
    std.debug.print("Conversation ID: 0x{X}\n", .{conv});
    std.debug.print("MTU: {}, MSS: {}\n", .{ kcp_inst.mtu, kcp_inst.mss });

    // Example of sending data
    const message = "Hello, KCP!";
    const sent = try kcp.send(kcp_inst, message);
    std.debug.print("Sent {} bytes\n", .{sent});

    // Update KCP state
    try kcp.update(kcp_inst, compat.currentMs());

    // Example of receiving data (assuming data has been received)
    // var recv_buffer: [1024]u8 = undefined;
    // const recv_len = try kcp_inst.recv(&recv_buffer);
    // if (recv_len > 0) {
    //     std.debug.print("Received: {s}\n", .{recv_buffer[0..@as(usize, @intCast(recv_len))]});
    // }

    std.debug.print("\nExample completed!\n", .{});
}
