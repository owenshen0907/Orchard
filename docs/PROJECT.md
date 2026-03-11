# Orchard 项目说明

## 目标

Orchard 是新的起点项目，一期只服务苹果生态：

- 电脑端：macOS Agent
- 手机端：iPhone 原生控制端
- 服务器端：先用 Swift + Vapor，后续可替换为任意更适合的后端实现

这意味着当前初始化版本优先保证：

- 项目边界清晰
- 模型统一
- 目录干净
- 可以直接继续迭代

## 一期边界

一期先只做下面这些能力：

1. 中央控制面启动与基础 API
2. macOS Agent 注册与心跳
3. iPhone / Mac Companion 读取快照
4. 基础任务模型和创建接口

明确不在初始化阶段做：

- 多设备调度策略
- 任务隔离与沙盒
- WebSocket 实时日志
- 复杂权限系统
- 数据库存储
- Docker / GPU 调度

## 当前骨架

### `OrchardCore`

共享模型层，供服务端、Agent、控制端同时使用：

- 设备模型
- 任务模型
- 快照模型
- HTTP client
- JSON 编解码策略

### `OrchardControlPlane`

基础控制面服务，目前包含：

- `GET /health`
- `GET /api/snapshot`
- `GET /api/devices`
- `POST /api/devices/register`
- `POST /api/devices/:deviceID/heartbeat`
- `GET /api/tasks`
- `POST /api/tasks`

当前状态先存在内存里，目的是先稳定协议和边界。

### `OrchardAgent`

基础守护进程入口：

- 读取环境变量
- 注册设备
- 每 10 秒发送一次心跳
- 上报简单设备负载指标

### `OrchardCompanionApp`

SwiftUI 原生控制端骨架：

- 配置服务地址
- 拉取快照
- 展示设备和任务

## 环境变量

### Control Plane

- `ORCHARD_BIND`
- `ORCHARD_PORT`

### Agent

- `ORCHARD_SERVER_URL`
- `ORCHARD_WORK_ROOT`
- `ORCHARD_DEVICE_NAME`
- `ORCHARD_DEVICE_ID`

## 后续推荐拆分

下一轮建议优先做：

1. 任务领取与执行
2. 停止任务
3. 任务日志
4. 持久化
5. launchd 安装脚本
