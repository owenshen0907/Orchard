# Orchard Managed Codex Run v1 设计

## 1. 文档目标

这份文档用于冻结 Orchard 下一阶段的主方向：

- 不再把 `Codex attached session` 当系统真相
- 统一引入 `Managed Codex Run`
- 让远程控制、本机执行、移动端观察进入同一条链路

目标闭环只有一个：

1. 远程创建任务
2. 本机用 Codex 执行
3. 持续回传真实状态和日志
4. 远程继续 / 中断 / 停止 / 重试
5. Agent 或 Control Plane 重启后仍能恢复

---

## 2. 当前问题

当前 Orchard 已经有两条链路，但没有统一：

- `Orchard Task`
  - 可调度
  - 可停止
  - 可聚合日志
- `Codex attached session`
  - 可读取
  - 可继续
  - 可中断

问题在于：

- `codex exec` 启动出来的运行态没有 Orchard 自己的稳定 run handle
- Agent 运行态主要存在内存里，重启后无法 reattach
- `/api/codex/sessions` 来自外部 app-server，不适合作为运行中统计真相
- 移动端当前主要是在看快照和 attached session，不是在看 Orchard 托管运行态

所以当前系统离用户要的核心能力还差最后一层：

- 远程指挥中心
- 本机运行中心
- 统一受控对象

---

## 3. 技术栈与可移植性原则

### 3.1 当前实际技术栈

当前仓库已经使用：

- 语言：`Swift 6`
- Control Plane：`Vapor + Fluent + SQLite`
- Agent：`Swift CLI + Process + launchd`
- iPhone 端：`SwiftUI`
- 共享协议：`OrchardCore`
- 传输协议：`HTTP + WebSocket + JSON`
- 部署：`Docker`

### 3.2 是否需要现在换栈

不建议现在重写。

原因很直接：

- 当前痛点不是语言选错
- 当前痛点是系统边界没立住
- 现在换成 `Go`、`Node.js`、`Rust` 或 `Python`，也不会自动得到“可恢复的受控任务”

这轮最优策略是：

- 保留当前 Swift 仓库
- 但把协议、状态机、runtime manifest、driver 抽象做成可移植

### 3.3 可移植性原则

后续是否容易迁移，不取决于是不是 Swift，而取决于下面 5 点：

1. `API-first`
   - 对外只暴露 `HTTP + WebSocket + JSON`
   - 不把 Swift 特有类型泄漏到系统边界

2. `Runtime-first`
   - 运行态真相放在 Agent 本地 manifest 和服务端持久化
   - 不依赖某个 GUI 客户端的 session 列表

3. `Driver-first`
   - 把 `Codex`、`Claude Code`、`Gemini CLI` 之类都收敛成统一 driver 接口
   - Orchard 管理的是 run，不是某个供应商的私有 session

4. `Host-abstraction`
   - 把 `launchd`、`systemd`、Windows Service 视作宿主实现细节
   - 任务创建、停止、日志、重连逻辑不能和苹果平台 API 强耦合

5. `Storage-neutral`
   - manifest 用 JSON
   - 服务端 schema 用通用关系模型
   - 未来从 SQLite 换到 Postgres 不改领域模型

### 3.4 结论

为了容易移植，当前推荐的技术决策是：

- `短期实现栈`
  - Control Plane 继续用 `Swift + Vapor`
  - Agent 继续用 `Swift`
  - 移动端继续用 `SwiftUI`

- `长期移植策略`
  - 控制面协议保持纯 `HTTP/WebSocket/JSON`
  - Agent runtime manifest 保持纯 JSON
  - 运行驱动抽象成协议层
  - UI 一律只依赖 HTTP API

这样后面如果要：

- 把 Control Plane 换成 `Go`
- 把 Web 控制台换成 `Next.js`
- 增加 Linux Agent
- 增加 Android 客户端

都不需要推倒重来。

---

## 4. 领域模型

### 4.1 `ManagedCodexRun`

这是系统真相。

最小字段：

- `id`
- `taskID`
- `deviceID`
- `workspaceID`
- `title`
- `driver`
- `cwd`
- `status`
- `createdAt`
- `startedAt`
- `updatedAt`
- `endedAt`
- `pid`
- `exitCode`
- `summary`
- `lastHeartbeatAt`
- `codexSessionID?`
- `lastUserPrompt?`
- `lastAssistantPreview?`

### 4.2 `ManagedCodexRunEvent`

用于日志和时间线：

- `runCreated`
- `launching`
- `started`
- `logChunk`
- `waitingInput`
- `continued`
- `interruptRequested`
- `stopRequested`
- `finished`
- `reattached`
- `agentLost`

### 4.3 `AttachedCodexSession`

这是辅助观察对象，不是系统真相。

定位：

- 展示外部已存在会话
- 尽力读取
- 尽力继续
- 尽力中断

它不能承担：

- 主统计
- SLA 级运行态判断
- 任务恢复依据

---

## 5. 状态机

`ManagedCodexRun` 最小状态机：

- `queued`
- `launching`
- `running`
- `waitingInput`
- `interrupting`
- `stopRequested`
- `succeeded`
- `failed`
- `interrupted`
- `cancelled`

状态规则：

- `queued -> launching -> running`
- `running -> waitingInput`
- `waitingInput -> running`
- `running -> interrupting -> interrupted`
- `running -> stopRequested -> cancelled`
- `running -> succeeded`
- `running -> failed`

说明：

- `waitingInput` 表示 run 当前需要进一步 prompt 或外部确认
- `interrupting` 是已下发控制命令但本地尚未完成的中间态
- 只有 `succeeded / failed / interrupted / cancelled` 是 terminal

---

## 6. Agent 侧设计

### 6.1 本地 runtime manifest

每个托管 run 在本地都有独立目录：

- `~/Library/Application Support/Orchard/runs/<runID>/`

建议落地文件：

- `run.json`
- `runtime.json`
- `combined.log`
- `stdout.log`
- `stderr.log`

`runtime.json` 最小字段：

- `runID`
- `taskID`
- `driver`
- `pid`
- `cwd`
- `status`
- `startedAt`
- `lastSeenAt`
- `logPath`
- `codexSessionID?`

### 6.2 启动恢复

Agent 启动时：

1. 扫描 `runs/`
2. 读取每个 `runtime.json`
3. 判断 `pid` 是否仍存活
4. 若存活则 reattach 并继续上报
5. 若不存在则补发 terminal 状态

### 6.3 Driver 抽象

Agent 内部新增统一 driver 层：

- `ManagedRunDriver`
  - `launch()`
  - `continueRun()`
  - `interruptRun()`
  - `stopRun()`
  - `snapshot()`

第一批只实现：

- `CodexCLIDriver`

后续再扩展：

- `CodexAppServerAttachedDriver`
- `ClaudeCodeDriver`
- `GeminiCLIDriver`

### 6.4 宿主隔离

当前宿主是 macOS，先继续用：

- `Process`
- `launchd`
- `kill(SIGTERM/SIGKILL)`

但这些能力要只存在宿主层，不能污染领域层。

---

## 7. Control Plane 侧设计

### 7.1 真相来源

Control Plane 对 `ManagedCodexRun` 的真相来源有两部分：

- Agent 主动上报的 run 状态
- 服务端持久化记录

`/api/codex/sessions` 不再用于主统计。

### 7.2 API 草案

新增主接口：

- `GET /api/runs`
- `GET /api/runs/:runID`
- `POST /api/runs`
- `POST /api/runs/:runID/continue`
- `POST /api/runs/:runID/interrupt`
- `POST /api/runs/:runID/stop`
- `POST /api/runs/:runID/retry`
- `GET /api/runs/:runID/logs`

保留现有接口：

- `GET /api/codex/sessions`
- `GET /api/devices/:deviceID/codex/sessions/:sessionID`
- `POST /api/devices/:deviceID/codex/sessions/:sessionID/continue`
- `POST /api/devices/:deviceID/codex/sessions/:sessionID/interrupt`

但文案和页面上要明确标注为：

- `附着会话`
- `仅观察 / 尽力控制`

### 7.3 数据表方向

当前 `tasks` 表可以继续保留。

新增建议：

- `managed_runs`
- `managed_run_events`
- `managed_run_controls`

如果想减少一次迁移，也可以先把 `managed_runs` 作为 `tasks` 的扩展视图实现，但不建议长期混用。

---

## 8. 移动端与网页设计

### 8.1 主看板

Dashboard 主看板切换为：

- 运行中的托管任务
- 最近失败 / 中断
- 在线设备
- 附着会话入口

### 8.2 运行详情

`ManagedCodexRun` 详情页最小能力：

- 基本信息
- 当前状态
- 实时日志
- 最近动作时间线
- 继续
- 中断
- 停止
- 重试

### 8.3 Attached Session 页面

Attached Session 继续保留，但明确降级为：

- 外部会话观察页
- 不参与“运行中”主统计

---

## 9. 分阶段执行

### Phase 1: 协议和模型冻结

- 定义 `ManagedCodexRun` 模型
- 定义 run 控制接口
- 定义 Agent -> Control Plane 的状态载荷

### Phase 2: Agent runtime 落地

- manifest
- reattach
- 统一 driver
- 日志和事件持久化

### Phase 3: Control Plane 汇聚

- run 持久化
- run 控制 API
- 主统计切换

### Phase 4: 移动端和网页切换

- Dashboard 改看 runs
- run 详情和控制
- attached session 降级

### Phase 5: 联调与部署

- 本地构建
- Agent 重启恢复验证
- 线上部署
- 手机端验证

---

## 10. 验收标准

这一版做完后，必须满足：

1. 远程创建一个 Codex run，本机立即执行
2. Dashboard 的运行中数量与本机真实执行一致
3. 手机端能持续看到状态和日志
4. 远程 `continue / interrupt / stop / retry` 都有效
5. Agent 重启后，未结束 run 还能恢复显示和控制
6. attached session 即使异常，也不会影响主统计

---

## 11. 本轮不做

这轮先不做：

- 多用户权限系统
- Android 客户端
- 完整 Web 管理后台重构
- 多 agent 供应商统一调度策略
- 浏览器内直接运行 Codex

先把“远程指挥中心 + 本机运行中心 + Codex 托管闭环”做实。
