//=====================================================================
//
// control.zig - Flow Control and Congestion Control
//
//=====================================================================

const std = @import("std");
const types = @import("types.zig");
const utils = @import("utils.zig");
const Kcp = types.Kcp;
const Segment = types.Segment;

//---------------------------------------------------------------------
// update ack
//---------------------------------------------------------------------
pub fn updateAck(kcp: *Kcp, rtt: i32) void {
    if (kcp.rx_srtt == 0) {
        kcp.rx_srtt = rtt;
        kcp.rx_rttval = @divTrunc(rtt, 2);
    } else {
        const delta = if (rtt > kcp.rx_srtt) rtt - kcp.rx_srtt else kcp.rx_srtt - rtt;
        kcp.rx_rttval = @divTrunc((3 * kcp.rx_rttval + delta), 4);
        kcp.rx_srtt = @divTrunc((7 * kcp.rx_srtt + rtt), 8);
        if (kcp.rx_srtt < 1) {
            kcp.rx_srtt = 1;
        }
    }
    const rto_i32 = kcp.rx_srtt + @as(i32, @intCast(utils.imax(kcp.interval, @as(u32, @intCast(4 * kcp.rx_rttval)))));
    const rto = @as(u32, @intCast(rto_i32));
    kcp.rx_rto = utils.ibound(kcp.rx_minrto, rto, types.RTO_MAX);
}

//---------------------------------------------------------------------
// shrink send buffer
//---------------------------------------------------------------------
pub fn shrinkBuf(kcp: *Kcp) void {
    if (kcp.snd_buf.items.len > 0) {
        kcp.snd_una = kcp.snd_buf.items[0].sn;
    } else {
        kcp.snd_una = kcp.snd_nxt;
    }
}

//---------------------------------------------------------------------
// parse ack
//---------------------------------------------------------------------
pub fn parseAck(kcp: *Kcp, sn: u32) void {
    if (utils.itimediff(sn, kcp.snd_una) < 0 or utils.itimediff(sn, kcp.snd_nxt) >= 0) {
        return;
    }

    var left: usize = 0;
    var right: usize = kcp.snd_buf.items.len;

    while (left < right) {
        const mid = left + (right - left) / 2;
        const seg = &kcp.snd_buf.items[mid];
        const diff = utils.itimediff(sn, seg.sn);
        if (diff == 0) {
            const removed = kcp.snd_buf.orderedRemove(mid);
            kcp.recycleSegment(removed);
            kcp.nsnd_buf -= 1;
            return;
        }
        if (diff > 0) {
            left = mid + 1;
        } else {
            right = mid;
        }
    }
}

//---------------------------------------------------------------------
// parse una
//---------------------------------------------------------------------
pub fn parseUna(kcp: *Kcp, una: u32) void {
    var remove_count: usize = 0;
    while (remove_count < kcp.snd_buf.items.len) {
        const seg = &kcp.snd_buf.items[remove_count];
        if (utils.itimediff(una, seg.sn) > 0) {
            remove_count += 1;
        } else {
            break;
        }
    }

    if (remove_count == 0) {
        return;
    }

    // Recycle segments without unnecessary initialization
    for (kcp.snd_buf.items[0..remove_count]) |seg_value| {
        kcp.recycleSegment(seg_value);
    }
    kcp.snd_buf.replaceRangeAssumeCapacity(0, remove_count, &.{});
    kcp.nsnd_buf -= @as(u32, @intCast(remove_count));
}

//---------------------------------------------------------------------
// parse fast ack
//---------------------------------------------------------------------
pub fn parseFastack(kcp: *Kcp, sn: u32, ts: u32) void {
    if (utils.itimediff(sn, kcp.snd_una) < 0 or utils.itimediff(sn, kcp.snd_nxt) >= 0) {
        return;
    }

    // Binary search to find upper bound (first segment with sn >= target)
    var left: usize = 0;
    var right: usize = kcp.snd_buf.items.len;

    while (left < right) {
        const mid = left + (right - left) / 2;
        const seg = &kcp.snd_buf.items[mid];
        if (utils.itimediff(sn, seg.sn) > 0) {
            left = mid + 1;
        } else {
            right = mid;
        }
    }

    // Update fastack for all segments before the found position
    for (kcp.snd_buf.items[0..left]) |*seg| {
        if (sn != seg.sn and utils.itimediff(ts, seg.ts) >= 0) {
            seg.fastack += 1;
        }
    }
}

//---------------------------------------------------------------------
// ack push
//---------------------------------------------------------------------
pub fn ackPush(kcp: *Kcp, sn: u32, ts: u32) !void {
    if (kcp.acklist.items.len == kcp.acklist.capacity) {
        const minimal = kcp.acklist.items.len + 1;
        var desired = if (kcp.acklist.capacity == 0) minimal + 7 else kcp.acklist.capacity * 2;
        if (desired < minimal) {
            desired = minimal;
        }
        try kcp.acklist.ensureTotalCapacity(kcp.allocator, desired);
    }
    kcp.acklist.appendAssumeCapacity(.{ .sn = sn, .ts = ts });
}

//---------------------------------------------------------------------
// window unused
//---------------------------------------------------------------------
pub fn wndUnused(kcp: *const Kcp) u32 {
    if (kcp.nrcv_que < kcp.rcv_wnd) {
        return kcp.rcv_wnd - kcp.nrcv_que;
    }
    return 0;
}
