//=====================================================================
//
// compat.zig - Compatibility shims for Zig 0.15 and 0.16
//
// Centralises every API that differs between the two versions so the
// rest of the codebase can stay version-agnostic.
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
// UDP socket helpers (raw syscalls on 0.16, std.posix on 0.15)
//---------------------------------------------------------------------
pub const Fd = std.posix.fd_t;
pub const sockaddr = std.posix.sockaddr;
pub const socklen_t = std.posix.socklen_t;
pub const AF = std.posix.AF;
pub const SOCK = std.posix.SOCK;
pub const IPPROTO = std.posix.IPPROTO;
pub const MSG = std.posix.MSG;

pub const NetError = error{
    SocketFailed,
    BindFailed,
    SendFailed,
    RecvFailed,
    WouldBlock,
    Unexpected,
};

pub fn udpSocket() !Fd {
    if (comptime is_016) {
        const linux = std.os.linux;
        const rc = linux.socket(linux.AF.INET, linux.SOCK.DGRAM, linux.IPPROTO.UDP);
        return switch (linux.errno(rc)) {
            .SUCCESS => @intCast(rc),
            else => NetError.SocketFailed,
        };
    } else {
        return std.posix.socket(AF.INET, SOCK.DGRAM, IPPROTO.UDP) catch return NetError.SocketFailed;
    }
}

pub fn closeFd(fd: Fd) void {
    if (comptime is_016) {
        _ = std.os.linux.close(fd);
    } else {
        std.posix.close(fd);
    }
}

pub fn bindIp4(fd: Fd, addr_in: *const sockaddr.in) !void {
    if (comptime is_016) {
        const rc = std.os.linux.bind(fd, @ptrCast(addr_in), @sizeOf(sockaddr.in));
        if (std.os.linux.errno(rc) != .SUCCESS) return NetError.BindFailed;
    } else {
        std.posix.bind(fd, @ptrCast(addr_in), @sizeOf(sockaddr.in)) catch return NetError.BindFailed;
    }
}

pub fn sendTo(fd: Fd, buf: []const u8, addr: *const sockaddr, addr_len: socklen_t) !usize {
    if (comptime is_016) {
        const linux = std.os.linux;
        const rc = linux.sendto(fd, buf.ptr, buf.len, 0, addr, addr_len);
        return switch (linux.errno(rc)) {
            .SUCCESS => rc,
            else => NetError.SendFailed,
        };
    } else {
        return std.posix.sendto(fd, buf, 0, addr, addr_len) catch return NetError.SendFailed;
    }
}

pub fn recvFromNonblocking(
    fd: Fd,
    buf: []u8,
    addr: ?*sockaddr,
    addr_len: ?*socklen_t,
) !usize {
    if (comptime is_016) {
        const linux = std.os.linux;
        const rc = linux.recvfrom(fd, buf.ptr, buf.len, linux.MSG.DONTWAIT, addr, addr_len);
        return switch (linux.errno(rc)) {
            .SUCCESS => rc,
            .AGAIN => NetError.WouldBlock,
            else => NetError.RecvFailed,
        };
    } else {
        return std.posix.recvfrom(fd, buf, MSG.DONTWAIT, addr, addr_len) catch |err| {
            if (err == error.WouldBlock) return NetError.WouldBlock;
            return NetError.RecvFailed;
        };
    }
}

//---------------------------------------------------------------------
// Read one byte from a file descriptor (used for blocking stdin reads)
//---------------------------------------------------------------------
pub const ReadResult = enum { ok, eof, err };

pub fn readByte(fd: Fd, byte_out: *u8) ReadResult {
    if (comptime is_016) {
        const linux = std.os.linux;
        const rc = linux.read(fd, @ptrCast(byte_out), 1);
        return switch (linux.errno(rc)) {
            .SUCCESS => if (rc == 0) .eof else .ok,
            else => .err,
        };
    } else {
        const n = std.posix.read(fd, @as(*[1]u8, @ptrCast(byte_out))[0..]) catch return .err;
        return if (n == 0) .eof else .ok;
    }
}

pub const STDIN_FILENO: Fd = if (is_016) std.os.linux.STDIN_FILENO else std.posix.STDIN_FILENO;

//---------------------------------------------------------------------
// IPv4 dotted-decimal parser, version-agnostic.
//---------------------------------------------------------------------
pub fn parseIp4(host: []const u8, port: u16) !sockaddr.in {
    var octets: [4]u8 = undefined;
    var idx: usize = 0;
    var iter = std.mem.splitScalar(u8, host, '.');
    while (iter.next()) |part| {
        if (idx >= 4) return error.InvalidAddress;
        octets[idx] = std.fmt.parseInt(u8, part, 10) catch return error.InvalidAddress;
        idx += 1;
    }
    if (idx != 4) return error.InvalidAddress;

    const addr_be: u32 =
        (@as(u32, octets[0])) |
        (@as(u32, octets[1]) << 8) |
        (@as(u32, octets[2]) << 16) |
        (@as(u32, octets[3]) << 24);

    return .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = addr_be,
    };
}

//---------------------------------------------------------------------
// Lock-free mutex for simple producer/consumer (works on both versions)
//---------------------------------------------------------------------
pub const SpinMutex = struct {
    state: std.atomic.Value(u8) = .{ .raw = 0 },

    pub fn lock(self: *SpinMutex) void {
        while (self.state.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlock(self: *SpinMutex) void {
        self.state.store(0, .release);
    }
};
