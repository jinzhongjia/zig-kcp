const std = @import("std");
const kcp = @import("kcp");
const compat = kcp.compat;

const Address = compat.Address;
const Socket = compat.Socket;

// Default server target. Edit these if your server isn't on localhost:9999.
const default_host = "127.0.0.1";
const default_port: u16 = 9999;

// UDP context, used for sending data in KCP output callback
const UdpContext = struct {
    socket: *Socket,
    server_addr: Address,
};

// Message queue for passing user input between threads
const MessageQueue = struct {
    const Self = @This();
    const Message = struct {
        data: [2048]u8,
        len: usize,
    };

    queue: std.ArrayList(Message),
    mutex: compat.SpinMutex,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) Self {
        return .{
            .queue = .empty,
            .mutex = .{},
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

// Input thread context
const InputThreadContext = struct {
    msg_queue: *MessageQueue,
    running: *std.atomic.Value(bool),
};

// KCP output callback function: called when KCP needs to send data
fn kcpOutput(buf: []const u8, k: *kcp.Kcp, user: ?*anyopaque) !i32 {
    _ = k;
    const ctx = @as(*UdpContext, @ptrCast(@alignCast(user.?)));
    const sent = try ctx.socket.sendTo(buf, ctx.server_addr);
    return @intCast(sent);
}

// Input thread function: blocking read from stdin
fn inputThread(ctx: *InputThreadContext) void {
    var line_buffer: [2048]u8 = undefined;
    var line_pos: usize = 0;

    while (ctx.running.load(.seq_cst)) {
        var byte: u8 = 0;
        switch (compat.readStdinByte(&byte)) {
            .ok => {},
            .eof => {
                std.debug.print("\n[Input thread] Stdin EOF\n", .{});
                ctx.running.store(false, .seq_cst);
                break;
            },
            .err => {
                std.debug.print("[Input thread] Read error, continuing...\n", .{});
                compat.sleepMs(100);
                continue;
            },
        }

        if (byte == '\n') {
            // Remove \r on Windows
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
    var gpa: compat.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const host = default_host;
    const port: u16 = default_port;

    // Resolve server address (IPv4 literal only)
    const server_addr = Address.parseIp4(host, port) catch {
        std.debug.print("Failed to parse host: {s}\n", .{host});
        return error.HostNotFound;
    };

    // Bind ephemeral local UDP socket
    var socket = try compat.bindUdp(Address.unspecified(0));
    defer socket.close();

    // Initialize UDP context
    var udp_ctx = UdpContext{
        .socket = &socket,
        .server_addr = server_addr,
    };

    // Create KCP instance (conv=1234, must match server)
    const conv: u32 = 1234;
    const kcp_inst = try kcp.create(allocator, conv, &udp_ctx);
    defer kcp.release(kcp_inst);

    // Set KCP output callback
    kcp.setOutput(kcp_inst, &kcpOutput);

    // Set to fast mode: low latency, suitable for real-time applications
    // nodelay=1, interval=10ms, resend=2, nc=1
    kcp.setNodelay(kcp_inst, 1, 10, 2, 1);

    // Set window size
    kcp.wndsize(kcp_inst, 128, 128);

    std.debug.print("KCP initialized (conv={d}, fast mode)\n", .{conv});
    std.debug.print("\n=== KCP Chat Room Client ===\n", .{});
    std.debug.print("Commands:\n", .{});
    std.debug.print("  /list        - List all online users\n", .{});
    std.debug.print("  /rename NAME - Change your username\n", .{});
    std.debug.print("  /quit        - Disconnect from chat\n", .{});
    std.debug.print("\nConnecting to server {s}:{d}...\n\n", .{ host, port });

    // Create message queue
    var msg_queue = MessageQueue.init(allocator);
    defer msg_queue.deinit();

    // Create running flag
    var running = std.atomic.Value(bool).init(true);

    // Create input thread context
    var input_ctx = InputThreadContext{
        .msg_queue = &msg_queue,
        .running = &running,
    };

    // Start input thread
    const thread = try std.Thread.spawn(.{}, inputThread, .{&input_ctx});
    thread.detach(); // Detach thread, no need to wait when main thread exits
    defer {
        running.store(false, .seq_cst);
    }

    var recv_buf: [2048]u8 = undefined;
    var kcp_recv_buf: [2048]u8 = undefined;
    var last_update = compat.currentMs();
    var last_heartbeat = compat.currentMs();

    // Immediately send initialization packet to let server know we're connected
    _ = try kcp.send(kcp_inst, "__INIT__");
    try kcp.update(kcp_inst, compat.currentMs());

    // Wait for input thread to start
    compat.sleepMs(10);

    std.debug.print("> ", .{});

    // Main loop: handle network I/O and send user messages
    while (running.load(.seq_cst)) {
        const current = compat.currentMs();

        // Periodically update KCP state machine
        if (current >= last_update) {
            try kcp.update(kcp_inst, current);
            last_update = kcp.check(kcp_inst, current);
        }

        // Heartbeat: send every 200 milliseconds
        if (current - last_heartbeat >= 200) {
            _ = try kcp.send(kcp_inst, "__HEARTBEAT__");
            last_heartbeat = current;
        }

        // Check if there are user input messages to send
        if (msg_queue.pop()) |message| {
            const msg_data = message.data[0..message.len];

            // Check if it's a quit command
            if (std.mem.eql(u8, msg_data, "/quit")) {
                std.debug.print("Goodbye!\n", .{});
                running.store(false, .seq_cst);
                break;
            }

            // Send message
            _ = try kcp.send(kcp_inst, msg_data);

            // Only display "You:" for non-command messages
            if (!std.mem.startsWith(u8, msg_data, "/")) {
                std.debug.print("You: {s}\n", .{msg_data});
            }
            std.debug.print("> ", .{});

            // Immediately update KCP to send message
            try kcp.update(kcp_inst, current);
            last_update = kcp.check(kcp_inst, current);
        }

        // Try to receive data from UDP socket (non-blocking)
        const received = socket.recvFromNonblocking(&recv_buf, null) catch |err| blk: {
            if (err != compat.NetError.WouldBlock) {
                return err;
            }
            break :blk 0;
        };

        if (received > 0) {
            // Feed UDP data into KCP
            _ = try kcp.input(kcp_inst, recv_buf[0..received]);

            // Try to receive application-layer data from KCP
            while (true) {
                const kcp_len = kcp.recv(kcp_inst, &kcp_recv_buf) catch |err| {
                    if (err == error.NoData) break;
                    return err;
                };

                const msg = kcp_recv_buf[0..@intCast(kcp_len)];
                // Clear current line prompt, display message, then redisplay prompt
                std.debug.print("\r{s}\n> ", .{msg});
            }
        }

        // Brief sleep to avoid CPU spinning (1ms)
        compat.sleepMs(1);
    }

    std.debug.print("\nClient closed.\n", .{});
}
