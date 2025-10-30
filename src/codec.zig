//=====================================================================
//
// codec.zig - Encoding and Decoding Functions
//
//=====================================================================

const std = @import("std");
const types = @import("types.zig");
const Segment = types.Segment;

//=====================================================================
// ENCODE / DECODE
//=====================================================================
pub inline fn encode8u(buf: []u8, offset: usize, c: u8) usize {
    buf[offset] = c;
    return offset + 1;
}

pub inline fn decode8u(buf: []const u8, offset: usize) struct { value: u8, offset: usize } {
    return .{
        .value = buf[offset],
        .offset = offset + 1,
    };
}

pub inline fn encode16u(buf: []u8, offset: usize, w: u16) usize {
    std.mem.writeInt(u16, buf[offset..][0..2], w, .little);
    return offset + 2;
}

pub inline fn decode16u(buf: []const u8, offset: usize) struct { value: u16, offset: usize } {
    return .{
        .value = std.mem.readInt(u16, buf[offset..][0..2], .little),
        .offset = offset + 2,
    };
}

pub inline fn encode32u(buf: []u8, offset: usize, l: u32) usize {
    std.mem.writeInt(u32, buf[offset..][0..4], l, .little);
    return offset + 4;
}

pub inline fn decode32u(buf: []const u8, offset: usize) struct { value: u32, offset: usize } {
    return .{
        .value = std.mem.readInt(u32, buf[offset..][0..4], .little),
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
