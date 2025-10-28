# KCP UDP Examples

These examples demonstrate how to use the KCP protocol with real UDP network transport.

## Files

- **udp_server.zig** - Multi-user KCP chat room server
- **udp_client.zig** - Interactive KCP chat room client (multi-threaded)

## Quick Start

### 1. Run the Server

Start the chat room server in one terminal window (default port 9999):

```bash
zig build server
```

Or specify a port:

```bash
zig build server -- 8888
```

The server will:
- Listen on all network interfaces
- Accept multiple simultaneous clients
- Automatically assign usernames (User1, User2, etc.)
- Broadcast messages to all connected clients
- Handle user commands

### 2. Run Multiple Clients

Start the interactive chat client in **multiple** terminal windows:

**Terminal 1 (Client A):**
```bash
zig build client
```

**Terminal 2 (Client B):**
```bash
zig build client
```

**Terminal 3 (Client C):**
```bash
zig build client -- 127.0.0.1 9999
```

### 3. Chat Room Features

The chat room supports:

**Automatic Username Assignment:**
```
=== KCP Chat Room Client ===
Commands:
  /list        - List all online users
  /rename NAME - Change your username
  /quit        - Disconnect from chat

Connecting to server...

>
── Welcome to the chat room! You are User1 ──
```

**Multi-User Communication:**
```
> Hello everyone!
You: Hello everyone!
[User2] Hi there!
[User3] Welcome!
```

**User Join/Leave Notifications:**
```
── User4 joined the chat ──
── User2 disconnected (timeout) ──
```

**Available Commands:**

1. **`/list`** - List all online users
   ```
   > /list
   ── Online users ──
     User1 (you)
     User2
     User3
   ```

2. **`/rename <newname>`** - Change your username
   ```
   > /rename Alice
   ── User1 is now known as Alice ──

   [Bob] Nice name!
   ```

3. **`/quit`** - Disconnect from chat room
   ```
   > /quit
   Goodbye!
   ```

### 4. Server Features

The server provides:
- **Multi-client support**: Each client gets its own KCP instance
- **Username validation**: Names must be 1-20 characters and unique
- **Message broadcasting**: Messages are forwarded to all other clients
- **System notifications**: Join/leave/rename events notify all users
- **Command processing**: Handles `/rename` and `/list` commands
- **Per-client KCP state**: Independent reliable transmission for each user
- **Heartbeat mechanism**: Client sends heartbeat every 200ms
- **Auto-disconnect**: Clients timeout after 600ms (3 missed heartbeats)

## Building Executables

To generate standalone executables without running them:

```bash
zig build
```

The compiled files will be in the `zig-out/bin/` directory:

```bash
./zig-out/bin/udp_server 9999
./zig-out/bin/udp_client 127.0.0.1 9999
```

## Architecture

### Multi-Client Server Design

The chat room server manages multiple clients simultaneously:

```
┌──────────────────────────────────────────────────────────┐
│                    Chat Room Server                       │
│                                                            │
│  ┌─────────────────────────────────────────────────────┐ │
│  │         AutoHashMap<u64, *Client>                   │ │
│  │  (Key: Address Hash, Value: Client Info)            │ │
│  └─────────────────────────────────────────────────────┘ │
│                                                            │
│  Each Client contains:                                    │
│    - KCP instance (independent state machine)            │
│    - Username (User1, User2, or custom)                  │
│    - Network address (IP + port)                         │
│    - Last activity timestamp                             │
│                                                            │
│  Main Loop:                                               │
│    1. Update all KCP instances                           │
│    2. Receive UDP packets (non-blocking)                 │
│    3. Route to appropriate client's KCP                  │
│    4. Process application messages                       │
│    5. Handle commands (/rename, /list)                   │
│    6. Broadcast to other clients                         │
└──────────────────────────────────────────────────────────┘
         ↓              ↓              ↓
    [Client 1]     [Client 2]     [Client 3]
```

**Key Design Points:**
- **One KCP per client**: Each connection maintains independent reliable state
- **Address-based routing**: UDP packets routed to correct KCP instance by source address
- **Broadcast mechanism**: Messages forwarded to all clients except sender
- **Command processing**: Server interprets special `/` commands
- **Auto username**: Sequential IDs assigned on first connection
- **Instant connection**: Client sends `__INIT__` packet on connect, triggers immediate notification
- **Active monitoring**: Server checks client activity every 100ms
- **Fast timeout**: Clients disconnected after 600ms of inactivity (3 missed heartbeats @ 200ms)

### Multi-threaded Client Design

The interactive chat client uses a multi-threaded architecture to handle concurrent I/O:

```
┌─────────────────┐              ┌─────────────────┐
│  Input Thread   │              │   Main Thread   │
│                 │              │                 │
│  stdin (block)  │              │  UDP (nonblock) │
│      ↓          │              │      ↓          │
│  Read line      │              │  recvfrom()     │
│      ↓          │   Message    │      ↓          │
│  Push to Queue ─┼──────────────┼→ kcp.input()    │
│                 │    Queue     │      ↓          │
└─────────────────┘   (Mutex)    │  kcp.recv()     │
                                 │      ↓          │
                     ┌───────────┼─ Pop from Queue │
                     │           │      ↓          │
                     │           │  kcp.send()     │
                     │           │      ↓          │
                     │           │  kcp.update()   │
                     │           │                 │
                     │           └─────────────────┘
                     │
                Display to user
```

**Key Components:**
- **MessageQueue**: Thread-safe queue using `std.Thread.Mutex`
- **Input Thread**: Blocks on stdin, pushes messages to queue
- **Main Thread**: Non-blocking UDP I/O, KCP updates, message sending
- **Atomic Flag**: Coordinates graceful shutdown between threads

### KCP and UDP Integration

KCP is an application-layer protocol that requires an underlying transport layer (like UDP) to transmit packets. The integration architecture is:

```
Application Data
    ↓
KCP Protocol Layer (kcp.send/recv)
    ↓
KCP Output Callback
    ↓
UDP Socket (sendto/recvfrom)
    ↓
Network
```

### Key Components

#### 1. Output Callback Function

KCP sends data to UDP through the output callback:

```zig
fn kcpOutput(buf: []const u8, k: *kcp.Kcp, user: ?*anyopaque) !i32 {
    const ctx = @as(*UdpContext, @ptrCast(@alignCast(user.?)));
    const sent = try posix.sendto(
        ctx.socket,
        buf,
        0,
        &ctx.peer_addr,
        ctx.peer_len,
    );
    return @intCast(sent);
}
```

#### 2. UDP Receive and KCP Input

Received UDP data must be fed into KCP for processing:

```zig
// Receive from UDP
const received = try posix.recvfrom(socket, &recv_buf, 0, &from, &from_len);

// Feed into KCP
_ = try kcp.input(kcp_inst, recv_buf[0..received]);

// Read application-layer data from KCP
const len = try kcp.recv(kcp_inst, &app_buf);
```

#### 3. State Machine Updates

KCP requires periodic `update()` calls to drive its internal state machine:

```zig
const current = getCurrentMs();
try kcp.update(kcp_inst, current);

// Or use check() to optimize update intervals
const next_update = kcp.check(kcp_inst, current);
```

### KCP Configuration

The examples use fast mode configuration, suitable for low-latency applications:

```zig
// Fast mode: nodelay=1, interval=10ms, resend=2, nc=1
kcp.setNodelay(kcp_inst, 1, 10, 2, 1);

// Set send and receive window sizes
kcp.wndsize(kcp_inst, 128, 128);
```

**Parameter Description:**

- **nodelay**: Enable no-delay mode
  - `0`: Disabled (default)
  - `1`: Enabled
  - `2`: Ultra mode

- **interval**: Internal update interval (milliseconds)
  - Default: 100ms
  - Fast mode: 10ms

- **resend**: Fast retransmit trigger multiplier
  - `0`: Disable fast retransmit
  - `2`: Trigger after 2 ACKs (recommended)

- **nc**: Disable congestion control
  - `0`: Enable congestion control
  - `1`: Disable (ultra mode)

### Conversation ID

Both client and server must use the same conversation ID (`conv`):

```zig
const conv: u32 = 1234;  // Must match on both ends
const kcp_inst = try kcp.create(allocator, conv, user_data);
```

## Error Handling

Common errors and handling:

- **error.NoData**: KCP receive queue is empty, keep waiting
- **error.WouldBlock**: UDP socket has no data to read (non-blocking mode)
- **error.BufferTooSmall**: Provided buffer is too small

## Performance Tips

1. **Update Frequency**: Adjust `update()` call frequency based on application needs
   - Real-time games: 10ms
   - Regular applications: 100ms

2. **Window Size**: Adjust window based on bandwidth and latency
   - Low latency, high bandwidth: Increase window (256+)
   - High latency: Use default (128)

3. **MTU Settings**: Adjust based on network environment
   ```zig
   try kcp.setMtu(kcp_inst, 1400);  // Default
   ```

4. **Mode Selection**:
   - Maximum throughput: Normal mode `(0, 100, 0, 0)`
   - Low latency: Fast mode `(1, 10, 2, 1)`
   - Minimum latency: Ultra mode `(2, 10, 2, 1)`

## Extension Suggestions

The chat room now features multi-client support, interactive chat, and commands. Additional production features may include:

### Already Implemented ✅
1. ✅ **Multi-client Support**: Server maintains multiple KCP instances (one per client)
2. ✅ **Interactive Chat**: Multi-threaded client with real-time input
3. ✅ **User Management**: Automatic username assignment with rename support
4. ✅ **Command System**: `/list` and `/rename` commands
5. ✅ **Notifications**: Join/leave/rename broadcast to all users

### Recommended Next Steps 🚀
1. **Heartbeat Mechanism**: Detect inactive clients and auto-disconnect
2. **Graceful Disconnect**: Handle client disconnections properly (currently clients just disappear)
3. **Reconnection Logic**: Handle network interruptions with automatic reconnect
4. **Private Messages**: Add `/msg <user> <message>` for direct messaging
5. **Chat Rooms**: Support multiple chat rooms with `/join <room>`
6. **Message History**: Save and replay recent messages for new joiners
7. **User Authentication**: Add login/registration system
8. **Encryption**: Add encryption layer on top of KCP
9. **Rate Limiting**: Prevent message spam
10. **Admin Commands**: Add `/kick`, `/ban`, `/mute` for moderation
11. **Logging**: Add detailed debug logging and chat logs
12. **Statistics**: Monitor per-client latency, packet loss rate, etc.

## References

- [KCP Protocol Documentation](https://github.com/skywind3000/kcp)
- [Zig Standard Library - Networking](https://ziglang.org/documentation/master/std/#std.net)
- [Zig Cookbook - UDP](https://cookbook.ziglang.cc/04-03-udp-echo/)
