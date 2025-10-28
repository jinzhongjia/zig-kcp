const std = @import("std");
const kcp = @import("kcp");
const posix = std.posix;
const net = std.net;

// 客户端信息
const Client = struct {
    kcp_inst: *kcp.Kcp,
    username: []u8,
    addr: posix.sockaddr,
    addr_len: posix.socklen_t,
    last_seen: u32, // 最后活跃时间
    allocator: std.mem.Allocator,

    fn deinit(self: *Client) void {
        self.allocator.free(self.username);
        kcp.release(self.kcp_inst);
    }
};

// 客户端输出上下文
const ClientOutputContext = struct {
    socket: posix.socket_t,
    client: *Client,
};

// KCP output 回调函数：发送给特定客户端
fn kcpOutput(buf: []const u8, k: *kcp.Kcp, user: ?*anyopaque) !i32 {
    _ = k;
    const ctx = @as(*ClientOutputContext, @ptrCast(@alignCast(user.?)));

    const sent = try posix.sendto(
        ctx.socket,
        buf,
        0,
        &ctx.client.addr,
        ctx.client.addr_len,
    );

    return @intCast(sent);
}

// 地址比较函数
fn addrEqual(a: *const posix.sockaddr, b: *const posix.sockaddr) bool {
    const a_in = @as(*const posix.sockaddr.in, @ptrCast(a));
    const b_in = @as(*const posix.sockaddr.in, @ptrCast(b));
    return a_in.port == b_in.port and a_in.addr == b_in.addr;
}

// 地址哈希函数
fn addrHash(addr: *const posix.sockaddr) u64 {
    const in = @as(*const posix.sockaddr.in, @ptrCast(@alignCast(addr)));
    return @as(u64, in.addr) << 32 | @as(u64, in.port);
}

// 获取当前时间戳（毫秒）
fn getCurrentMs() u32 {
    const ns = std.time.nanoTimestamp();
    return @truncate(@as(u64, @intCast(@divTrunc(ns, 1_000_000))));
}

// 格式化地址为可读字符串
fn formatAddress(addr: *const posix.sockaddr, buf: []u8) ![]const u8 {
    const in = @as(*const posix.sockaddr.in, @ptrCast(@alignCast(addr)));
    const ip_addr = in.addr;
    const port = @byteSwap(in.port);

    // 将 IP 地址转换为点分十进制
    const a = @as(u8, @truncate(ip_addr & 0xFF));
    const b = @as(u8, @truncate((ip_addr >> 8) & 0xFF));
    const c = @as(u8, @truncate((ip_addr >> 16) & 0xFF));
    const d = @as(u8, @truncate((ip_addr >> 24) & 0xFF));

    return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}:{d}", .{ a, b, c, d, port });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const port: u16 = if (args.len > 1)
        try std.fmt.parseInt(u16, args[1], 10)
    else
        9999;

    std.debug.print("\n=== KCP Chat Room Server ===\n", .{});
    std.debug.print("Starting on port {d}...\n", .{port});

    // 创建 UDP socket
    const socket = try posix.socket(
        posix.AF.INET,
        posix.SOCK.DGRAM,
        posix.IPPROTO.UDP,
    );
    defer posix.close(socket);

    // 绑定地址
    const addr = net.Address.initIp4([_]u8{ 0, 0, 0, 0 }, port);
    try posix.bind(socket, &addr.any, addr.getOsSockLen());

    std.debug.print("Listening on 0.0.0.0:{d}\n", .{port});
    std.debug.print("Waiting for clients to connect...\n\n", .{});

    // 客户端管理
    var clients = std.AutoHashMap(u64, *Client).init(allocator);
    defer {
        var it = clients.valueIterator();
        while (it.next()) |client| {
            client.*.deinit();
            allocator.destroy(client.*);
        }
        clients.deinit();
    }

    var next_user_id: u32 = 1;
    var recv_buf: [2048]u8 = undefined;
    var kcp_recv_buf: [2048]u8 = undefined;
    var last_update = getCurrentMs();

    const conv: u32 = 1234; // 所有客户端使用相同的 conv
    const client_timeout_ms: u32 = 600; // 600ms 超时（3 次心跳）
    var last_timeout_check = getCurrentMs();

    // 主循环
    while (true) {
        const current = getCurrentMs();

        // 更新所有客户端的 KCP 状态机
        var it = clients.valueIterator();
        while (it.next()) |client| {
            if (current >= last_update) {
                try kcp.update(client.*.kcp_inst, current);
            }
        }
        if (current >= last_update) {
            last_update = current + 10; // 10ms 更新间隔
        }

        // 每 100ms 检查一次超时客户端
        if (current - last_timeout_check >= 100) {
            last_timeout_check = current;

            // 收集超时的客户端
            var timeout_keys = std.ArrayList(u64){};
            defer timeout_keys.deinit(allocator);

            var timeout_it = clients.iterator();
            while (timeout_it.next()) |entry| {
                if (current - entry.value_ptr.*.last_seen > client_timeout_ms) {
                    try timeout_keys.append(allocator, entry.key_ptr.*);
                }
            }

            // 移除超时客户端并通知
            for (timeout_keys.items) |key| {
                if (clients.get(key)) |client| {
                    const disconnect_msg = try std.fmt.allocPrint(
                        allocator,
                        "── {s} disconnected (timeout) ──",
                        .{client.username},
                    );
                    defer allocator.free(disconnect_msg);

                    std.debug.print("{s}\n", .{disconnect_msg});

                    // 先通知其他人，再删除
                    try broadcastMessage(&clients, allocator, client, disconnect_msg);

                    // 删除客户端
                    _ = clients.remove(key);
                    client.deinit();
                    allocator.destroy(client);
                }
            }
        }

        // 非阻塞接收 UDP 数据
        var from: posix.sockaddr = undefined;
        var from_len: posix.socklen_t = @sizeOf(posix.sockaddr);

        const received = posix.recvfrom(
            socket,
            &recv_buf,
            posix.MSG.DONTWAIT,
            &from,
            &from_len,
        ) catch |err| {
            if (err == error.WouldBlock) {
                std.Thread.sleep(1_000_000); // 1ms
                continue;
            }
            return err;
        };

        const from_hash = addrHash(&from);

        // 检查是否是新客户端
        const client = clients.get(from_hash) orelse blk: {
            // 新客户端，创建并初始化
            const new_client = try allocator.create(Client);
            errdefer allocator.destroy(new_client);

            // 生成用户名
            const username = try std.fmt.allocPrint(allocator, "User{d}", .{next_user_id});
            next_user_id += 1;

            // 创建输出上下文
            const output_ctx = try allocator.create(ClientOutputContext);
            errdefer allocator.destroy(output_ctx);

            // 创建 KCP 实例
            const kcp_inst = try kcp.create(allocator, conv, output_ctx);
            errdefer kcp.release(kcp_inst);

            new_client.* = Client{
                .kcp_inst = kcp_inst,
                .username = username,
                .addr = from,
                .addr_len = from_len,
                .last_seen = current,
                .allocator = allocator,
            };

            output_ctx.* = ClientOutputContext{
                .socket = socket,
                .client = new_client,
            };

            // 设置 KCP
            kcp.setOutput(kcp_inst, &kcpOutput);
            kcp.setNodelay(kcp_inst, 1, 10, 2, 1);
            kcp.wndsize(kcp_inst, 128, 128);

            try clients.put(from_hash, new_client);

            var addr_buf: [64]u8 = undefined;
            const addr_str = try formatAddress(&from, &addr_buf);
            std.debug.print("✓ {s} connected from {s}\n", .{ username, addr_str });

            // 通知其他客户端
            const join_msg = try std.fmt.allocPrint(allocator, "── {s} joined the chat ──", .{username});
            defer allocator.free(join_msg);
            try broadcastMessage(&clients, allocator, null, join_msg);

            // 发送欢迎消息给新客户端
            const welcome = try std.fmt.allocPrint(allocator, "── Welcome to the chat room! You are {s} ──", .{username});
            defer allocator.free(welcome);
            _ = try kcp.send(kcp_inst, welcome);

            break :blk new_client;
        };

        // 更新客户端最后活跃时间
        client.last_seen = current;

        // 将 UDP 数据输入到对应客户端的 KCP
        _ = try kcp.input(client.kcp_inst, recv_buf[0..received]);

        // 尝试从 KCP 接收应用层数据
        while (true) {
            const kcp_len = kcp.recv(client.kcp_inst, &kcp_recv_buf) catch |err| {
                if (err == error.NoData) break;
                return err;
            };

            const msg = kcp_recv_buf[0..@intCast(kcp_len)];

            // 处理消息
            try handleClientMessage(&clients, allocator, client, msg);
        }
    }
}

// 广播消息给所有客户端（除了 exclude）
fn broadcastMessage(
    clients: *std.AutoHashMap(u64, *Client),
    allocator: std.mem.Allocator,
    exclude: ?*Client,
    message: []const u8,
) !void {
    _ = allocator;
    var it = clients.valueIterator();
    while (it.next()) |client| {
        if (exclude != null and client.* == exclude.?) continue;
        _ = try kcp.send(client.*.kcp_inst, message);
    }
}

// 处理客户端消息
fn handleClientMessage(
    clients: *std.AutoHashMap(u64, *Client),
    allocator: std.mem.Allocator,
    client: *Client,
    message: []const u8,
) !void {
    // 检查是否是系统消息（心跳或初始化）
    if (std.mem.eql(u8, message, "__HEARTBEAT__")) {
        // 心跳消息，只更新 last_seen，不处理
        return;
    }

    if (std.mem.eql(u8, message, "__INIT__")) {
        // 初始化消息，客户端刚连接，不需要特殊处理
        // last_seen 已经在主循环中更新
        return;
    }

    // 检查是否是命令
    if (std.mem.startsWith(u8, message, "/")) {
        try handleCommand(clients, allocator, client, message);
    } else {
        // 普通消息，广播给所有其他客户端
        const formatted = try std.fmt.allocPrint(
            allocator,
            "[{s}] {s}",
            .{ client.username, message },
        );
        defer allocator.free(formatted);

        std.debug.print("{s}\n", .{formatted});
        try broadcastMessage(clients, allocator, client, formatted);
    }
}

// 处理命令
fn handleCommand(
    clients: *std.AutoHashMap(u64, *Client),
    allocator: std.mem.Allocator,
    client: *Client,
    cmd: []const u8,
) !void {
    // /rename newname
    if (std.mem.startsWith(u8, cmd, "/rename ")) {
        const new_name = std.mem.trim(u8, cmd[8..], " \t\r\n");
        if (new_name.len == 0 or new_name.len > 20) {
            const err_msg = "── Error: Username must be 1-20 characters ──";
            _ = try kcp.send(client.kcp_inst, err_msg);
            return;
        }

        // 检查用户名是否已被使用
        var it = clients.valueIterator();
        while (it.next()) |c| {
            if (c.* != client and std.mem.eql(u8, c.*.username, new_name)) {
                const err_msg = "── Error: Username already taken ──";
                _ = try kcp.send(client.kcp_inst, err_msg);
                return;
            }
        }

        const old_name = client.username;
        const notification = try std.fmt.allocPrint(
            allocator,
            "── {s} is now known as {s} ──",
            .{ old_name, new_name },
        );
        defer allocator.free(notification);

        // 更新用户名
        allocator.free(client.username);
        client.username = try allocator.dupe(u8, new_name);

        std.debug.print("{s}\n", .{notification});
        try broadcastMessage(clients, allocator, null, notification);
        return;
    }

    // /quit - 客户端断开连接（客户端会自己关闭，这里只是不报错）
    if (std.mem.eql(u8, std.mem.trim(u8, cmd, " \t\r\n"), "/quit")) {
        // 客户端即将断开，不需要发送响应
        return;
    }

    // /list
    if (std.mem.eql(u8, std.mem.trim(u8, cmd, " \t\r\n"), "/list")) {
        var list_buf = std.ArrayList(u8){};
        defer list_buf.deinit(allocator);

        try list_buf.appendSlice(allocator, "── Online users ──\n");
        var it = clients.valueIterator();
        while (it.next()) |c| {
            try list_buf.appendSlice(allocator, "  ");
            try list_buf.appendSlice(allocator, c.*.username);
            if (c.* == client) {
                try list_buf.appendSlice(allocator, " (you)");
            }
            try list_buf.appendSlice(allocator, "\n");
        }

        _ = try kcp.send(client.kcp_inst, list_buf.items);
        return;
    }

    // 未知命令
    const err_msg = "── Unknown command. Available: /rename <name>, /list, /quit ──";
    _ = try kcp.send(client.kcp_inst, err_msg);
}
