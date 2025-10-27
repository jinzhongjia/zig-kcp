//=====================================================================
//
// kcp.zig - Main Entry Point for KCP Protocol
//
// KCP - A Better ARQ Protocol Implementation (Zig Version)
// Based on ikcp.c by skywind3000 (at) gmail.com, 2010-2011
//
// Features:
// + Average RTT reduce 30% - 40% vs traditional ARQ like tcp.
// + Maximum RTT reduce three times vs tcp.
// + Lightweight, modular implementation.
//
//=====================================================================

const std = @import("std");

// Export all modules
pub const types = @import("types.zig");
pub const utils = @import("utils.zig");
pub const codec = @import("codec.zig");
pub const segment = @import("segment.zig");
pub const control = @import("control.zig");
pub const protocol = @import("protocol.zig");

// Export types
pub const Kcp = types.Kcp;
pub const Segment = types.Segment;

// Export constants
pub const RTO_NDL = types.RTO_NDL;
pub const RTO_MIN = types.RTO_MIN;
pub const RTO_DEF = types.RTO_DEF;
pub const RTO_MAX = types.RTO_MAX;
pub const CMD_PUSH = types.CMD_PUSH;
pub const CMD_ACK = types.CMD_ACK;
pub const CMD_WASK = types.CMD_WASK;
pub const CMD_WINS = types.CMD_WINS;
pub const ASK_SEND = types.ASK_SEND;
pub const ASK_TELL = types.ASK_TELL;
pub const WND_SND = types.WND_SND;
pub const WND_RCV = types.WND_RCV;
pub const MTU_DEF = types.MTU_DEF;
pub const ACK_FAST = types.ACK_FAST;
pub const INTERVAL = types.INTERVAL;
pub const OVERHEAD = types.OVERHEAD;
pub const DEADLINK = types.DEADLINK;
pub const THRESH_INIT = types.THRESH_INIT;
pub const THRESH_MIN = types.THRESH_MIN;
pub const PROBE_INIT = types.PROBE_INIT;
pub const PROBE_LIMIT = types.PROBE_LIMIT;
pub const FASTACK_LIMIT = types.FASTACK_LIMIT;
pub const STATE_CONNECTED = types.STATE_CONNECTED;
pub const STATE_DEAD = types.STATE_DEAD;
pub const FASTACK_UNLIMITED = types.FASTACK_UNLIMITED;
pub const TIME_DIFF_LIMIT = types.TIME_DIFF_LIMIT;
pub const MAX_PACKET_TIME = types.MAX_PACKET_TIME;

// Export error types
pub const KcpError = types.KcpError;

// Export main API functions
pub const create = protocol.create;
pub const release = protocol.release;
pub const setOutput = protocol.setOutput;
pub const recv = protocol.recv;
pub const send = protocol.send;
pub const input = protocol.input;
pub const update = protocol.update;
pub const check = protocol.check;
pub const flush = protocol.flush;
pub const peeksize = protocol.peeksize;
pub const setMtu = protocol.setMtu;
pub const wndsize = protocol.wndsize;
pub const waitsnd = protocol.waitsnd;
pub const setNodelay = protocol.setNodelay;

// Export codec functions
pub const getconv = codec.getconv;
pub const encode8u = codec.encode8u;
pub const decode8u = codec.decode8u;
pub const encode16u = codec.encode16u;
pub const decode16u = codec.decode16u;
pub const encode32u = codec.encode32u;
pub const decode32u = codec.decode32u;

// Export utility functions
pub const imin = utils.imin;
pub const imax = utils.imax;
pub const ibound = utils.ibound;
pub const itimediff = utils.itimediff;
