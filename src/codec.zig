//=====================================================================
//
// codec.zig - Encoding and Decoding Functions
//
//=====================================================================

const types = @import("types.zig");
const Segment = types.Segment;

//=====================================================================
// ENCODE / DECODE
//=====================================================================
pub fn encode8u(buf: []u8, offset: *usize, c: u8) void {
    buf[offset.*] = c;
    offset.* += 1;
}

pub fn decode8u(buf: []const u8, offset: *usize) u8 {
    const c = buf[offset.*];
    offset.* += 1;
    return c;
}

pub fn encode16u(buf: []u8, offset: *usize, w: u16) void {
    buf[offset.*] = @as(u8, @truncate(w & 0xff));
    buf[offset.* + 1] = @as(u8, @truncate((w >> 8) & 0xff));
    offset.* += 2;
}

pub fn decode16u(buf: []const u8, offset: *usize) u16 {
    const w = @as(u16, buf[offset.*]) | (@as(u16, buf[offset.* + 1]) << 8);
    offset.* += 2;
    return w;
}

pub fn encode32u(buf: []u8, offset: *usize, l: u32) void {
    buf[offset.*] = @as(u8, @truncate((l >> 0) & 0xff));
    buf[offset.* + 1] = @as(u8, @truncate((l >> 8) & 0xff));
    buf[offset.* + 2] = @as(u8, @truncate((l >> 16) & 0xff));
    buf[offset.* + 3] = @as(u8, @truncate((l >> 24) & 0xff));
    offset.* += 4;
}

pub fn decode32u(buf: []const u8, offset: *usize) u32 {
    const l = @as(u32, buf[offset.*]) |
        (@as(u32, buf[offset.* + 1]) << 8) |
        (@as(u32, buf[offset.* + 2]) << 16) |
        (@as(u32, buf[offset.* + 3]) << 24);
    offset.* += 4;
    return l;
}

//---------------------------------------------------------------------
// encode segment header
//---------------------------------------------------------------------
pub fn encodeSegment(seg: *const Segment, buf: []u8, offset: *usize) void {
    encode32u(buf, offset, seg.conv);
    encode8u(buf, offset, @as(u8, @truncate(seg.cmd)));
    encode8u(buf, offset, @as(u8, @truncate(seg.frg)));
    encode16u(buf, offset, @as(u16, @truncate(seg.wnd)));
    encode32u(buf, offset, seg.ts);
    encode32u(buf, offset, seg.sn);
    encode32u(buf, offset, seg.una);
    encode32u(buf, offset, @as(u32, @truncate(seg.data.items.len)));
}

//---------------------------------------------------------------------
// read conv from data
//---------------------------------------------------------------------
pub fn getconv(data: []const u8) !u32 {
    if (data.len < 4) {
        return error.InvalidData;
    }
    var offset: usize = 0;
    return decode32u(data, &offset);
}
