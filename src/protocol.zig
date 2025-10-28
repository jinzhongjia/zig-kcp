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

/// Creates a new KCP control object.
///
/// Parameters:
///   - allocator: Memory allocator for KCP instance and buffers
///   - conv: Conversation ID for multiplexing multiple connections
///   - user: Optional user data pointer passed to output callback
///
/// Returns: Pointer to initialized KCP instance, or error if allocation fails
///
/// Example:
/// ```zig
/// const kcp_inst = try kcp.create(allocator, 1, null);
/// defer kcp.release(kcp_inst);
/// ```
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
        .nocwnd = false,
        .stream = false,
        .allocator = allocator,
        .user = user,
        .output = null,
        .segment_pool = .empty,
        .segment_pool_limit = types.computeSegmentPoolLimit(types.WND_RCV, types.WND_SND),
    };

    kcp.refreshSegmentPoolLimit();

    return kcp;
}

/// Releases a KCP control object and frees all associated resources.
///
/// This function cleans up all internal buffers and deallocates the KCP instance.
/// After calling this function, the KCP pointer is no longer valid.
///
/// Parameters:
///   - kcp: Pointer to KCP instance to release
pub fn release(kcp: *Kcp) void {
    for (kcp.snd_buf.items) |*seg| {
        seg.deinit();
    }
    kcp.snd_buf.deinit(kcp.allocator);

    for (kcp.rcv_buf.items) |*seg| {
        seg.deinit();
    }
    kcp.rcv_buf.deinit(kcp.allocator);

    for (kcp.snd_queue.items) |*seg| {
        seg.deinit();
    }
    kcp.snd_queue.deinit(kcp.allocator);

    for (kcp.rcv_queue.items) |*seg| {
        seg.deinit();
    }
    kcp.rcv_queue.deinit(kcp.allocator);

    kcp.acklist.deinit(kcp.allocator);
    kcp.allocator.free(kcp.buffer);
    for (kcp.segment_pool.items) |*seg| {
        seg.deinit();
    }
    kcp.segment_pool.deinit(kcp.allocator);
    kcp.allocator.destroy(kcp);
}

/// Sets the output callback function for sending packets.
///
/// The callback is invoked when KCP needs to send data over the network.
/// The application must implement this callback to handle actual packet transmission.
///
/// Parameters:
///   - kcp: Pointer to KCP instance
///   - output: Callback function with signature: fn(buf: []const u8, kcp: *Kcp, user: ?*anyopaque) anyerror!i32
///
/// Example:
/// ```zig
/// fn outputCallback(buf: []const u8, kcp: *Kcp, user: ?*anyopaque) !i32 {
///     // Send buf over UDP socket
///     return @intCast(buf.len);
/// }
/// kcp.setOutput(kcp_inst, outputCallback);
/// ```
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

/// Receives data from the KCP connection.
///
/// This function retrieves complete messages from the receive queue, handling
/// fragmentation and reassembly automatically.
///
/// Parameters:
///   - kcp: Pointer to KCP instance
///   - buffer: Destination buffer for received data
///
/// Returns: Number of bytes received, or error:
///   - KcpError.NoData: No data available to receive
///   - KcpError.FragmentIncomplete: Fragments not yet reassembled
///   - KcpError.BufferTooSmall: Buffer too small for message
///
/// Example:
/// ```zig
/// var buf: [1024]u8 = undefined;
/// const len = try kcp.recv(kcp_inst, &buf);
/// // Process buf[0..len]
/// ```
pub fn recv(kcp: *Kcp, buffer: []u8) !usize {
    if (kcp.rcv_queue.items.len == 0) {
        return types.KcpError.NoData;
    }

    const peek_size = try peeksize(kcp);
    if (peek_size < 0) {
        return types.KcpError.FragmentIncomplete;
    }

    const size: usize = @intCast(peek_size);
    if (size > buffer.len) {
        return types.KcpError.BufferTooSmall;
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
    if (n > 0) {
        for (0..n) |i| {
            const seg_ptr = &kcp.rcv_queue.items[i];
            const seg_value = seg_ptr.*;
            seg_ptr.* = Segment.init(kcp.allocator);
            kcp.recycleSegment(seg_value);
        }
        kcp.rcv_queue.replaceRangeAssumeCapacity(0, n, &.{});
        kcp.nrcv_que -= @as(u32, @intCast(n));
    }

    // move available data from rcv_buf -> rcv_queue
    try moveReadySegments(kcp);

    // fast recover
    if (kcp.nrcv_que < kcp.rcv_wnd and recover) {
        kcp.probe |= types.ASK_TELL;
    }

    return len;
}

/// Sends data through the KCP connection.
///
/// Data is queued for transmission and will be sent when flush() or update() is called.
/// Large data is automatically fragmented based on MTU/MSS settings.
///
/// Parameters:
///   - kcp: Pointer to KCP instance
///   - buffer: Data to send
///
/// Returns: Number of bytes queued for sending, or error:
///   - KcpError.EmptyData: Buffer is empty
///   - KcpError.FragmentTooLarge: Data requires too many fragments
///
/// Example:
/// ```zig
/// const message = "Hello, KCP!";
/// const sent = try kcp.send(kcp_inst, message);
/// ```
pub fn send(kcp: *Kcp, buffer: []const u8) !usize {
    var len = buffer.len;
    if (len == 0) {
        return types.KcpError.EmptyData;
    }

    var sent: usize = 0;

    // append to previous segment in streaming mode (if possible)
    if (kcp.stream) {
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
            return sent;
        }
    }

    const count = if (len <= kcp.mss) 1 else (len + kcp.mss - 1) / kcp.mss;

    if (count >= types.WND_RCV) {
        if (kcp.stream and sent > 0) {
            return sent;
        }
        return types.KcpError.FragmentTooLarge;
    }

    // fragment
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const size = if (len > kcp.mss) kcp.mss else len;
        var seg = kcp.takeSegment();
        var segment_owned = true;
        errdefer if (segment_owned) kcp.recycleSegment(seg);
        try seg.data.appendSlice(kcp.allocator, buffer[sent..][0..size]);
        seg.frg = if (!kcp.stream) @as(u32, @intCast(count - i - 1)) else 0;
        try kcp.snd_queue.append(kcp.allocator, seg);
        segment_owned = false;
        kcp.nsnd_que += 1;
        sent += size;
        len -= size;
    }

    return sent;
}

//---------------------------------------------------------------------
// move ready segments from rcv_buf to rcv_queue
//---------------------------------------------------------------------
fn moveReadySegments(kcp: *Kcp) !void {
    var ready_count: usize = 0;
    var expected_sn = kcp.rcv_nxt;

    while (ready_count < kcp.rcv_buf.items.len) {
        if (kcp.nrcv_que + @as(u32, @intCast(ready_count)) >= kcp.rcv_wnd) {
            break;
        }

        const seg = &kcp.rcv_buf.items[ready_count];
        if (seg.sn != expected_sn) {
            break;
        }

        ready_count += 1;
        expected_sn += 1;
    }

    if (ready_count == 0) {
        return;
    }

    try kcp.rcv_queue.ensureTotalCapacity(kcp.allocator, kcp.rcv_queue.items.len + ready_count);

    for (0..ready_count) |idx| {
        const moved = kcp.rcv_buf.items[idx];
        kcp.rcv_buf.items[idx] = Segment.init(kcp.allocator);
        kcp.rcv_queue.appendAssumeCapacity(moved);
    }

    kcp.rcv_buf.replaceRangeAssumeCapacity(0, ready_count, &.{});
    kcp.nrcv_buf -= @as(u32, @intCast(ready_count));
    kcp.nrcv_que += @as(u32, @intCast(ready_count));
    kcp.rcv_nxt = expected_sn;
}

//---------------------------------------------------------------------
// parse data
//---------------------------------------------------------------------
fn parseData(kcp: *Kcp, newseg: Segment) !void {
    const sn = newseg.sn;

    if (utils.itimediff(sn, kcp.rcv_nxt + kcp.rcv_wnd) >= 0 or
        utils.itimediff(sn, kcp.rcv_nxt) < 0)
    {
        kcp.recycleSegment(newseg);
        return;
    }

    // insert into rcv_buf in order using binary search
    var low: usize = 0;
    var high: usize = kcp.rcv_buf.items.len;
    var insert_idx: usize = 0;
    var repeat = false;

    while (low < high and !repeat) {
        const mid = low + (high - low) / 2;
        const seg = &kcp.rcv_buf.items[mid];
        const diff = utils.itimediff(sn, seg.sn);
        if (diff == 0) {
            repeat = true;
            break;
        } else if (diff > 0) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }

    if (!repeat) {
        insert_idx = low;
        try kcp.rcv_buf.insert(kcp.allocator, insert_idx, newseg);
        kcp.nrcv_buf += 1;
    } else {
        kcp.recycleSegment(newseg);
    }

    // move available data from rcv_buf -> rcv_queue
    try moveReadySegments(kcp);
}

/// Processes incoming packet data.
///
/// Call this function when receiving packets from the network. KCP will parse
/// the packet, update state, and queue data for the application to receive.
///
/// Parameters:
///   - kcp: Pointer to KCP instance
///   - data: Raw packet data received from network
///
/// Returns: 0 on success, negative value on error (invalid packet format)
///
/// Example:
/// ```zig
/// // When UDP packet received
/// _ = try kcp.input(kcp_inst, udp_packet);
/// ```
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

        const len_usize = @as(usize, @intCast(len));

        if (len > kcp.mtu or data.len - offset < len_usize) {
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
                    var seg = kcp.takeSegment();
                    var segment_owned = true;
                    errdefer if (segment_owned) kcp.recycleSegment(seg);
                    seg.conv = conv;
                    seg.cmd = cmd;
                    seg.frg = frg;
                    seg.wnd = wnd;
                    seg.ts = ts;
                    seg.sn = sn;
                    seg.una = una;

                    if (len > 0) {
                        try seg.data.appendSlice(kcp.allocator, data[offset..][0..len_usize]);
                    }

                    try parseData(kcp, seg);
                    segment_owned = false;
                }
            }
        } else if (cmd == types.CMD_WASK) {
            kcp.probe |= types.ASK_TELL;
        } else if (cmd == types.CMD_WINS) {
            // do nothing
        }

        offset += len_usize;
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
    defer seg.deinit();

    seg.conv = kcp.conv;
    seg.cmd = types.CMD_ACK;
    seg.frg = 0;
    seg.wnd = control.wndUnused(kcp);
    seg.una = kcp.rcv_nxt;

    var offset: usize = 0;

    // flush acknowledges
    for (kcp.acklist.items) |ack| {
        if (offset + types.OVERHEAD > kcp.mtu) {
            if (kcp.output) |output_fn| {
                _ = try output_fn(kcp.buffer[0..offset], kcp, kcp.user);
            }
            offset = 0;
        }
        seg.sn = ack.sn;
        seg.ts = ack.ts;
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
    if (!kcp.nocwnd) {
        cwnd = utils.imin(kcp.cwnd, cwnd);
    }

    // move data from snd_queue to snd_buf
    var move_count: usize = 0;
    while (utils.itimediff(kcp.snd_nxt, kcp.snd_una + cwnd) < 0) {
        if (move_count >= kcp.snd_queue.items.len) {
            break;
        }

        var newseg = kcp.snd_queue.items[move_count];
        kcp.snd_queue.items[move_count] = Segment.init(kcp.allocator);
        move_count += 1;

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

    if (move_count > 0) {
        kcp.snd_queue.replaceRangeAssumeCapacity(0, move_count, &.{});
        kcp.nsnd_que -= @as(u32, @intCast(move_count));
    }

    // calculate resent
    const resent: u32 = if (kcp.fastresend > 0) kcp.fastresend else types.FASTACK_UNLIMITED;
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
                kcp.state = types.STATE_DEAD;
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

/// Updates KCP state and flushes pending data.
///
/// Call this function periodically (e.g., every 10-100ms) to drive the KCP state machine.
/// This handles retransmissions, acknowledgments, and flow control.
///
/// Parameters:
///   - kcp: Pointer to KCP instance
///   - current: Current timestamp in milliseconds
///
/// Example:
/// ```zig
/// while (running) {
///     const now = getCurrentTimeMs();
///     try kcp.update(kcp_inst, now);
///     std.time.sleep(10 * std.time.ns_per_ms);
/// }
/// ```
pub fn update(kcp: *Kcp, current: u32) !void {
    kcp.current = current;

    if (kcp.updated == 0) {
        kcp.updated = 1;
        kcp.ts_flush = kcp.current;
    }

    var slap = utils.itimediff(kcp.current, kcp.ts_flush);

    if (slap >= types.TIME_DIFF_LIMIT or slap < -types.TIME_DIFF_LIMIT) {
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

    if (utils.itimediff(current, ts_flush) >= types.TIME_DIFF_LIMIT or
        utils.itimediff(current, ts_flush) < -types.TIME_DIFF_LIMIT)
    {
        ts_flush = current;
    }

    if (utils.itimediff(current, ts_flush) >= 0) {
        return current;
    }

    const tm_flush = utils.itimediff(ts_flush, current);
    var tm_packet: i32 = types.MAX_PACKET_TIME;

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
    kcp.refreshSegmentPoolLimit();
}

pub fn waitsnd(kcp: *const Kcp) u32 {
    return kcp.nsnd_buf + kcp.nsnd_que;
}

/// Configures KCP working mode for different latency/bandwidth trade-offs.
///
/// Parameters:
///   - kcp: Pointer to KCP instance
///   - nodelay: 0=normal mode (default), 1=low-latency mode, 2=ultra-low-latency
///   - interval: Internal update interval in ms (10-5000, default 100ms)
///   - resend: Fast retransmission threshold (0=disabled, default 0)
///   - nc: Disable congestion control: 0=enable (default), 1=disable
///
/// Common configurations:
/// - Normal mode:  setNodelay(kcp, 0, 100, 0, 0) - Best for throughput
/// - Fast mode:    setNodelay(kcp, 1, 10, 2, 1)  - Low latency
/// - Extreme mode: setNodelay(kcp, 2, 10, 2, 1)  - Minimum latency
///
/// Example:
/// ```zig
/// // Configure for low latency gaming
/// kcp.setNodelay(kcp_inst, 1, 10, 2, 1);
/// ```
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
        kcp.fastresend = @as(u32, @intCast(resend));
    }
    if (nc >= 0) {
        kcp.nocwnd = nc != 0;
    }
}
