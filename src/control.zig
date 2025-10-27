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

    for (0..kcp.snd_buf.items.len) |idx| {
        const seg = &kcp.snd_buf.items[idx];
        if (sn == seg.sn) {
            var removed = kcp.snd_buf.orderedRemove(idx);
            removed.deinit(kcp.allocator);
            kcp.nsnd_buf -= 1;
            break;
        }
        if (utils.itimediff(sn, seg.sn) < 0) {
            break;
        }
    }
}

//---------------------------------------------------------------------
// parse una
//---------------------------------------------------------------------
pub fn parseUna(kcp: *Kcp, una: u32) void {
    while (kcp.snd_buf.items.len > 0) {
        const seg = &kcp.snd_buf.items[0];
        if (utils.itimediff(una, seg.sn) > 0) {
            var removed = kcp.snd_buf.orderedRemove(0);
            removed.deinit(kcp.allocator);
            kcp.nsnd_buf -= 1;
        } else {
            break;
        }
    }
}

//---------------------------------------------------------------------
// parse fast ack
//---------------------------------------------------------------------
pub fn parseFastack(kcp: *Kcp, sn: u32, ts: u32) void {
    if (utils.itimediff(sn, kcp.snd_una) < 0 or utils.itimediff(sn, kcp.snd_nxt) >= 0) {
        return;
    }

    for (kcp.snd_buf.items) |*seg| {
        if (utils.itimediff(sn, seg.sn) < 0) {
            break;
        } else if (sn != seg.sn) {
            if (utils.itimediff(ts, seg.ts) >= 0) {
                seg.fastack += 1;
            }
        }
    }
}

//---------------------------------------------------------------------
// ack push
//---------------------------------------------------------------------
pub fn ackPush(kcp: *Kcp, sn: u32, ts: u32) !void {
    try kcp.acklist.append(kcp.allocator, sn);
    try kcp.acklist.append(kcp.allocator, ts);
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
