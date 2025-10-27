const std = @import("std");
const kcp = @import("kcp");

// 输出回调函数示例
fn outputCallback(buf: []const u8, k: *kcp.Kcp, user: ?*anyopaque) !i32 {
    _ = k;
    _ = user;

    // 在实际应用中，这里应该通过 UDP socket 发送数据
    std.debug.print("Output {} bytes\n", .{buf.len});

    return @as(i32, @intCast(buf.len));
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 创建 KCP 实例
    const conv: u32 = 0x12345678; // 会话 ID，两端必须相同
    const kcp_inst = try kcp.Kcp.create(allocator, conv, null);
    defer kcp_inst.release();

    // 设置输出回调
    kcp_inst.setOutput(&outputCallback);

    // 配置 KCP 参数
    // 参数: nodelay, interval, resend, nc
    // 最快模式: setNodelay(1, 10, 2, 1)
    kcp_inst.setNodelay(1, 10, 2, 1);

    // 设置窗口大小
    kcp_inst.wndsize(128, 128);

    std.debug.print("KCP instance created successfully!\n", .{});
    std.debug.print("Conversation ID: 0x{X}\n", .{conv});
    std.debug.print("MTU: {}, MSS: {}\n", .{ kcp_inst.mtu, kcp_inst.mss });

    // 发送数据示例
    const message = "Hello, KCP!";
    const sent = try kcp_inst.send(message);
    std.debug.print("Sent {} bytes\n", .{sent});

    // 更新 KCP 状态
    const current_time = @as(u32, @intCast(std.time.milliTimestamp()));
    try kcp_inst.update(current_time);

    // 接收数据示例（假设已经收到数据）
    // var recv_buffer: [1024]u8 = undefined;
    // const recv_len = try kcp_inst.recv(&recv_buffer);
    // if (recv_len > 0) {
    //     std.debug.print("Received: {s}\n", .{recv_buffer[0..@as(usize, @intCast(recv_len))]});
    // }

    std.debug.print("\nExample completed!\n", .{});
}
