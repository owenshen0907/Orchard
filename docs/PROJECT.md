# Orchard 项目说明

## 当前定位

Orchard 一期先做“个人远程 AI 控制核心”，重点是：

- `macOS Agent`
- `Control Plane`

手机端继续保留为 Companion，但不进入一期关键路径。

## 一期边界

一期当前已经按下面边界实现：

- 单用户
- Tailscale 内网假设
- Swift 技术栈
- `launchd` 用户级 Agent
- 单实例 Vapor Control Plane
- SQLite 持久化

## 当前协议与能力

### `OrchardCore`

- typed task model：
  - `shell`
  - `codex`
- 共享模型：
  - `WorkspaceDefinition`
  - `AgentRegistrationRequest`
  - `CreateTaskRequest`
  - `TaskRecord`
  - `TaskDetail`
  - `DashboardSnapshot`
- WebSocket 消息：
  - `AgentSocketMessage`
  - `ServerSocketMessage`
- workspace 安全路径解析：
  - `OrchardWorkspacePath`

### `OrchardControlPlane`

- HTTP API：
  - `GET /health`
  - `GET /api/snapshot`
  - `GET /api/devices`
  - `GET /api/tasks`
  - `GET /api/tasks/:taskID`
  - `POST /api/agents/register`
  - `POST /api/tasks`
  - `POST /api/tasks/:taskID/stop`
- WebSocket：
  - `GET /api/agents/:deviceID/session?token=...`
- 持久化：
  - `devices`
  - `device_workspaces`
  - `tasks`
  - `task_logs`
- 调度规则：
  - 只派发 `queued`
  - 设备必须在线
  - 设备必须具备目标 capability
  - 设备必须拥有目标 workspace
  - 设备不能超过 `maxParallelTasks`
  - 候选按 `runningTaskCount -> lastSeenAt -> deviceID` 排序

### `OrchardAgent`

- 固定配置文件：
  - `~/Library/Application Support/Orchard/agent.json`
- 固定 runtime 目录：
  - `~/Library/Application Support/Orchard/tasks/<taskID>/`
- 执行器：
  - `ShellRunner`
  - `CodexRunner`
- 行为：
  - CLI 子命令：
    - `run`
    - `init-config`
    - `install-launch-agent`
    - `doctor`
  - 启动时注册设备
  - 建立单条 WebSocket
  - 周期 heartbeat
  - 收到任务后在目标 workspace 执行
  - 流式发送日志
  - 收到 stop 后 `SIGTERM`，10 秒后 `SIGKILL`
  - 重连退避：`1 / 2 / 5 / 10 / 30` 秒
  - Agent 重启后，把上次未完成任务上报为 `failed`，summary 为 `agent restarted`

### `OrchardCompanionApp`

- 通过 HTTP API 查看概览、设备、任务列表与任务详情
- 支持创建简单 `shell` / `codex` 任务
- 支持停止运行中任务或取消排队任务
- 主要用于后续原生控制端迭代
- 一期不参与 Agent 核心通信链路

## 配置

### Control Plane 环境变量

- `ORCHARD_BIND`
- `ORCHARD_PORT`
- `ORCHARD_DATA_DIR`
- `ORCHARD_ENROLLMENT_TOKEN`

### Agent 配置文件

- 路径：
  - `~/Library/Application Support/Orchard/agent.json`
- 字段：
  - `serverURL`
  - `enrollmentToken`
  - `deviceID`
  - `deviceName`
  - `maxParallelTasks`
  - `workspaceRoots[]`
  - `heartbeatIntervalSeconds`
  - `codexBinaryPath`

## 当前验证状态

- `swift build` 通过
- `swift test` 通过
- 已覆盖的自动化测试：
  - payload 编解码
  - workspace 路径约束
  - Agent 重启后未完成任务回补失败状态
  - Agent CLI 参数解析
  - agent 配置初始化
  - LaunchAgent plist 渲染
  - 调度排序
  - 队列任务停止
  - shell 任务端到端执行
  - `running -> stopRequested -> cancelled` 端到端
  - SQLite 重启后持久化

## 下一轮建议

1. 给 Companion 增加实时刷新能力（WebSocket / push）
2. 给 `doctor` 增加更深的 launchctl / 日志状态检查
3. 给 Control Plane 增加更严格的鉴权与会话保护
4. 补充 release 安装包或一键安装脚本
5. 增加任务历史筛选和更稳定的失败摘要策略
