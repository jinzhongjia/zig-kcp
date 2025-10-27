//=====================================================================
//
// types.zig - KCP Types and Constants
//
//=====================================================================

const std = @import("std");
const Allocator = std.mem.Allocator;

//=====================================================================
// KCP CONSTANTS
//=====================================================================
pub const RTO_NDL: u32 = 30; // no delay min rto
pub const RTO_MIN: u32 = 100; // normal min rto
pub const RTO_DEF: u32 = 200;
pub const RTO_MAX: u32 = 60000;
pub const CMD_PUSH: u32 = 81; // cmd: push data
pub const CMD_ACK: u32 = 82; // cmd: ack
pub const CMD_WASK: u32 = 83; // cmd: window probe (ask)
pub const CMD_WINS: u32 = 84; // cmd: window size (tell)
pub const ASK_SEND: u32 = 1; // need to send IKCP_CMD_WASK
pub const ASK_TELL: u32 = 2; // need to send IKCP_CMD_WINS
pub const WND_SND: u32 = 32;
pub const WND_RCV: u32 = 128; // must >= max fragment size
pub const MTU_DEF: u32 = 1400;
pub const ACK_FAST: u32 = 3;
pub const INTERVAL: u32 = 100;
pub const OVERHEAD: u32 = 24;
pub const DEADLINK: u32 = 20;
pub const THRESH_INIT: u32 = 2;
pub const THRESH_MIN: u32 = 2;
pub const PROBE_INIT: u32 = 7000; // 7 secs to probe window size
pub const PROBE_LIMIT: u32 = 120000; // up to 120 secs to probe window
pub const FASTACK_LIMIT: u32 = 5; // max times to trigger fastack

// State constants
pub const STATE_CONNECTED: u32 = 0;
pub const STATE_DEAD: u32 = 0xFFFFFFFF;

// Magic numbers
pub const FASTACK_UNLIMITED: u32 = 0xffffffff;
pub const TIME_DIFF_LIMIT: i32 = 10000;
pub const MAX_PACKET_TIME: i32 = 0x7fffffff;

//=====================================================================
// KCP ERROR TYPES
//=====================================================================
pub const KcpError = error{
    NoData,
    BufferTooSmall,
    FragmentIncomplete,
    EmptyData,
    FragmentTooLarge,
};

//=====================================================================
// SEGMENT
//=====================================================================
pub const Segment = struct {
    conv: u32 = 0,
    cmd: u32 = 0,
    frg: u32 = 0,
    wnd: u32 = 0,
    ts: u32 = 0,
    sn: u32 = 0,
    una: u32 = 0,
    resendts: u32 = 0,
    rto: u32 = 0,
    fastack: u32 = 0,
    xmit: u32 = 0,
    data: std.ArrayList(u8),
    allocator: Allocator,

    pub fn init(allocator: Allocator) Segment {
        return Segment{
            .data = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Segment) void {
        self.data.deinit(self.allocator);
    }
};

//=====================================================================
// KCP CONTROL BLOCK
//=====================================================================
pub const Kcp = struct {
    conv: u32,
    mtu: u32,
    mss: u32,
    state: u32,

    snd_una: u32,
    snd_nxt: u32,
    rcv_nxt: u32,

    ts_recent: u32,
    ts_lastack: u32,
    ssthresh: u32,

    rx_rttval: i32,
    rx_srtt: i32,
    rx_rto: u32,
    rx_minrto: u32,

    snd_wnd: u32,
    rcv_wnd: u32,
    rmt_wnd: u32,
    cwnd: u32,
    probe: u32,

    current: u32,
    interval: u32,
    ts_flush: u32,
    xmit: u32,

    nrcv_buf: u32,
    nsnd_buf: u32,
    nrcv_que: u32,
    nsnd_que: u32,

    nodelay: u32,
    updated: u32,

    ts_probe: u32,
    probe_wait: u32,

    dead_link: u32,
    incr: u32,

    snd_queue: std.ArrayList(Segment),
    rcv_queue: std.ArrayList(Segment),
    snd_buf: std.ArrayList(Segment),
    rcv_buf: std.ArrayList(Segment),

    acklist: std.ArrayList(u32),

    buffer: []u8,
    fastresend: u32,
    fastlimit: u32,
    nocwnd: bool,
    stream: bool,

    allocator: Allocator,
    user: ?*anyopaque,
    output: ?*const fn (buf: []const u8, kcp: *Kcp, user: ?*anyopaque) anyerror!i32,
};
