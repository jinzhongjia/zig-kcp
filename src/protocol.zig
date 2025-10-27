//=====================================================================
//
// protocol.zig - KCP Core Protocol Implementation
//
//=====================================================================

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const utils = @import("utils.zig");
const codec = @import("codec.zig");
const control = @import("control.zig");
const segment = @import("segment.zig");

const Kcp = types.Kcp;
const Segment = types.Segment;

//---------------------------------------------------------------------
// create a new kcp control object
//---------------------------------------------------------------------
pub fn create(allocator: Allocator, conv: u32, user: ?*anyopaque) !*Kcp {
    const kcp = try allocator.create(Kcp);
    errdefer allocator.destroy(kcp);

    const buffer = try allocator.alloc(u8, (types.MTU_DEF + types.OVERHEAD) * 3);
    errdefer allocator.free(buffer);

    kcp.* = Kcp{
        .conv = conv,
        .mtu = types.MTU_DEF,
        .mss = types.MTU_DEF - types.OVERHEAD,
        .state = 0,
        .snd_una = 0,
        .snd_nxt = 0,
        .rcv_nxt = 0,
        .ts_recent = 0,
        .ts_lastack = 0,
        .ssthresh = types.THRESH_INIT,
        .rx_rttval = 0,
        .rx_srtt = 0,
        .rx_rto = types.RTO_DEF,
        .rx_minrto = types.RTO_MIN,
        .snd_wnd = types.WND_SND,
        .rcv_wnd = types.WND_RCV,
        .rmt_wnd = types.WND_RCV,
        .cwnd = 0,
        .probe = 0,
        .current = 0,
        .interval = types.INTERVAL,
        .ts_flush = types.INTERVAL,
        .xmit = 0,
        .nrcv_buf = 0,
        .nsnd_buf = 0,
        .nrcv_que = 0,
        .nsnd_que = 0,
        .nodelay = 0,
        .updated = 0,
        .ts_probe = 0,
        .probe_wait = 0,
        .dead_link = types.DEADLINK,
        .incr = 0,
        .snd_queue = .empty,
        .rcv_queue = .empty,
        .snd_buf = .empty,
        .rcv_buf = .empty,
        .acklist = .empty,
        .buffer = buffer,
        .fastresend = 0,
        .fastlimit = types.FASTACK_LIMIT,
        .nocwnd = 0,
        .stream = 0,
        .allocator = allocator,
        .user = user,
        .output = null,
    };

    return kcp;
}

//---------------------------------------------------------------------
// release kcp control object
//---------------------------------------------------------------------
pub fn release(kcp: *Kcp) void {
    for (kcp.snd_buf.items) |*seg| {
        seg.deinit(kcp.allocator);
    }
    kcp.snd_buf.deinit(kcp.allocator);

    for (kcp.rcv_buf.items) |*seg| {
        seg.deinit(kcp.allocator);
    }
    kcp.rcv_buf.deinit(kcp.allocator);

    for (kcp.snd_queue.items) |*seg| {
        seg.deinit(kcp.allocator);
    }
    kcp.snd_queue.deinit(kcp.allocator);

    for (kcp.rcv_queue.items) |*seg| {
        seg.deinit(kcp.allocator);
    }
    kcp.rcv_queue.deinit(kcp.allocator);

    kcp.acklist.deinit(kcp.allocator);
    kcp.allocator.free(kcp.buffer);
    kcp.allocator.destroy(kcp);
}

//---------------------------------------------------------------------
// set output callback
//---------------------------------------------------------------------
pub fn setOutput(kcp: *Kcp, output: *const fn (buf: []const u8, k: *Kcp, user: ?*anyopaque) anyerror!i32) void {
    kcp.output = output;
}

//---------------------------------------------------------------------
// peek data size
//---------------------------------------------------------------------
pub fn peeksize(kcp: *const Kcp) !i32 {
    if (kcp.rcv_queue.items.len == 0) {
        return -1;
    }

    const seg = &kcp.rcv_queue.items[0];
    if (seg.frg == 0) {
        return @as(i32, @intCast(seg.data.items.len));
    }

    if (kcp.nrcv_que < seg.frg + 1) {
        return -1;
    }

    var length: usize = 0;
    for (kcp.rcv_queue.items) |*s| {
        length += s.data.items.len;
        if (s.frg == 0) {
            break;
        }
    }

    return @as(i32, @intCast(length));
}

//---------------------------------------------------------------------
// user/upper level recv
//---------------------------------------------------------------------
pub fn recv(kcp: *Kcp, buffer: []u8) !i32 {
    if (kcp.rcv_queue.items.len == 0) {
        return -1;
    }

    const peek_size = try peeksize(kcp);
    if (peek_size < 0) {
        return -2;
    }

    if (peek_size > buffer.len) {
        return -3;
    }

    const recover = kcp.nrcv_que >= kcp.rcv_wnd;

    // merge fragment
    var len: usize = 0;
    var n: usize = 0;
    while (n < kcp.rcv_queue.items.len) {
        const seg = &kcp.rcv_queue.items[n];
        @memcpy(buffer[len..][0..seg.data.items.len], seg.data.items);
        len += seg.data.items.len;

        const fragment = seg.frg;
        n += 1;

        if (fragment == 0) {
            break;
        }
    }

    // remove segments from queue
    for (0..n) |_| {
        var seg = kcp.rcv_queue.orderedRemove(0);
        seg.deinit(kcp.allocator);
        kcp.nrcv_que -= 1;
    }

    // move available data from rcv_buf -> rcv_queue
    while (kcp.rcv_buf.items.len > 0) {
        const seg = &kcp.rcv_buf.items[0];
        if (seg.sn == kcp.rcv_nxt and kcp.nrcv_que < kcp.rcv_wnd) {
            const removed_seg = kcp.rcv_buf.orderedRemove(0);
            try kcp.rcv_queue.append(kcp.allocator, removed_seg);
            kcp.nrcv_buf -= 1;
            kcp.nrcv_que += 1;
            kcp.rcv_nxt += 1;
        } else {
            break;
        }
    }

    // fast recover
    if (kcp.nrcv_que < kcp.rcv_wnd and recover) {
        kcp.probe |= types.ASK_TELL;
    }

    return @as(i32, @intCast(len));
}

//---------------------------------------------------------------------
// user/upper level send
//---------------------------------------------------------------------
pub fn send(kcp: *Kcp, buffer: []const u8) !i32 {
    var len = buffer.len;
    if (len == 0) {
        return -1;
    }

    var sent: usize = 0;

    // append to previous segment in streaming mode (if possible)
    if (kcp.stream != 0) {
        if (kcp.snd_queue.items.len > 0) {
            const old = &kcp.snd_queue.items[kcp.snd_queue.items.len - 1];
            if (old.data.items.len < kcp.mss) {
                const capacity = kcp.mss - old.data.items.len;
                const extend = if (len < capacity) len else capacity;
                try old.data.appendSlice(kcp.allocator, buffer[0..extend]);
                len -= extend;
                sent = extend;
            }
        }
        if (len == 0) {
            return @as(i32, @intCast(sent));
        }
    }

    const count = if (len <= kcp.mss) 1 else (len + kcp.mss - 1) / kcp.mss;

    if (count >= types.WND_RCV) {
        if (kcp.stream != 0 and sent > 0) {
            return @as(i32, @intCast(sent));
        }
        return -2;
    }

    // fragment
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const size = if (len > kcp.mss) kcp.mss else len;
        var seg = Segment.init(kcp.allocator);
        try seg.data.appendSlice(kcp.allocator, buffer[sent..][0..size]);
        seg.frg = if (kcp.stream == 0) @as(u32, @intCast(count - i - 1)) else 0;
        try kcp.snd_queue.append(kcp.allocator, seg);
        kcp.nsnd_que += 1;
        sent += size;
        len -= size;
    }

    return @as(i32, @intCast(sent));
}

//---------------------------------------------------------------------
// parse data
//---------------------------------------------------------------------
fn parseData(kcp: *Kcp, newseg: Segment) !void {
    const sn = newseg.sn;

    if (utils.itimediff(sn, kcp.rcv_nxt + kcp.rcv_wnd) >= 0 or
        utils.itimediff(sn, kcp.rcv_nxt) < 0)
    {
        var seg_copy = newseg;
        seg_copy.deinit(kcp.allocator);
        return;
    }

    // insert into rcv_buf in order
    var insert_idx: usize = kcp.rcv_buf.items.len;
    var repeat = false;

    var i: usize = kcp.rcv_buf.items.len;
    while (i > 0) {
        i -= 1;
        const seg = &kcp.rcv_buf.items[i];
        if (seg.sn == sn) {
            repeat = true;
            break;
        }
        if (utils.itimediff(sn, seg.sn) > 0) {
            insert_idx = i + 1;
            break;
        }
        insert_idx = i;
    }

    if (!repeat) {
        try kcp.rcv_buf.insert(kcp.allocator, insert_idx, newseg);
        kcp.nrcv_buf += 1;
    } else {
        var seg_copy = newseg;
        seg_copy.deinit(kcp.allocator);
    }

    // move available data from rcv_buf -> rcv_queue
    while (kcp.rcv_buf.items.len > 0) {
        const seg = &kcp.rcv_buf.items[0];
        if (seg.sn == kcp.rcv_nxt and kcp.nrcv_que < kcp.rcv_wnd) {
            const removed_seg = kcp.rcv_buf.orderedRemove(0);
            try kcp.rcv_queue.append(kcp.allocator, removed_seg);
            kcp.nrcv_buf -= 1;
            kcp.nrcv_que += 1;
            kcp.rcv_nxt += 1;
        } else {
            break;
        }
    }
}

//---------------------------------------------------------------------
// input data
//---------------------------------------------------------------------
pub fn input(kcp: *Kcp, data: []const u8) !i32 {
    const prev_una = kcp.snd_una;
    var maxack: u32 = 0;
    var latest_ts: u32 = 0;
    var flag: i32 = 0;

    if (data.len < types.OVERHEAD) {
        return -1;
    }

    var offset: usize = 0;
    while (offset < data.len) {
        if (data.len - offset < types.OVERHEAD) {
            break;
        }

        var result32 = codec.decode32u(data, offset);
        const conv = result32.value;
        offset = result32.offset;
        if (conv != kcp.conv) {
            return -1;
        }

        var result8 = codec.decode8u(data, offset);
        const cmd = result8.value;
        offset = result8.offset;

        result8 = codec.decode8u(data, offset);
        const frg = result8.value;
        offset = result8.offset;

        const result16 = codec.decode16u(data, offset);
        const wnd = result16.value;
        offset = result16.offset;

        result32 = codec.decode32u(data, offset);
        const ts = result32.value;
        offset = result32.offset;

        result32 = codec.decode32u(data, offset);
        const sn = result32.value;
        offset = result32.offset;

        result32 = codec.decode32u(data, offset);
        const una = result32.value;
        offset = result32.offset;

        result32 = codec.decode32u(data, offset);
        const len = result32.value;
        offset = result32.offset;

        if (data.len - offset < len) {
            return -2;
        }

        if (cmd != types.CMD_PUSH and cmd != types.CMD_ACK and
            cmd != types.CMD_WASK and cmd != types.CMD_WINS)
        {
            return -3;
        }

        kcp.rmt_wnd = wnd;
        control.parseUna(kcp, una);
        control.shrinkBuf(kcp);

        if (cmd == types.CMD_ACK) {
            if (utils.itimediff(kcp.current, ts) >= 0) {
                control.updateAck(kcp, utils.itimediff(kcp.current, ts));
            }
            control.parseAck(kcp, sn);
            control.shrinkBuf(kcp);
            if (flag == 0) {
                flag = 1;
                maxack = sn;
                latest_ts = ts;
            } else {
                if (utils.itimediff(sn, maxack) > 0) {
                    if (utils.itimediff(ts, latest_ts) > 0) {
                        maxack = sn;
                        latest_ts = ts;
                    }
                }
            }
        } else if (cmd == types.CMD_PUSH) {
            if (utils.itimediff(sn, kcp.rcv_nxt + kcp.rcv_wnd) < 0) {
                try control.ackPush(kcp, sn, ts);
                if (utils.itimediff(sn, kcp.rcv_nxt) >= 0) {
                    var seg = Segment.init(kcp.allocator);
                    seg.conv = conv;
                    seg.cmd = cmd;
                    seg.frg = frg;
                    seg.wnd = wnd;
                    seg.ts = ts;
                    seg.sn = sn;
                    seg.una = una;

                    if (len > 0) {
                        try seg.data.appendSlice(kcp.allocator, data[offset..][0..len]);
                    }

                    try parseData(kcp, seg);
                }
            }
        } else if (cmd == types.CMD_WASK) {
            kcp.probe |= types.ASK_TELL;
        } else if (cmd == types.CMD_WINS) {
            // do nothing
        }

        offset += len;
    }

    if (flag != 0) {
        control.parseFastack(kcp, maxack, latest_ts);
    }

    if (utils.itimediff(kcp.snd_una, prev_una) > 0) {
        if (kcp.cwnd < kcp.rmt_wnd) {
            const mss = kcp.mss;
            if (kcp.cwnd < kcp.ssthresh) {
                kcp.cwnd += 1;
                kcp.incr += mss;
            } else {
                if (kcp.incr < mss) {
                    kcp.incr = mss;
                }
                kcp.incr += (mss * mss) / kcp.incr + (mss / 16);
                if ((kcp.cwnd + 1) * mss <= kcp.incr) {
                    kcp.cwnd = (kcp.incr + mss - 1) / if (mss > 0) mss else 1;
                }
            }
            if (kcp.cwnd > kcp.rmt_wnd) {
                kcp.cwnd = kcp.rmt_wnd;
                kcp.incr = kcp.rmt_wnd * mss;
            }
        }
    }

    return 0;
}

//---------------------------------------------------------------------
// flush pending data
//---------------------------------------------------------------------
pub fn flush(kcp: *Kcp) !void {
    if (kcp.updated == 0) {
        return;
    }

    var seg = Segment.init(kcp.allocator);
    defer seg.deinit(kcp.allocator);

    seg.conv = kcp.conv;
    seg.cmd = types.CMD_ACK;
    seg.frg = 0;
    seg.wnd = control.wndUnused(kcp);
    seg.una = kcp.rcv_nxt;

    var offset: usize = 0;

    // flush acknowledges
    var i: usize = 0;
    while (i < kcp.acklist.items.len) : (i += 2) {
        if (offset + types.OVERHEAD > kcp.mtu) {
            if (kcp.output) |output_fn| {
                _ = try output_fn(kcp.buffer[0..offset], kcp, kcp.user);
            }
            offset = 0;
        }
        seg.sn = kcp.acklist.items[i];
        seg.ts = kcp.acklist.items[i + 1];
        offset = segment.encode(&seg, kcp.buffer, offset);
    }
    kcp.acklist.clearRetainingCapacity();

    // probe window size (if remote window size equals zero)
    if (kcp.rmt_wnd == 0) {
        if (kcp.probe_wait == 0) {
            kcp.probe_wait = types.PROBE_INIT;
            kcp.ts_probe = kcp.current + kcp.probe_wait;
        } else {
            if (utils.itimediff(kcp.current, kcp.ts_probe) >= 0) {
                if (kcp.probe_wait < types.PROBE_INIT) {
                    kcp.probe_wait = types.PROBE_INIT;
                }
                kcp.probe_wait += kcp.probe_wait / 2;
                if (kcp.probe_wait > types.PROBE_LIMIT) {
                    kcp.probe_wait = types.PROBE_LIMIT;
                }
                kcp.ts_probe = kcp.current + kcp.probe_wait;
                kcp.probe |= types.ASK_SEND;
            }
        }
    } else {
        kcp.ts_probe = 0;
        kcp.probe_wait = 0;
    }

    // flush window probing commands
    if (kcp.probe & types.ASK_SEND != 0) {
        seg.cmd = types.CMD_WASK;
        if (offset + types.OVERHEAD > kcp.mtu) {
            if (kcp.output) |output_fn| {
                _ = try output_fn(kcp.buffer[0..offset], kcp, kcp.user);
            }
            offset = 0;
        }
        offset = segment.encode(&seg, kcp.buffer, offset);
    }

    if (kcp.probe & types.ASK_TELL != 0) {
        seg.cmd = types.CMD_WINS;
        if (offset + types.OVERHEAD > kcp.mtu) {
            if (kcp.output) |output_fn| {
                _ = try output_fn(kcp.buffer[0..offset], kcp, kcp.user);
            }
            offset = 0;
        }
        offset = segment.encode(&seg, kcp.buffer, offset);
    }

    kcp.probe = 0;

    // calculate window size
    var cwnd = utils.imin(kcp.snd_wnd, kcp.rmt_wnd);
    if (kcp.nocwnd == 0) {
        cwnd = utils.imin(kcp.cwnd, cwnd);
    }

    // move data from snd_queue to snd_buf
    while (utils.itimediff(kcp.snd_nxt, kcp.snd_una + cwnd) < 0) {
        if (kcp.snd_queue.items.len == 0) {
            break;
        }

        var newseg = kcp.snd_queue.orderedRemove(0);
        kcp.nsnd_que -= 1;

        newseg.conv = kcp.conv;
        newseg.cmd = types.CMD_PUSH;
        newseg.wnd = seg.wnd;
        newseg.ts = kcp.current;
        newseg.sn = kcp.snd_nxt;
        kcp.snd_nxt += 1;
        newseg.una = kcp.rcv_nxt;
        newseg.resendts = kcp.current;
        newseg.rto = kcp.rx_rto;
        newseg.fastack = 0;
        newseg.xmit = 0;

        try kcp.snd_buf.append(kcp.allocator, newseg);
        kcp.nsnd_buf += 1;
    }

    // calculate resent
    const resent: u32 = if (kcp.fastresend > 0) @as(u32, @intCast(kcp.fastresend)) else 0xffffffff;
    const rtomin: u32 = if (kcp.nodelay == 0) (kcp.rx_rto >> 3) else 0;

    var change: i32 = 0;
    var lost: i32 = 0;

    // flush data segments
    for (kcp.snd_buf.items) |*segment_ptr| {
        var needsend = false;
        if (segment_ptr.xmit == 0) {
            needsend = true;
            segment_ptr.xmit += 1;
            segment_ptr.rto = kcp.rx_rto;
            segment_ptr.resendts = kcp.current + segment_ptr.rto + rtomin;
        } else if (utils.itimediff(kcp.current, segment_ptr.resendts) >= 0) {
            needsend = true;
            segment_ptr.xmit += 1;
            kcp.xmit += 1;
            if (kcp.nodelay == 0) {
                segment_ptr.rto += utils.imax(segment_ptr.rto, kcp.rx_rto);
            } else {
                const step: i32 = if (kcp.nodelay < 2) @as(i32, @intCast(segment_ptr.rto)) else @as(i32, @intCast(kcp.rx_rto));
                segment_ptr.rto = @as(u32, @intCast(@as(i32, @intCast(segment_ptr.rto)) + @divTrunc(step, 2)));
            }
            segment_ptr.resendts = kcp.current + segment_ptr.rto;
            lost = 1;
        } else if (segment_ptr.fastack >= resent) {
            if (segment_ptr.xmit <= kcp.fastlimit or kcp.fastlimit <= 0) {
                needsend = true;
                segment_ptr.xmit += 1;
                segment_ptr.fastack = 0;
                segment_ptr.resendts = kcp.current + segment_ptr.rto;
                change += 1;
            }
        }

        if (needsend) {
            segment_ptr.ts = kcp.current;
            segment_ptr.wnd = seg.wnd;
            segment_ptr.una = kcp.rcv_nxt;

            const need = types.OVERHEAD + segment_ptr.data.items.len;

            if (offset + need > kcp.mtu) {
                if (kcp.output) |output_fn| {
                    _ = try output_fn(kcp.buffer[0..offset], kcp, kcp.user);
                }
                offset = 0;
            }

            offset = segment.encode(segment_ptr, kcp.buffer, offset);

            if (segment_ptr.data.items.len > 0) {
                @memcpy(kcp.buffer[offset..][0..segment_ptr.data.items.len], segment_ptr.data.items);
                offset += segment_ptr.data.items.len;
            }

            if (segment_ptr.xmit >= kcp.dead_link) {
                kcp.state = @as(u32, @bitCast(@as(i32, -1)));
            }
        }
    }

    // flush remain segments
    if (offset > 0) {
        if (kcp.output) |output_fn| {
            _ = try output_fn(kcp.buffer[0..offset], kcp, kcp.user);
        }
    }

    // update ssthresh
    if (change != 0) {
        const inflight = kcp.snd_nxt -% kcp.snd_una;
        kcp.ssthresh = inflight / 2;
        if (kcp.ssthresh < types.THRESH_MIN) {
            kcp.ssthresh = types.THRESH_MIN;
        }
        kcp.cwnd = kcp.ssthresh + resent;
        kcp.incr = kcp.cwnd * kcp.mss;
    }

    if (lost != 0) {
        kcp.ssthresh = cwnd / 2;
        if (kcp.ssthresh < types.THRESH_MIN) {
            kcp.ssthresh = types.THRESH_MIN;
        }
        kcp.cwnd = 1;
        kcp.incr = kcp.mss;
    }

    if (kcp.cwnd < 1) {
        kcp.cwnd = 1;
        kcp.incr = kcp.mss;
    }
}

//---------------------------------------------------------------------
// update state
//---------------------------------------------------------------------
pub fn update(kcp: *Kcp, current: u32) !void {
    kcp.current = current;

    if (kcp.updated == 0) {
        kcp.updated = 1;
        kcp.ts_flush = kcp.current;
    }

    var slap = utils.itimediff(kcp.current, kcp.ts_flush);

    if (slap >= 10000 or slap < -10000) {
        kcp.ts_flush = kcp.current;
        slap = 0;
    }

    if (slap >= 0) {
        kcp.ts_flush += kcp.interval;
        if (utils.itimediff(kcp.current, kcp.ts_flush) >= 0) {
            kcp.ts_flush = kcp.current + kcp.interval;
        }
        try flush(kcp);
    }
}

//---------------------------------------------------------------------
// check when to call update again
//---------------------------------------------------------------------
pub fn check(kcp: *const Kcp, current: u32) u32 {
    if (kcp.updated == 0) {
        return current;
    }

    var ts_flush = kcp.ts_flush;

    if (utils.itimediff(current, ts_flush) >= 10000 or
        utils.itimediff(current, ts_flush) < -10000)
    {
        ts_flush = current;
    }

    if (utils.itimediff(current, ts_flush) >= 0) {
        return current;
    }

    const tm_flush = utils.itimediff(ts_flush, current);
    var tm_packet: i32 = 0x7fffffff;

    for (kcp.snd_buf.items) |*seg_item| {
        const diff = utils.itimediff(seg_item.resendts, current);
        if (diff <= 0) {
            return current;
        }
        if (diff < tm_packet) {
            tm_packet = diff;
        }
    }

    var minimal = if (tm_packet < tm_flush) @as(u32, @intCast(tm_packet)) else @as(u32, @intCast(tm_flush));
    if (minimal >= kcp.interval) {
        minimal = kcp.interval;
    }

    return current + minimal;
}

//---------------------------------------------------------------------
// configuration functions
//---------------------------------------------------------------------
pub fn setMtu(kcp: *Kcp, mtu: u32) !void {
    if (mtu < 50 or mtu < types.OVERHEAD) {
        return error.InvalidMtu;
    }

    const buffer = try kcp.allocator.alloc(u8, (mtu + types.OVERHEAD) * 3);
    kcp.allocator.free(kcp.buffer);
    kcp.buffer = buffer;
    kcp.mtu = mtu;
    kcp.mss = kcp.mtu - types.OVERHEAD;
}

pub fn wndsize(kcp: *Kcp, sndwnd: u32, rcvwnd: u32) void {
    if (sndwnd > 0) {
        kcp.snd_wnd = sndwnd;
    }
    if (rcvwnd > 0) {
        kcp.rcv_wnd = utils.imax(rcvwnd, types.WND_RCV);
    }
}

pub fn waitsnd(kcp: *const Kcp) u32 {
    return kcp.nsnd_buf + kcp.nsnd_que;
}

pub fn setNodelay(kcp: *Kcp, nodelay_: i32, interval_: i32, resend: i32, nc: i32) void {
    if (nodelay_ >= 0) {
        kcp.nodelay = @as(u32, @intCast(nodelay_));
        if (nodelay_ != 0) {
            kcp.rx_minrto = types.RTO_NDL;
        } else {
            kcp.rx_minrto = types.RTO_MIN;
        }
    }
    if (interval_ >= 0) {
        var interval = interval_;
        if (interval > 5000) {
            interval = 5000;
        } else if (interval < 10) {
            interval = 10;
        }
        kcp.interval = @as(u32, @intCast(interval));
    }
    if (resend >= 0) {
        kcp.fastresend = resend;
    }
    if (nc >= 0) {
        kcp.nocwnd = nc;
    }
}
