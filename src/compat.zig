//=====================================================================
//
// compat.zig - Compatibility shims for Zig 0.15 and 0.16
//
// Centralises every API that differs between the two versions and exposes
// a small platform-neutral UDP layer (Linux + macOS + Windows) so the rest
// of the codebase can stay version- and OS-agnostic.
//
//=====================================================================

const std = @import("std");
const builtin = @import("builtin");

pub const is_016 = builtin.zig_version.major == 0 and builtin.zig_version.minor >= 16;

//---------------------------------------------------------------------
// Allocator: GeneralPurposeAllocator (0.15) vs DebugAllocator (0.16)
//---------------------------------------------------------------------
pub const DebugAllocator = if (@hasDecl(std.heap, "DebugAllocator"))
    std.heap.DebugAllocator
else
    std.heap.GeneralPurposeAllocator;

//---------------------------------------------------------------------
// Time helpers
//---------------------------------------------------------------------
fn nowNs() i128 {
    if (comptime is_016) {
        const io = std.Io.Threaded.global_single_threaded.io();
        const ts = std.Io.Clock.Timestamp.now(io, .awake);
        return @intCast(ts.raw.nanoseconds);
    } else {
        return std.time.nanoTimestamp();
    }
}

pub fn currentMs() u32 {
    const ms_i64: i64 = @intCast(@divTrunc(nowNs(), std.time.ns_per_ms));
    return @truncate(@as(u64, @bitCast(ms_i64)));
}

pub fn currentMsI64() i64 {
    return @intCast(@divTrunc(nowNs(), std.time.ns_per_ms));
}

pub fn sleepMs(ms: u64) void {
    if (comptime is_016) {
        const io = std.Io.Threaded.global_single_threaded.io();
        std.Io.sleep(io, .fromMilliseconds(@intCast(ms)), .awake) catch {};
    } else if (@hasDecl(std.Thread, "sleep")) {
        std.Thread.sleep(ms * std.time.ns_per_ms);
    } else {
        std.time.sleep(ms * std.time.ns_per_ms);
    }
}

pub fn sleepNs(ns: u64) void {
    if (comptime is_016) {
        const io = std.Io.Threaded.global_single_threaded.io();
        std.Io.sleep(io, .fromNanoseconds(@intCast(ns)), .awake) catch {};
    } else if (@hasDecl(std.Thread, "sleep")) {
        std.Thread.sleep(ns);
    } else {
        std.time.sleep(ns);
    }
}

pub const Timer = struct {
    start_ns: i128,

    pub fn start() Timer {
        return .{ .start_ns = nowNs() };
    }

    pub fn read(self: Timer) u64 {
        const elapsed = nowNs() - self.start_ns;
        return if (elapsed < 0) 0 else @intCast(elapsed);
    }
};

//---------------------------------------------------------------------
// Lazy single-threaded Io (0.16 only). Cheap: no syscall on 0.15.
//---------------------------------------------------------------------
fn ioInstance() if (is_016) std.Io else void {
    if (comptime !is_016) return {};
    return std.Io.Threaded.global_single_threaded.io();
}

//---------------------------------------------------------------------
// IPv4 address abstraction. Storage matches network order so hashing and
// equality are cheap, and conversion to/from version-specific types is a
// straight field copy.
//---------------------------------------------------------------------
pub const Address = struct {
    /// Octets in network order: octets[0..4] = a.b.c.d for "a.b.c.d".
    octets: [4]u8,
    /// Port in host byte order.
    port: u16,

    pub const ParseError = error{InvalidAddress};

    pub fn parseIp4(text: []const u8, port: u16) ParseError!Address {
        var octets: [4]u8 = undefined;
        var idx: usize = 0;
        var iter = std.mem.splitScalar(u8, text, '.');
        while (iter.next()) |part| {
            if (idx >= 4) return error.InvalidAddress;
            octets[idx] = std.fmt.parseInt(u8, part, 10) catch return error.InvalidAddress;
            idx += 1;
        }
        if (idx != 4) return error.InvalidAddress;
        return .{ .octets = octets, .port = port };
    }

    pub fn loopback(port: u16) Address {
        return .{ .octets = .{ 127, 0, 0, 1 }, .port = port };
    }

    pub fn unspecified(port: u16) Address {
        return .{ .octets = .{ 0, 0, 0, 0 }, .port = port };
    }

    pub fn eql(a: Address, b: Address) bool {
        return a.port == b.port and std.mem.eql(u8, &a.octets, &b.octets);
    }

    pub fn formatBuf(a: Address, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}:{d}", .{
            a.octets[0], a.octets[1], a.octets[2], a.octets[3], a.port,
        });
    }
};

//---------------------------------------------------------------------
// Cross-platform UDP socket
//
// 0.15 → std.posix (Linux/macOS/Windows via stdlib's POSIX shim).
// 0.16 → std.Io.net.Socket (Linux epoll, macOS kqueue, Windows IOCP).
//---------------------------------------------------------------------
pub const NetError = error{
    SocketFailed,
    BindFailed,
    SendFailed,
    RecvFailed,
    WouldBlock,
    Unexpected,
};

pub const Socket = struct {
    impl: Impl,

    const Impl = if (is_016) std.Io.net.Socket else std.posix.fd_t;

    pub fn close(self: *Socket) void {
        if (comptime is_016) {
            self.impl.close(ioInstance());
        } else {
            std.posix.close(self.impl);
        }
    }

    pub fn sendTo(self: *Socket, buf: []const u8, dest: Address) NetError!usize {
        if (comptime is_016) {
            const ip = std.Io.net.IpAddress{ .ip4 = .{ .bytes = dest.octets, .port = dest.port } };
            self.impl.send(ioInstance(), &ip, buf) catch return NetError.SendFailed;
            return buf.len;
        } else {
            const sa = sockaddrFromAddress(dest);
            return std.posix.sendto(
                self.impl,
                buf,
                0,
                @ptrCast(&sa),
                @sizeOf(std.posix.sockaddr.in),
            ) catch return NetError.SendFailed;
        }
    }

    pub fn recvFromNonblocking(
        self: *Socket,
        buf: []u8,
        from_out: ?*Address,
    ) NetError!usize {
        if (comptime is_016) {
            const io = ioInstance();
            const zero: std.Io.Clock.Duration = .{
                .raw = .fromNanoseconds(0),
                .clock = .awake,
            };
            const msg = self.impl.receiveTimeout(io, buf, .{ .duration = zero }) catch |err| switch (err) {
                error.Timeout => return NetError.WouldBlock,
                else => return NetError.RecvFailed,
            };
            if (from_out) |out| {
                out.* = switch (msg.from) {
                    .ip4 => |ip| .{ .octets = ip.bytes, .port = ip.port },
                    .ip6 => return NetError.RecvFailed,
                };
            }
            return msg.data.len;
        } else {
            var sa: std.posix.sockaddr.in = undefined;
            var sa_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.in);
            const n = std.posix.recvfrom(
                self.impl,
                buf,
                std.posix.MSG.DONTWAIT,
                @ptrCast(&sa),
                &sa_len,
            ) catch |err| {
                if (err == error.WouldBlock) return NetError.WouldBlock;
                return NetError.RecvFailed;
            };
            if (from_out) |out| out.* = addressFromSockaddr(sa);
            return n;
        }
    }
};

pub fn bindUdp(addr: Address) NetError!Socket {
    if (comptime is_016) {
        const ip = std.Io.net.IpAddress{ .ip4 = .{ .bytes = addr.octets, .port = addr.port } };
        const sock = ip.bind(ioInstance(), .{ .mode = .dgram }) catch return NetError.BindFailed;
        return .{ .impl = sock };
    } else {
        const fd = std.posix.socket(
            std.posix.AF.INET,
            std.posix.SOCK.DGRAM,
            std.posix.IPPROTO.UDP,
        ) catch return NetError.SocketFailed;
        errdefer std.posix.close(fd);

        const sa = sockaddrFromAddress(addr);
        std.posix.bind(fd, @ptrCast(&sa), @sizeOf(std.posix.sockaddr.in)) catch return NetError.BindFailed;
        return .{ .impl = fd };
    }
}

// 0.15-only conversions: kept private so the rest of the codebase never
// touches version-specific socket types directly.
fn sockaddrFromAddress(a: Address) std.posix.sockaddr.in {
    if (comptime is_016) @compileError("sockaddrFromAddress unused on 0.16");
    return .{
        .port = std.mem.nativeToBig(u16, a.port),
        .addr = @bitCast(a.octets),
    };
}

fn addressFromSockaddr(sa: std.posix.sockaddr.in) Address {
    if (comptime is_016) @compileError("addressFromSockaddr unused on 0.16");
    const octets: [4]u8 = @bitCast(sa.addr);
    return .{ .octets = octets, .port = std.mem.bigToNative(u16, sa.port) };
}

//---------------------------------------------------------------------
// Stdin: small blocking single-byte reader. Only used by the chat client.
//
// 0.15 → std.posix.read on STDIN_FILENO (cross-platform via stdlib's POSIX
//        shim, including the Windows HANDLE wrapper).
// 0.16 → std.Io.File.stdin().readStreaming (cross-platform, including
//        Windows IOCP). STDIN_FILENO is not exposed because its type
//        differs from fd_t on Windows under 0.16.
//---------------------------------------------------------------------
pub const ReadResult = enum { ok, eof, err };

pub fn readStdinByte(byte_out: *u8) ReadResult {
    if (comptime is_016) {
        const io = ioInstance();
        const stdin = std.Io.File.stdin();
        const buf: []u8 = @as(*[1]u8, @ptrCast(byte_out))[0..];
        const n = stdin.readStreaming(io, &.{buf}) catch return .err;
        return if (n == 0) .eof else .ok;
    } else {
        const n = std.posix.read(std.posix.STDIN_FILENO, @as(*[1]u8, @ptrCast(byte_out))[0..]) catch return .err;
        return if (n == 0) .eof else .ok;
    }
}

//---------------------------------------------------------------------
// Lock-free mutex for simple producer/consumer (works on both versions)
//---------------------------------------------------------------------
pub const SpinMutex = struct {
    state: std.atomic.Value(u8) = .init(0),

    pub fn lock(self: *SpinMutex) void {
        while (self.state.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlock(self: *SpinMutex) void {
        self.state.store(0, .release);
    }
};
