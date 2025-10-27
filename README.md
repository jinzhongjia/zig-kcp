# KCP - A Fast and Reliable ARQ Protocol (Zig Implementation)

English | [简体中文](README.zh-CN.md)

A Zig implementation of the KCP protocol, based on the original C implementation by skywind3000.

## Introduction

KCP is a fast and reliable ARQ (Automatic Repeat reQuest) protocol that offers significant advantages over TCP:

- 30-40% average RTT reduction compared to TCP
- 3x reduction in maximum RTT
- Lightweight, modular implementation

## Features

- ✅ Complete ARQ protocol implementation
- ✅ Fast retransmission mechanism
- ✅ Congestion control
- ✅ Window management
- ✅ RTT calculation
- ✅ Memory safety (Zig feature)
- ✅ No unsafe code
- ✅ 59 unit tests (100% API coverage)
- ✅ Performance benchmarks

## Quick Start

### Installation

```bash
# Clone the repository
git clone https://github.com/yourusername/zig-kcp.git
cd zig-kcp

# Run tests
zig build test

# Run benchmarks
zig build bench
```

### Basic Usage

```zig
const std = @import("std");
const kcp = @import("kcp");

// 1. Define output callback function (for sending underlying packets)
fn outputCallback(buf: []const u8, k: *kcp.Kcp, user: ?*anyopaque) !i32 {
    // Send data via UDP socket
    // This is just an example
    return @as(i32, @intCast(buf.len));
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // 2. Create KCP instance
    const conv: u32 = 0x12345678; // Conversation ID, must be same for both peers
    const kcp_inst = try kcp.create(allocator, conv, null);
    defer kcp.release(kcp_inst);

    // 3. Set output callback
    kcp.setOutput(kcp_inst, &outputCallback);

    // 4. Configure KCP (optional)
    // Parameters: nodelay, interval, resend, nc
    // Normal mode: setNodelay(0, 40, 0, 0)
    // Fast mode: setNodelay(1, 10, 2, 1)
    kcp.setNodelay(kcp_inst, 1, 10, 2, 1);

    // 5. Send data
    const message = "Hello, KCP!";
    _ = try kcp.send(kcp_inst, message);

    // 6. Update periodically (e.g., every 10ms)
    const current = @as(u32, @intCast(std.time.milliTimestamp()));
    try kcp.update(kcp_inst, current);

    // 7. Call input when receiving underlying packets
    // const data = ...; // Data received from UDP socket
    // _ = try kcp.input(kcp_inst, data);

    // 8. Read received data
    var buffer: [1024]u8 = undefined;
    const len = try kcp.recv(kcp_inst, &buffer);
    if (len > 0) {
        std.debug.print("Received: {s}\n", .{buffer[0..@as(usize, @intCast(len))]});
    }
}
```

## API Documentation

### Creation and Destruction

#### `create(allocator, conv, user)`

Create a KCP instance

- `allocator`: Memory allocator
- `conv`: Conversation ID, must be the same for both communicating peers
- `user`: User-defined data pointer (optional)

#### `release(kcp)`

Release the KCP instance and its resources

### Configuration Functions

#### `setOutput(kcp, callback)`

Set the output callback function, which KCP uses to send underlying packets

```zig
fn callback(buf: []const u8, kcp: *Kcp, user: ?*anyopaque) !i32
```

#### `setNodelay(kcp, nodelay, interval, resend, nc)`

Configure KCP working mode

- `nodelay`: 0=disabled (default), 1=enabled
- `interval`: Internal update interval (milliseconds), default 100ms
- `resend`: Fast retransmission trigger count, 0=disabled (default)
- `nc`: 0=normal congestion control (default), 1=disable congestion control

**Recommended configurations:**

- Normal mode: `setNodelay(0, 40, 0, 0)`
- Fast mode: `setNodelay(1, 20, 2, 1)`
- Turbo mode: `setNodelay(1, 10, 2, 1)`

#### `setMtu(kcp, mtu)`

Set MTU size, default 1400 bytes

#### `wndsize(kcp, sndwnd, rcvwnd)`

Set send and receive window sizes

- `sndwnd`: Send window, default 32
- `rcvwnd`: Receive window, default 128

### Data Transfer

#### `send(kcp, buffer)`

Send data

- Return value: Returns the number of bytes sent on success, negative on error

#### `recv(kcp, buffer)`

Receive data

- Return value: Returns the number of bytes received on success, negative on error
  - `-1`: Receive queue is empty
  - `-2`: Incomplete packet
  - `-3`: Buffer too small

#### `input(kcp, data)`

Input underlying packet data into KCP (e.g., data received from UDP)

### Update and Check

#### `update(kcp, current)`

Update KCP state, should be called periodically (recommended: 10-100ms)

- `current`: Current timestamp (milliseconds)

#### `check(kcp, current)`

Check when to call update next

- Return value: Timestamp for the next update (milliseconds)

### Other Functions

#### `flush(kcp)`

Immediately flush pending data

#### `peeksize(kcp)`

Get the size of the next message in the receive queue

#### `waitsnd(kcp)`

Get the number of packets waiting to be sent

#### `getconv(data)`

Extract conversation ID from a packet

## Build and Test

```bash
# Run unit tests
zig build test

# Run performance benchmarks
zig build bench

# View detailed test output
zig build test --summary all
```

## How It Works

KCP is an ARQ (Automatic Repeat reQuest) protocol operating at the application layer, designed to work with unreliable transport protocols like UDP.

### Basic Flow

1. **Sender:**
   - Call `send()` to queue data
   - Call `update()` to trigger KCP processing
   - KCP sends packets via the output callback

2. **Receiver:**
   - Call `input()` when receiving packets from UDP
   - Call `recv()` to read reassembled data

3. **Timer:**
   - Periodically call `update()` to handle retransmissions, ACKs, etc.

### Protocol Header (24 bytes)

```
0               4       5       6       8       12      16      20      24
+---------------+-------+-------+-------+-------+-------+-------+-------+
|     conv      |  cmd  |  frg  |  wnd  |   ts  |   sn  |  una  |  len  |
+---------------+-------+-------+-------+-------+-------+-------+-------+
```

- `conv`: Conversation ID (4 bytes)
- `cmd`: Command type (1 byte): PUSH, ACK, WASK, WINS
- `frg`: Fragment number (1 byte)
- `wnd`: Window size (2 bytes)
- `ts`: Timestamp (4 bytes)
- `sn`: Sequence number (4 bytes)
- `una`: Unacknowledged sequence number (4 bytes)
- `len`: Data length (4 bytes)

## Performance Tuning

1. **Reduce latency:**
   - Use `setNodelay(1, 10, 2, 1)` configuration
   - Decrease `interval` parameter
   - Enable fast retransmission

2. **Increase throughput:**
   - Increase send/receive window sizes
   - Increase MTU (if network supports)
   - Disable congestion control (in controlled network environments)

3. **Reduce CPU usage:**
   - Increase `interval` parameter appropriately
   - Use `check()` to optimize `update()` call frequency

## Test Coverage

- ✅ 59 unit tests
- ✅ 100% API coverage
- ✅ Fuzz testing (random input, malformed packets)
- ✅ Stress testing (large data, multiple packets)
- ✅ Boundary testing (edge values, wraparound)
- ✅ Performance benchmarks

### Test Categories

| Category           | Count | Coverage                                      |
| ------------------ | ----- | --------------------------------------------- |
| Basic Functions    | 9     | Encode/decode, utilities, create/release      |
| Configuration      | 6     | MTU, window, nodelay, stream mode             |
| Error Handling     | 5     | Invalid conv, corrupted data, buffer issues   |
| ARQ Mechanisms     | 5     | Timeout retransmission, fast retransmission   |
| Fragmentation      | 2     | Large data, multi-fragment reassembly         |
| Advanced Features  | 3     | Window probe, flush, window full              |
| Fuzz Testing       | 3     | Random input, malformed packets, edge values  |
| Stress Testing     | 3     | Many small packets, large data, bidirectional |
| Boundary Testing   | 8     | MTU, window, sequence wraparound              |
| Dead Link          | 2     | Complete loss, gradual retransmission         |
| Receive Window     | 3     | Window full, flow control, zero window        |
| RTT Testing        | 2     | RTT calculation, delay variation              |
| Congestion Control | 2     | ssthresh adjustment, slow start               |
| Timestamp          | 2     | Wraparound, time jump                         |
| Interval           | 3     | Update frequency, flush timing                |
| Nodelay Modes      | 3     | Normal, fast, comparison                      |

## Differences from Original C Implementation

1. **Memory Management:**
   - Uses Zig's Allocator for memory management
   - All resources managed automatically via defer

2. **Data Structures:**
   - Uses `ArrayList` instead of C linked lists
   - Cleaner memory layout

3. **Type Safety:**
   - Strong type system prevents type conversion errors
   - Compile-time overflow checking

4. **Error Handling:**
   - Uses Zig's error union types
   - Explicit error propagation

5. **Modularity:**
   - Code split into multiple modules (types, utils, codec, control, protocol)
   - Clearer code organization

## License

This implementation is based on the original KCP protocol by skywind3000.

## References

- [Original KCP Repository](https://github.com/skywind3000/kcp)
