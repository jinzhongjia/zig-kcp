//=====================================================================
//
// segment.zig - Segment Operations
//
//=====================================================================

const std = @import("std");
const types = @import("types.zig");
const codec = @import("codec.zig");
const Segment = types.Segment;
const Kcp = types.Kcp;

//---------------------------------------------------------------------
// segment encode wrapper
//---------------------------------------------------------------------
pub fn encode(seg: *const Segment, buf: []u8, offset: usize) usize {
    return codec.encodeSegment(seg, buf, offset);
}
