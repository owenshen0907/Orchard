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
- `OrchardAgent` 提供 `init-config / install-launch-agent / doctor` CLI，并可检查 launchctl 服务和日志落点

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
- `ORCHARD_ACCESS_KEY`

### 2. 配置一台 Agent

Agent 固定从下面路径读取配置：

- `~/Library/Application Support/Orchard/agent.json`

示例文件见：

- `deploy/agent.example.json`

也可以直接用 CLI 生成一份可校验的配置：

```bash
cd Orchard
swift run OrchardAgent init-config \
  --server-url http://127.0.0.1:8080 \
  --enrollment-token replace-me \
  --workspace-root /Users/owen/MyCodeSpace \
  --overwrite
```

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

等价命令：

```bash
swift run OrchardAgent run
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
2. 生成或确认 `~/Library/Application Support/Orchard/agent.json` 已存在
3. 执行：

```bash
swift run OrchardAgent install-launch-agent \
  --agent-binary "$(pwd)/.build/release/OrchardAgent"
```

如果你只想先写 plist、不立即 bootstrap，可以加 `--write-only`。

## Control Plane 服务器部署

生产环境建议把 Control Plane 的 env 文件放在仓库同步目录之外，避免 `rsync --delete` 覆盖或删掉线上密钥。

示例 env 文件：

- `deploy/control-plane.env.example`

推荐的远端落点：

- `/home/<user>/orchard-config/control-plane.env`

示例流程：

```bash
scp -P 322 -i ~/.ssh/owen_new_ed25519 \
  deploy/control-plane.env.example \
  owenadmin@8.153.75.111:/home/owenadmin/orchard-config/control-plane.env
```

编辑好远端 env 后，可直接执行部署脚本：

```bash
REMOTE_HOST=8.153.75.111 \
REMOTE_PORT=322 \
REMOTE_USER=owenadmin \
SSH_IDENTITY_FILE=~/.ssh/owen_new_ed25519 \
deploy/deploy-control-plane.sh
```

脚本会做 4 件事：

- `rsync` 同步仓库，但保留远端 `control-plane.env` 和 `data/`
- 如仍存在旧的 `/home/<user>/Orchard/control-plane.env`，自动迁移到仓库外
- 重新 `docker build` `orchard-control-plane:latest`
- 重启容器并用本机 `http://127.0.0.1:<port>/health` 做健康检查

## 项目上下文与宿主机密钥

为了让 Codex / MCP / 自动化任务稳定找到项目部署信息，这个仓库现在约定两层资料：

- 仓库内公开事实：`.orchard/project-context.json`
- 每台宿主机本地密钥：`~/Library/Application Support/Orchard/project-context/<projectID>.local.json`

公开文件里适合维护：

- 服务器在哪
- 应用服务部署在哪
- 数据库文件或数据库实例在哪
- 运行脚本、健康检查地址、配置文件落点

本地密钥文件里适合维护：

- SSH 用户名 / 端口 / 私钥路径
- Control Plane access key
- 其他只应该存在于当前宿主机的访问凭据

查看项目上下文：

```bash
swift run OrchardAgent project-context show --workspace /Users/owen/MyCodeSpace/Orchard
```

按资源直接查局部信息：

```bash
swift run OrchardAgent project-context lookup service orchard-control-plane --workspace /Users/owen/MyCodeSpace/Orchard
swift run OrchardAgent project-context lookup host aliyun-hangzhou-main --workspace /Users/owen/MyCodeSpace/Orchard
swift run OrchardAgent project-context lookup database control-plane-sqlite --workspace /Users/owen/MyCodeSpace/Orchard
swift run OrchardAgent project-context lookup credential orchard-control-plane-api --workspace /Users/owen/MyCodeSpace/Orchard
```

如果你要给脚本、MCP 或自动化任务消费，建议直接用 JSON：

```bash
swift run OrchardAgent project-context lookup host aliyun-hangzhou-main \
  --workspace /Users/owen/MyCodeSpace/Orchard \
  --format json
```

默认会把敏感字段打码；如果你确认当前终端安全，可以显式展开：

```bash
swift run OrchardAgent project-context show \
  --workspace /Users/owen/MyCodeSpace/Orchard \
  --reveal-secrets
```

检查当前宿主机是否已经配好密钥：

```bash
swift run OrchardAgent project-context doctor --workspace /Users/owen/MyCodeSpace/Orchard
```

生成一份本地密钥骨架文件：

```bash
swift run OrchardAgent project-context init-local --workspace /Users/owen/MyCodeSpace/Orchard
```

更完整的字段说明见：

- `docs/PROJECT_CONTEXT.md`

如果托管 Codex run 的工作目录里能定位到 `.orchard/project-context.json`，Agent 还会在首轮 prompt 自动注入一份非敏感上下文摘要，让任务优先按已登记的主机 / 服务 / 数据库事实执行，而不是自己猜。

## Agent 自检

可以在本机上执行：

```bash
swift run OrchardAgent doctor
```

常用变体：

```bash
swift run OrchardAgent doctor --skip-network
swift run OrchardAgent doctor --skip-launch-agent
```

默认检查项包括：

- `agent.json` 是否存在且可解析
- `codex` 可执行文件是否可找到
- Control Plane `/health` 是否可达
- LaunchAgent plist、label、working directory
- `launchctl print` 服务状态
- stdout / stderr 日志路径是否已就绪

## 验证

```bash
swift build
swift test
```

当前本地验证结果：

- `swift build` 通过
- `swift test` 通过
