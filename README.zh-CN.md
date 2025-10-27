# KCP - Zig 实现

[English](README.md) | 简体中文

这是 KCP 协议的 Zig 语言实现，基于 skywind3000 的原始 C 实现。

## 简介

KCP 是一个快速可靠的 ARQ 协议，相比 TCP 具有以下特点：

- 平均 RTT 降低 30%-40%
- 最大 RTT 降低三倍
- 轻量级，模块化实现

## 特性

- ✅ 完整的 ARQ 协议实现
- ✅ 快速重传机制
- ✅ 拥塞控制
- ✅ 窗口管理
- ✅ RTT 计算
- ✅ 内存安全（Zig 特性）
- ✅ 无 unsafe 代码
- ✅ 59 个单元测试（100% API 覆盖）
- ✅ 性能基准测试

## 快速开始

### 安装

```bash
# 克隆仓库
git clone https://github.com/yourusername/zig-kcp.git
cd zig-kcp

# 运行测试
zig build test

# 运行性能测试
zig build bench
```

### 基本使用

```zig
const std = @import("std");
const kcp = @import("kcp");

// 1. 定义输出回调函数（用于发送底层数据包）
fn outputCallback(buf: []const u8, k: *kcp.Kcp, user: ?*anyopaque) !i32 {
    // 通过 UDP socket 发送数据
    // 这里只是示例
    return @as(i32, @intCast(buf.len));
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // 2. 创建 KCP 实例
    const conv: u32 = 0x12345678; // 会话 ID，通信双方必须相同
    const kcp_inst = try kcp.create(allocator, conv, null);
    defer kcp.release(kcp_inst);

    // 3. 设置输出回调
    kcp.setOutput(kcp_inst, &outputCallback);

    // 4. 配置 KCP（可选）
    // 参数: nodelay, interval, resend, nc
    // 标准模式: setNodelay(0, 40, 0, 0)
    // 快速模式: setNodelay(1, 10, 2, 1)
    kcp.setNodelay(kcp_inst, 1, 10, 2, 1);

    // 5. 发送数据
    const message = "Hello, KCP!";
    _ = try kcp.send(kcp_inst, message);

    // 6. 定期更新（例如每 10ms）
    const current = @as(u32, @intCast(std.time.milliTimestamp()));
    try kcp.update(kcp_inst, current);

    // 7. 接收底层数据包时调用 input
    // const data = ...; // 从 UDP socket 接收的数据
    // _ = try kcp.input(kcp_inst, data);

    // 8. 读取接收到的数据
    var buffer: [1024]u8 = undefined;
    const len = try kcp.recv(kcp_inst, &buffer);
    if (len > 0) {
        std.debug.print("Received: {s}\n", .{buffer[0..@as(usize, @intCast(len))]});
    }
}
```

## API 文档

### 创建和销毁

#### `create(allocator, conv, user)`

创建 KCP 实例

- `allocator`: 内存分配器
- `conv`: 会话 ID（conversation），通信双方必须相同
- `user`: 用户自定义数据指针（可选）

#### `release(kcp)`

释放 KCP 实例及其占用的资源

### 配置函数

#### `setOutput(kcp, callback)`

设置输出回调函数，KCP 会通过此函数发送底层数据包

```zig
fn callback(buf: []const u8, kcp: *Kcp, user: ?*anyopaque) !i32
```

#### `setNodelay(kcp, nodelay, interval, resend, nc)`

配置 KCP 工作模式

- `nodelay`: 0=禁用(默认), 1=启用
- `interval`: 内部更新间隔（毫秒），默认 100ms
- `resend`: 快速重传触发次数，0=禁用(默认)
- `nc`: 0=正常拥塞控制(默认), 1=禁用拥塞控制

**推荐配置：**

- 普通模式：`setNodelay(0, 40, 0, 0)`
- 快速模式：`setNodelay(1, 20, 2, 1)`
- 极速模式：`setNodelay(1, 10, 2, 1)`

#### `setMtu(kcp, mtu)`

设置 MTU 大小，默认 1400 字节

#### `wndsize(kcp, sndwnd, rcvwnd)`

设置发送窗口和接收窗口大小

- `sndwnd`: 发送窗口，默认 32
- `rcvwnd`: 接收窗口，默认 128

### 数据收发

#### `send(kcp, buffer)`

发送数据

- 返回值：成功返回发送的字节数，失败返回负数

#### `recv(kcp, buffer)`

接收数据

- 返回值：成功返回接收的字节数，失败返回负数
  - `-1`: 接收队列为空
  - `-2`: 数据包不完整
  - `-3`: 缓冲区太小

#### `input(kcp, data)`

将底层数据包输入 KCP（例如从 UDP 接收到的数据）

### 更新和检查

#### `update(kcp, current)`

更新 KCP 状态，需要定期调用（建议 10-100ms）

- `current`: 当前时间戳（毫秒）

#### `check(kcp, current)`

检查下次应该调用 update 的时间

- 返回值：下次 update 的时间戳（毫秒）

### 其他

#### `flush(kcp)`

立即刷新待发送的数据

#### `peeksize(kcp)`

查看接收队列中下一个消息的大小

#### `waitsnd(kcp)`

获取等待发送的数据包数量

#### `getconv(data)`

从数据包中提取会话 ID

## 构建和测试

```bash
# 运行单元测试
zig build test

# 运行性能基准测试
zig build bench

# 查看测试详情
zig build test --summary all
```

## 工作原理

KCP 是一个 ARQ（自动重传请求）协议，工作在应用层，需要配合 UDP 等不可靠传输协议使用。

### 基本流程

1. **发送端：**
   - 调用 `send()` 将数据放入发送队列
   - 调用 `update()` 触发 KCP 处理
   - KCP 通过 output 回调发送数据包

2. **接收端：**
   - 从 UDP 收到数据包后调用 `input()`
   - 调用 `recv()` 读取已重组的数据

3. **定时器：**
   - 定期调用 `update()` 处理超时重传、ACK 等

### 协议头格式（24 字节）

```
0               4       5       6       8       12      16      20      24
+---------------+-------+-------+-------+-------+-------+-------+-------+
|     conv      |  cmd  |  frg  |  wnd  |   ts  |   sn  |  una  |  len  |
+---------------+-------+-------+-------+-------+-------+-------+-------+
```

- `conv`: 会话 ID (4 bytes)
- `cmd`: 命令类型 (1 byte): PUSH, ACK, WASK, WINS
- `frg`: 分片编号 (1 byte)
- `wnd`: 窗口大小 (2 bytes)
- `ts`: 时间戳 (4 bytes)
- `sn`: 序列号 (4 bytes)
- `una`: 未确认序列号 (4 bytes)
- `len`: 数据长度 (4 bytes)

## 性能优化建议

1. **减少延迟：**
   - 使用 `setNodelay(1, 10, 2, 1)` 配置
   - 减小 `interval` 参数
   - 启用快速重传

2. **提高吞吐量：**
   - 增大发送/接收窗口
   - 增大 MTU（如果网络支持）
   - 禁用拥塞控制（在可控网络环境）

3. **降低 CPU 使用：**
   - 适当增大 `interval` 参数
   - 使用 `check()` 优化 `update()` 调用频率

## 测试覆盖

- ✅ 59 个单元测试
- ✅ 100% API 覆盖
- ✅ 模糊测试（随机输入、畸形包）
- ✅ 压力测试（大数据、多包）
- ✅ 边界测试（极值、回绕）
- ✅ 性能基准测试

## 与原版 C 实现的区别

1. **内存管理：**
   - 使用 Zig 的 Allocator 进行内存管理
   - 所有资源通过 defer 自动管理

2. **数据结构：**
   - 使用 `ArrayList` 替代 C 的链表
   - 更简洁的内存布局

3. **类型安全：**
   - 强类型系统，避免类型转换错误
   - 编译时检查溢出

4. **错误处理：**
   - 使用 Zig 的错误联合类型
   - 明确的错误传播

5. **模块化：**
   - 代码分为多个模块（types, utils, codec, control, protocol）
   - 更清晰的代码组织

## 许可证

本实现基于 skywind3000 的原始 KCP 协议实现。

## 参考资料

- [KCP 原始仓库](https://github.com/skywind3000/kcp)
