# 项目上下文

`project-context` 的目标，是把「项目部署事实」和「宿主机私密凭据」分开维护，但又能在执行任务时一次查到。

## 文件分层

### 1. 仓库内公开事实

路径：

- `.orchard/project-context.json`

适合放：

- 项目 ID / 名称 / workspace ID
- 生产、预发、开发环境
- 服务器基础信息
- 服务部署目录、容器名、健康检查地址
- 数据库类型、宿主机、存储路径
- 标准操作命令模板（deploy、health、logs、restart 等）
- 哪些地方需要什么凭据

不适合放：

- SSH 私钥
- access key
- token
- 密码

### 2. 宿主机本地密钥

默认路径：

- `~/Library/Application Support/Orchard/project-context/<projectID>.local.json`

适合放：

- SSH 用户名
- SSH 端口
- SSH 私钥路径
- API access key
- 其他只对当前电脑有效的秘密

## CLI 用法

查看合并后的上下文：

```bash
swift run OrchardAgent project-context show --workspace /path/to/repo
```

按类型直接查局部信息：

```bash
swift run OrchardAgent project-context lookup service orchard-control-plane --workspace /path/to/repo
swift run OrchardAgent project-context lookup host aliyun-hangzhou-main --workspace /path/to/repo
swift run OrchardAgent project-context lookup database control-plane-sqlite --workspace /path/to/repo
swift run OrchardAgent project-context lookup command deploy-control-plane --workspace /path/to/repo
swift run OrchardAgent project-context lookup credential orchard-control-plane-api --workspace /path/to/repo
```

如果要给脚本、MCP 或自动化消费，直接切成 JSON：

```bash
swift run OrchardAgent project-context lookup host aliyun-hangzhou-main \
  --workspace /path/to/repo \
  --format json
```

展开敏感值：

```bash
swift run OrchardAgent project-context show \
  --workspace /path/to/repo \
  --reveal-secrets
```

做健康检查：

```bash
swift run OrchardAgent project-context doctor --workspace /path/to/repo
```

生成本地骨架文件：

```bash
swift run OrchardAgent project-context init-local --workspace /path/to/repo
```

如果你想把本地 secrets 放到别的位置，也可以显式指定：

```bash
swift run OrchardAgent project-context show \
  --workspace /path/to/repo \
  --local-secrets-path /path/to/custom.local.json
```

## 推荐维护方式

1. 在 `.orchard/project-context.json` 维护部署事实
2. 每台宿主机第一次执行 `init-local`
3. 在本地 secrets 文件中补齐凭据
4. 任务执行时统一先跑 `project-context show` 或 `project-context doctor`

## 托管 Codex 任务的自动注入

如果 Orchard 托管的 Codex 任务运行目录向上能找到 `.orchard/project-context.json`，Agent 会在首轮 prompt 前自动补一段非敏感项目上下文摘要。

这段自动注入会包含：

- 项目 / 环境 / 主机 / 服务 / 数据库的基础事实
- 已登记的标准操作命令模板
- 本机凭据是“已配置”还是“缺失哪些字段”
- 明确提醒任务不要把密钥写入仓库或日志

有两个边界：

- 真实 secret 不会注入，敏感值仍然打码
- 控制台里显示的 `lastUserPrompt` 仍然保留原始用户输入，不会把上下文大段塞进 UI

## 适合给 Codex / MCP 的调用方式

优先不要让任务硬编码服务器信息，而是先读取统一上下文：

```bash
swift run OrchardAgent project-context lookup service orchard-control-plane --workspace /path/to/repo
```

如果任务要执行标准 deploy / health / logs 操作，优先查 command：

```bash
swift run OrchardAgent project-context lookup command deploy-control-plane --workspace /path/to/repo
```

这样做有几个直接好处：

- 项目迁移服务器时，只改一处
- 新宿主机接入时，只需要补本地 secrets
- 自动化任务能稳定拿到数据库、服务、部署目录、健康检查地址
- 自动化任务能复用统一的操作命令模板，而不是每次临时拼 SSH 命令
- 敏感信息不会进入仓库

如果任务确实需要全量结构，再退回：

```bash
swift run OrchardAgent project-context show --workspace /path/to/repo
```
