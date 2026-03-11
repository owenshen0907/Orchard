# Orchard

Orchard 是一套从零重写的个人分布式 AI 控制平面，当前一期先把最核心的两部分做实：

- `OrchardControlPlane`：中央控制面，负责设备注册、WebSocket 会话、任务调度、日志聚合、停止任务、SQLite 持久化。
- `OrchardAgent`：跑在每台 Mac 上的用户级守护进程，负责注册、发送 heartbeat、执行 `shell` / `codex` 任务、流式回传日志。

`OrchardCompanionApp` 仍然保留，但一期不作为核心依赖；当前已经支持查看概览 / 设备 / 任务详情，并提供简单任务创建与停止入口。

## 技术选型

- 服务端：Swift + Vapor
- Agent：Swift CLI + `launchd`
- 控制端：SwiftUI
- 共享协议：`OrchardCore`

这样做的好处是：

- 任务协议只维护一份
- iPhone / Mac UI 和 Agent 共享模型
- 以后要做 push、WebSocket、CloudKit 或苹果系统集成时不需要换栈

## 一期能力

- Agent 通过 `POST /api/agents/register` 注册设备和 workspace
- Agent 通过 `GET /api/agents/:deviceID/session` 建立单条 WebSocket 会话
- 控制面支持 `shell` / `codex` typed task
- 任务可按 workspace、capability、preferred device 调度
- 任务日志和状态通过 WebSocket 回传
- `POST /api/tasks/:taskID/stop` 可停止任务
- Control Plane 使用 SQLite 持久化 `devices / device_workspaces / tasks / task_logs`
- `OrchardCompanionApp` 支持概览、设备列表、任务详情、简单任务创建和停止任务

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

### 1. 启动 Control Plane

```bash
cd Orchard
export ORCHARD_ENROLLMENT_TOKEN="replace-me"
swift run OrchardControlPlane
```

默认监听：

- `http://127.0.0.1:8080`

可选环境变量：

- `ORCHARD_BIND`
- `ORCHARD_PORT`
- `ORCHARD_DATA_DIR`
- `ORCHARD_ENROLLMENT_TOKEN`

### 2. 配置一台 Agent

Agent 固定从下面路径读取配置：

- `~/Library/Application Support/Orchard/agent.json`

示例文件见：

- `deploy/agent.example.json`

最小配置示例：

```json
{
  "serverURL": "http://127.0.0.1:8080",
  "enrollmentToken": "replace-me",
  "deviceID": "mac-studio-01",
  "deviceName": "Mac Studio",
  "maxParallelTasks": 2,
  "workspaceRoots": [
    {
      "id": "main",
      "name": "Main Workspace",
      "rootPath": "/Users/owen/MyCodeSpace"
    }
  ],
  "heartbeatIntervalSeconds": 10,
  "codexBinaryPath": "/opt/homebrew/bin/codex"
}
```

### 3. 启动 Agent

```bash
cd Orchard
swift run OrchardAgent
```

### 4. 打开原生控制端

```bash
cd Orchard
open .
```

然后用 Xcode 打开包目录，运行 `OrchardCompanionApp` target。

## launchd 部署

模板在：

- `deploy/com.owen.orchard.agent.plist.template`

Agent 作为用户级 LaunchAgent 运行时，依赖的是上面的 `agent.json`，不再通过环境变量传 `serverURL`。

建议流程：

1. `swift build -c release`
2. 把 `OrchardAgent` 二进制路径写进 plist
3. 确认 `~/Library/Application Support/Orchard/agent.json` 已存在
4. `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.owen.orchard.agent.plist`

## 验证

```bash
swift build
swift test
```

当前本地验证结果：

- `swift build` 通过
- `swift test` 通过
