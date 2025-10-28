const std = @import("std");
const kcp = @import("kcp");
const posix = std.posix;
const net = std.net;

// UDP 上下文，用于在 KCP output 回调中发送数据
const UdpContext = struct {
    socket: posix.socket_t,
    server_addr: posix.sockaddr,
    server_len: posix.socklen_t,
};

// 消息队列，用于线程间传递用户输入
const MessageQueue = struct {
    const Self = @This();
    const Message = struct {
        data: [2048]u8,
        len: usize,
    };

    queue: std.ArrayList(Message),
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) Self {
        return .{
            .queue = std.ArrayList(Message){},
            .mutex = std.Thread.Mutex{},
            .allocator = allocator,
        };
    }

    fn deinit(self: *Self) void {
        self.queue.deinit(self.allocator);
    }

    fn push(self: *Self, msg: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var message = Message{
            .data = undefined,
            .len = msg.len,
        };
        @memcpy(message.data[0..msg.len], msg);
        try self.queue.append(self.allocator, message);
    }

    fn pop(self: *Self) ?Message {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.queue.items.len == 0) return null;
        return self.queue.orderedRemove(0);
    }
};

// 输入线程的上下文
const InputThreadContext = struct {
    msg_queue: *MessageQueue,
    running: *std.atomic.Value(bool),
};

// KCP output 回调函数：当 KCP 需要发送数据时调用
fn kcpOutput(buf: []const u8, k: *kcp.Kcp, user: ?*anyopaque) !i32 {
    _ = k;
    const ctx = @as(*UdpContext, @ptrCast(@alignCast(user.?)));

    const sent = try posix.sendto(
        ctx.socket,
        buf,
        0,
        &ctx.server_addr,
        ctx.server_len,
    );

    return @intCast(sent);
}

// 获取当前时间戳（毫秒）
fn getCurrentMs() u32 {
    const ns = std.time.nanoTimestamp();
    return @truncate(@as(u64, @intCast(@divTrunc(ns, 1_000_000))));
}

// 输入线程函数：阻塞读取 stdin
fn inputThread(ctx: *InputThreadContext) void {
    // 使用 File.read 直接读取 stdin
    const stdin_file = std.fs.File.stdin();

    var line_buffer: [2048]u8 = undefined;
    var line_pos: usize = 0;

    while (ctx.running.load(.seq_cst)) {
        // 读取一个字节
        var byte_buf: [1]u8 = undefined;
        const n = stdin_file.read(&byte_buf) catch |err| {
            // 只有 EOF 才退出
            if (err == error.EndOfStream) {
                std.debug.print("\n[Input thread] Stdin closed (EOF)\n", .{});
                ctx.running.store(false, .seq_cst);
                break;
            }
            // 其他错误继续尝试
            std.debug.print("[Input thread] Read error: {}, continuing...\n", .{err});
            std.Thread.sleep(100_000_000); // 休眠 100ms 再试
            continue;
        };

        if (n == 0) {
            // EOF
            std.debug.print("\n[Input thread] Stdin EOF (0 bytes)\n", .{});
            ctx.running.store(false, .seq_cst);
            break;
        }

        const byte = byte_buf[0];

        if (byte == '\n') {
            // 去除 Windows 下的 \r
            const line_end = if (line_pos > 0 and line_buffer[line_pos - 1] == '\r')
                line_pos - 1
            else
                line_pos;

            const line = line_buffer[0..line_end];

            if (line.len > 0) {
                ctx.msg_queue.push(line) catch |err| {
                    std.debug.print("[Input thread] Queue push error: {}\n", .{err});
                };
            }
            line_pos = 0;
        } else if (line_pos < line_buffer.len) {
            line_buffer[line_pos] = byte;
            line_pos += 1;
        }
    }

    std.debug.print("[Input thread] Exiting\n", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const host = if (args.len > 1) args[1] else "127.0.0.1";
    const port: u16 = if (args.len > 2)
        try std.fmt.parseInt(u16, args[2], 10)
    else
        9999;

    // 创建 UDP socket
    const socket = try posix.socket(
        posix.AF.INET,
        posix.SOCK.DGRAM,
        posix.IPPROTO.UDP,
    );
    defer posix.close(socket);

    // 解析服务器地址
    const addr_list = try net.getAddressList(allocator, host, port);
    defer addr_list.deinit();

    if (addr_list.addrs.len == 0) {
        std.debug.print("Failed to resolve host: {s}\n", .{host});
        return error.HostNotFound;
    }

    const server_addr = addr_list.addrs[0];

    // 初始化 UDP 上下文
    var udp_ctx = UdpContext{
        .socket = socket,
        .server_addr = server_addr.any,
        .server_len = server_addr.getOsSockLen(),
    };

    // 创建 KCP 实例（conv=1234，必须与服务器一致）
    const conv: u32 = 1234;
    const kcp_inst = try kcp.create(allocator, conv, &udp_ctx);
    defer kcp.release(kcp_inst);

    // 设置 KCP output 回调
    kcp.setOutput(kcp_inst, &kcpOutput);

    // 设置为快速模式：低延迟，适合实时应用
    // nodelay=1, interval=10ms, resend=2, nc=1
    kcp.setNodelay(kcp_inst, 1, 10, 2, 1);

    // 设置窗口大小
    kcp.wndsize(kcp_inst, 128, 128);

    std.debug.print("KCP initialized (conv={d}, fast mode)\n", .{conv});
    std.debug.print("\n=== KCP Chat Room Client ===\n", .{});
    std.debug.print("Commands:\n", .{});
    std.debug.print("  /list        - List all online users\n", .{});
    std.debug.print("  /rename NAME - Change your username\n", .{});
    std.debug.print("  /quit        - Disconnect from chat\n", .{});
    std.debug.print("\nConnecting to server...\n\n", .{});

    // 创建消息队列
    var msg_queue = MessageQueue.init(allocator);
    defer msg_queue.deinit();

    // 创建运行标志
    var running = std.atomic.Value(bool).init(true);

    // 创建输入线程上下文
    var input_ctx = InputThreadContext{
        .msg_queue = &msg_queue,
        .running = &running,
    };

    // 启动输入线程
    const thread = try std.Thread.spawn(.{}, inputThread, .{&input_ctx});
    thread.detach(); // 分离线程，主线程退出时不需要等待
    defer {
        running.store(false, .seq_cst);
    }

    var recv_buf: [2048]u8 = undefined;
    var kcp_recv_buf: [2048]u8 = undefined;
    var last_update = getCurrentMs();
    var last_heartbeat = getCurrentMs();

    // 立即发送初始化包，让服务器知道我们已连接
    _ = try kcp.send(kcp_inst, "__INIT__");
    try kcp.update(kcp_inst, getCurrentMs());

    // 等待输入线程启动
    std.Thread.sleep(10_000_000); // 10ms

    std.debug.print("> ", .{});

    // 主循环：处理网络 I/O 和发送用户消息
    while (running.load(.seq_cst)) {
        const current = getCurrentMs();

        // 定期更新 KCP 状态机
        if (current >= last_update) {
            try kcp.update(kcp_inst, current);
            last_update = kcp.check(kcp_inst, current);
        }

        // 心跳：每 200 毫秒发送一次
        if (current - last_heartbeat >= 200) {
            _ = try kcp.send(kcp_inst, "__HEARTBEAT__");
            last_heartbeat = current;
        }

        // 检查是否有用户输入的消息要发送
        if (msg_queue.pop()) |message| {
            const msg_data = message.data[0..message.len];

            // 检查是否是退出命令
            if (std.mem.eql(u8, msg_data, "/quit")) {
                std.debug.print("Goodbye!\n", .{});
                running.store(false, .seq_cst);
                break;
            }

            // 发送消息
            _ = try kcp.send(kcp_inst, msg_data);

            // 只有非命令消息才显示 "You:"
            if (!std.mem.startsWith(u8, msg_data, "/")) {
                std.debug.print("You: {s}\n", .{msg_data});
            }
            std.debug.print("> ", .{});

            // 立即更新 KCP 以发送消息
            try kcp.update(kcp_inst, current);
            last_update = kcp.check(kcp_inst, current);
        }

        // 尝试从 UDP socket 接收数据（非阻塞）
        const received = posix.recvfrom(
            socket,
            &recv_buf,
            posix.MSG.DONTWAIT,
            null,
            null,
        ) catch |err| blk: {
            if (err != error.WouldBlock) {
                return err;
            }
            break :blk 0;
        };

        if (received > 0) {
            // 将 UDP 数据输入到 KCP
            _ = try kcp.input(kcp_inst, recv_buf[0..received]);

            // 尝试从 KCP 接收应用层数据
            while (true) {
                const kcp_len = kcp.recv(kcp_inst, &kcp_recv_buf) catch |err| {
                    if (err == error.NoData) break;
                    return err;
                };

                const msg = kcp_recv_buf[0..@intCast(kcp_len)];
                // 清除当前行的提示符，显示消息，然后重新显示提示符
                std.debug.print("\r{s}\n> ", .{msg});
            }
        }

        // 短暂休眠，避免 CPU 空转（1ms）
        std.Thread.sleep(1_000_000);
    }

    std.debug.print("\nClient closed.\n", .{});
}
