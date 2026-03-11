# Orchard

Orchard 是一套从零重写的个人分布式 AI 工作集群骨架，目标是用一套苹果原生栈把下面 3 个角色连起来：

- `OrchardControlPlane`：中央控制面，负责设备注册、心跳、任务分发、日志聚合、停止任务。
- `OrchardAgent`：跑在每台 Mac 上的守护进程，负责上报状态、领取任务、执行 shell / Codex 类任务。
- `OrchardCompanionApp`：SwiftUI 原生控制端，可在 iPhone 或 Mac 上查看设备、任务和下发命令。

## 技术选型

- 服务端：Swift + Vapor
- Agent：Swift CLI + `launchd`
- 控制端：SwiftUI
- 共享协议：`OrchardCore`

这样做的好处是：

- 任务协议只维护一份
- iPhone / Mac UI 和 Agent 共享模型
- 以后要做 push、WebSocket、CloudKit 或苹果系统集成时不需要换栈

## 当前初始化状态

- 设备注册
- 周期心跳
- 创建任务
- 控制端查看设备 / 任务快照

## 目录结构

```text
Orchard/
  Package.swift
  Sources/
    OrchardCore/
    OrchardControlPlane/
    OrchardAgent/
    OrchardCompanionApp/
  deploy/
    com.owen.orchard.agent.plist.template
```

## 本地运行

### 1. 启动控制面

```bash
cd Orchard
swift run OrchardControlPlane
```

默认监听：

- `http://127.0.0.1:8080`

### 2. 启动一台 Agent

```bash
cd Orchard
ORCHARD_SERVER_URL=http://127.0.0.1:8080 \
swift run OrchardAgent
```

### 3. 打开原生控制端

```bash
cd Orchard
open .
```

然后用 Xcode 打开包目录，运行 `OrchardCompanionApp` target。

## launchd

模板在：

- `deploy/com.owen.orchard.agent.plist.template`

后续可以把 `OrchardAgent` 构建产物安装成用户级 LaunchAgent。

## 下一步建议

- 加 WebSocket，把日志和任务状态改成实时推送
- 把任务执行环境切到独立 workspace / git clone
- 引入 SQLite 或 Postgres 持久化
- 给 Agent 增加工具权限与沙盒策略
