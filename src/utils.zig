//=====================================================================
//
// utils.zig - Utility Functions
//
//=====================================================================

//=====================================================================
// UTILITY FUNCTIONS
//=====================================================================
pub inline fn imin(a: u32, b: u32) u32 {
    return if (a <= b) a else b;
}

pub inline fn imax(a: u32, b: u32) u32 {
    return if (a >= b) a else b;
}

pub inline fn ibound(lower: u32, middle: u32, upper: u32) u32 {
    return imin(imax(lower, middle), upper);
}

pub inline fn itimediff(later: u32, earlier: u32) i32 {
    return @as(i32, @bitCast(later -% earlier));
}
