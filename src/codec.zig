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
pub fn encode8u(buf: []u8, offset: usize, c: u8) usize {
    buf[offset] = c;
    return offset + 1;
}

pub fn decode8u(buf: []const u8, offset: usize) struct { value: u8, offset: usize } {
    return .{
        .value = buf[offset],
        .offset = offset + 1,
    };
}

pub fn encode16u(buf: []u8, offset: usize, w: u16) usize {
    buf[offset] = @as(u8, @truncate(w & 0xff));
    buf[offset + 1] = @as(u8, @truncate((w >> 8) & 0xff));
    return offset + 2;
}

pub fn decode16u(buf: []const u8, offset: usize) struct { value: u16, offset: usize } {
    const w = @as(u16, buf[offset]) | (@as(u16, buf[offset + 1]) << 8);
    return .{
        .value = w,
        .offset = offset + 2,
    };
}

pub fn encode32u(buf: []u8, offset: usize, l: u32) usize {
    buf[offset] = @as(u8, @truncate((l >> 0) & 0xff));
    buf[offset + 1] = @as(u8, @truncate((l >> 8) & 0xff));
    buf[offset + 2] = @as(u8, @truncate((l >> 16) & 0xff));
    buf[offset + 3] = @as(u8, @truncate((l >> 24) & 0xff));
    return offset + 4;
}

pub fn decode32u(buf: []const u8, offset: usize) struct { value: u32, offset: usize } {
    const l = @as(u32, buf[offset]) |
        (@as(u32, buf[offset + 1]) << 8) |
        (@as(u32, buf[offset + 2]) << 16) |
        (@as(u32, buf[offset + 3]) << 24);
    return .{
        .value = l,
        .offset = offset + 4,
    };
}

//---------------------------------------------------------------------
// encode segment header
//---------------------------------------------------------------------
pub fn encodeSegment(seg: *const Segment, buf: []u8, offset: usize) usize {
    var pos = offset;
    pos = encode32u(buf, pos, seg.conv);
    pos = encode8u(buf, pos, @as(u8, @truncate(seg.cmd)));
    pos = encode8u(buf, pos, @as(u8, @truncate(seg.frg)));
    pos = encode16u(buf, pos, @as(u16, @truncate(seg.wnd)));
    pos = encode32u(buf, pos, seg.ts);
    pos = encode32u(buf, pos, seg.sn);
    pos = encode32u(buf, pos, seg.una);
    pos = encode32u(buf, pos, @as(u32, @truncate(seg.data.items.len)));
    return pos;
}

//---------------------------------------------------------------------
// read conv from data
//---------------------------------------------------------------------
pub fn getconv(data: []const u8) !u32 {
    if (data.len < 4) {
        return error.InvalidData;
    }
    const result = decode32u(data, 0);
    return result.value;
}
