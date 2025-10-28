const std = @import("std");
const kcp = @import("kcp");
const posix = std.posix;
const net = std.net;

// Client information
const Client = struct {
    kcp_inst: *kcp.Kcp,
    username: []u8,
    addr: posix.sockaddr,
    addr_len: posix.socklen_t,
    last_seen: u32, // Last activity timestamp
    allocator: std.mem.Allocator,

    fn deinit(self: *Client) void {
        self.allocator.free(self.username);
        kcp.release(self.kcp_inst);
    }
};

// Client output context
const ClientOutputContext = struct {
    socket: posix.socket_t,
    client: *Client,
};

// KCP output callback function: send to specific client
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

// Address comparison function
fn addrEqual(a: *const posix.sockaddr, b: *const posix.sockaddr) bool {
    const a_in = @as(*const posix.sockaddr.in, @ptrCast(a));
    const b_in = @as(*const posix.sockaddr.in, @ptrCast(b));
    return a_in.port == b_in.port and a_in.addr == b_in.addr;
}

// Address hash function
fn addrHash(addr: *const posix.sockaddr) u64 {
    const in = @as(*const posix.sockaddr.in, @ptrCast(@alignCast(addr)));
    return @as(u64, in.addr) << 32 | @as(u64, in.port);
}

// Get current timestamp in milliseconds
fn getCurrentMs() u32 {
    const ns = std.time.nanoTimestamp();
    return @truncate(@as(u64, @intCast(@divTrunc(ns, 1_000_000))));
}

// Format address as readable string
fn formatAddress(addr: *const posix.sockaddr, buf: []u8) ![]const u8 {
    const in = @as(*const posix.sockaddr.in, @ptrCast(@alignCast(addr)));
    const ip_addr = in.addr;
    const port = @byteSwap(in.port);

    // Convert IP address to dotted decimal notation
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

    // Create UDP socket
    const socket = try posix.socket(
        posix.AF.INET,
        posix.SOCK.DGRAM,
        posix.IPPROTO.UDP,
    );
    defer posix.close(socket);

    // Bind address
    const addr = net.Address.initIp4([_]u8{ 0, 0, 0, 0 }, port);
    try posix.bind(socket, &addr.any, addr.getOsSockLen());

    std.debug.print("Listening on 0.0.0.0:{d}\n", .{port});
    std.debug.print("Waiting for clients to connect...\n\n", .{});

    // Client management
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

    const conv: u32 = 1234; // All clients use the same conv
    const client_timeout_ms: u32 = 600; // 600ms timeout (3 heartbeats)
    var last_timeout_check = getCurrentMs();

    // Main loop
    while (true) {
        const current = getCurrentMs();

        // Update KCP state machine for all clients
        var it = clients.valueIterator();
        while (it.next()) |client| {
            if (current >= last_update) {
                try kcp.update(client.*.kcp_inst, current);
            }
        }
        if (current >= last_update) {
            last_update = current + 10; // 10ms update interval
        }

        // Check for timeout clients every 100ms
        if (current - last_timeout_check >= 100) {
            last_timeout_check = current;

            // Collect timeout clients
            var timeout_keys = std.ArrayList(u64){};
            defer timeout_keys.deinit(allocator);

            var timeout_it = clients.iterator();
            while (timeout_it.next()) |entry| {
                if (current - entry.value_ptr.*.last_seen > client_timeout_ms) {
                    try timeout_keys.append(allocator, entry.key_ptr.*);
                }
            }

            // Remove timeout clients and notify
            for (timeout_keys.items) |key| {
                if (clients.get(key)) |client| {
                    const disconnect_msg = try std.fmt.allocPrint(
                        allocator,
                        "── {s} disconnected (timeout) ──",
                        .{client.username},
                    );
                    defer allocator.free(disconnect_msg);

                    std.debug.print("{s}\n", .{disconnect_msg});

                    // Notify others first, then delete
                    try broadcastMessage(&clients, allocator, client, disconnect_msg);

                    // Delete client
                    _ = clients.remove(key);
                    client.deinit();
                    allocator.destroy(client);
                }
            }
        }

        // Non-blocking receive UDP data
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

        // Check if this is a new client
        const client = clients.get(from_hash) orelse blk: {
            // New client, create and initialize
            const new_client = try allocator.create(Client);
            errdefer allocator.destroy(new_client);

            // Generate username
            const username = try std.fmt.allocPrint(allocator, "User{d}", .{next_user_id});
            next_user_id += 1;

            // Create output context
            const output_ctx = try allocator.create(ClientOutputContext);
            errdefer allocator.destroy(output_ctx);

            // Create KCP instance
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

            // Setup KCP
            kcp.setOutput(kcp_inst, &kcpOutput);
            kcp.setNodelay(kcp_inst, 1, 10, 2, 1);
            kcp.wndsize(kcp_inst, 128, 128);

            try clients.put(from_hash, new_client);

            var addr_buf: [64]u8 = undefined;
            const addr_str = try formatAddress(&from, &addr_buf);
            std.debug.print("✓ {s} connected from {s}\n", .{ username, addr_str });

            // Notify other clients
            const join_msg = try std.fmt.allocPrint(allocator, "── {s} joined the chat ──", .{username});
            defer allocator.free(join_msg);
            try broadcastMessage(&clients, allocator, null, join_msg);

            // Send welcome message to new client
            const welcome = try std.fmt.allocPrint(allocator, "── Welcome to the chat room! You are {s} ──", .{username});
            defer allocator.free(welcome);
            _ = try kcp.send(kcp_inst, welcome);

            break :blk new_client;
        };

        // Update client's last activity time
        client.last_seen = current;

        // Feed UDP data into corresponding client's KCP
        _ = try kcp.input(client.kcp_inst, recv_buf[0..received]);

        // Try to receive application-layer data from KCP
        while (true) {
            const kcp_len = kcp.recv(client.kcp_inst, &kcp_recv_buf) catch |err| {
                if (err == error.NoData) break;
                return err;
            };

            const msg = kcp_recv_buf[0..@intCast(kcp_len)];

            // Handle message
            try handleClientMessage(&clients, allocator, client, msg);
        }
    }
}

// Broadcast message to all clients (except exclude)
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

// Handle client message
fn handleClientMessage(
    clients: *std.AutoHashMap(u64, *Client),
    allocator: std.mem.Allocator,
    client: *Client,
    message: []const u8,
) !void {
    // Check if this is a system message (heartbeat or initialization)
    if (std.mem.eql(u8, message, "__HEARTBEAT__")) {
        // Heartbeat message, only update last_seen, no processing needed
        return;
    }

    if (std.mem.eql(u8, message, "__INIT__")) {
        // Initialization message, client just connected, no special handling needed
        // last_seen is already updated in main loop
        return;
    }

    // Check if this is a command
    if (std.mem.startsWith(u8, message, "/")) {
        try handleCommand(clients, allocator, client, message);
    } else {
        // Normal message, broadcast to all other clients
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

// Handle command
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

        // Check if username is already taken
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

        // Update username
        allocator.free(client.username);
        client.username = try allocator.dupe(u8, new_name);

        std.debug.print("{s}\n", .{notification});
        try broadcastMessage(clients, allocator, null, notification);
        return;
    }

    // /quit - Client disconnects (client will close itself, just don't throw error)
    if (std.mem.eql(u8, std.mem.trim(u8, cmd, " \t\r\n"), "/quit")) {
        // Client is about to disconnect, no response needed
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

    // Unknown command
    const err_msg = "── Unknown command. Available: /rename <name>, /list, /quit ──";
    _ = try kcp.send(client.kcp_inst, err_msg);
}
