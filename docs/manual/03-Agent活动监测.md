# 03 - Agent 活动监测

本章介绍 Tomo 如何发现并监测本机各 AI Coding Agent 的运行状态：文件/数据库轮询、Unix socket 事件桥、统一状态机与任务跳转。

---

## 1. 纳管 Agent 一览（BuiltInAgentCatalog）

Tomo 定义 5 个 agent 家族与展示优先级（`MultiAgentModels.swift:33-65`）：

| 优先级 | Agent | ID | 承载面 (Surface) | 监测数据来源 |
|---|---|---|---|---|
| 0 | Codex | `agent.codex` | codex-cli / codex-desktop | `~/.codex/state_5.sqlite`（threads 表）+ `session_index.jsonl` + 各 thread 的 rollout 日志尾部（`CodexActivity.swift:508-542`） |
| 1 | Deepseek Harness (DSH) | `agent.deepseek-harness` | deepseek-harness-cli | `~/.dsh/sessions` 压缩会话（zstd 帧解压读 head/tail，`DSHActivityService.swift:131-153`） |
| 2 | Hermes | `agent.hermes` | hermes-cli | `~/.hermes/state.db` SQLite（`HermesActivityService.swift`） |
| 3 | Antigravity | `agent.antigravity` | desktop / ide / cli | `~/.gemini/antigravity/` 会话 `transcript.jsonl` 原子步骤（`AntigravityActivityService.swift`） |
| 4 | Pi | `agent.pi` | pi-cli | `~/.pi/agent/sessions/*.jsonl` head+tail 解析（`PiActivityService.swift:78-169`） |

**接入无需安装 Hook**：五个 agent 全部通过读取其本地会话/状态文件被动感知，设置「Agents 与 Hooks」页展示每个 agent 的安装探测状态（CLI/Desktop 是否存在）与官方安装指引弹窗（`AgentHookManager.AgentInstallGuideCatalog`，`AgentHookManager.swift:64-237`；UI `AgentInstallGuideModal`，`SettingsViews.swift:2553`）。

---

## 2. 统一活动状态机

所有来源归一为 `CodexActivityState`（`CodexActivity.swift:6-105`）：

| 状态 | 菜单/胶囊文案 | 颜色 | 宠物动画 |
|---|---|---|---|
| unavailable | — | 灰 | idle |
| idle | — | 灰 | idle |
| thinking | 思考中 | 紫 | running |
| executing | 工作中 | 蓝 | running |
| reviewing | 检查中 | 青 | review |
| waitingForUser | 待确认 | 橙 | waiting |
| completed | 已完成 | 绿 | waving |
| interrupted | 已中止 | 红 | failed |

- `showsActivityWave`：非 idle/unavailable 即显示波浪（`:16-18`）。
- **多任务仲裁**：每个任务的状态带 `arbitrationPriority`（waitingForUser 5 > executing 4 > reviewing 3 > thinking 2 > interrupted 1 > completed/idle 0），聚合快照取最高优先级（`:56-65`、`CodexActivitySnapshot.merged`，`:160-199`）。

### 聚合循环（CodexActivityStore）
- 每 **1.2 秒**在后台线程并发读取 5 路 service 的快照并 merge（`CodexActivity.swift:801-851`）。
- `CodexActivitySnapshotStabilizer` 做防抖：短窗口的状态闪烁不会打到 UI（`:199-226`）。
- 另有 socket 事件 reducer 实时叠加（`ingest(_:)`，`:818-821`），两条通道 merge 后发布（`:853-859`）。
- UI 联动：`AppDelegate` 在快照变化时更新宠物帧、当前活跃 agent 判定（按 task id 前缀 `antigravity:`/`dsh:`/`hermes:`/`pi:` 归属，`AppDelegate.swift:84-101`）、伴侣统计与状态栏标题。

---

## 3. 事件 Socket 与桥接工具（TomoAgentBridge）

除轮询外，agent 可主动推送事件，实现秒级状态：

### 3.1 Socket 服务（AgentEventSocketService）
- 路径：`~/Library/Application Support/Tomo/agent-events.sock`（`AgentEventSocketService.swift:38-41`）。
- 类型：`AF_UNIX` **SOCK_DGRAM**（数据报），权限 `0600`；单包上限 8KB，畸形/超版本包直接忽略——保证发送方 hook 永远 fail-open，不阻塞 agent（`:21-25, 106-121`）。
- App 启动即监听，收到 `NormalizedAgentEvent` 直接 `activityStore.ingest`（`AppDelegate.swift:172-180`）。

### 3.2 事件模型（隐私优先）
`NormalizedAgentEvent`（Schema v1，`MultiAgentModels.swift:681-764`）：
`schemaVersion / agentID / surfaceID / connectionID / sessionID / turnID / event / toolCategory / outcome / timestamp`。
注释明确：**厂商 payload 正文、prompt、工具参数、命令与完整路径永不进入事件**。

事件名（`NormalizedAgentEventName`，`:659-669`）：
`session.started`、`prompt.submitted`、`tool.started`、`permission.requested`、`tool.finished`、`turn.completed`、`session.ended`、`failed`；
工具类别（`AgentToolCategory`）：`reading`、`writing` 等（`:671+`）。

### 3.3 桥 CLI（TomoAgentBridge）
独立可执行 target（`Package.swift` product），供 agent 的 hook 配置以子进程方式调用：
```
TomoAgentBridge --agent <id> --surface <id> --connection <uuid> \
                     --event <vendorEvent> [--socket <path>]
```
- 从 stdin 读厂商 JSON（≤8KB），按内置映射表把厂商事件名**归一化**为上述标准事件（`sessionStart→session.started`、`preToolUse→tool.started`、`permissionRequest→permission.requested`、`stop→turn.completed`、`postToolUseFailure→failed` 等，`Sources/TomoAgentBridge/main.swift:38-52`）。
- 提取 session/turn id 等有限字段后，向 socket 发送一个 UDP 数据报即退出——任何失败都静默（fail-open）。
- 探针脚本：`scripts/probe_multi_agent_capabilities.sh`。

---

## 4. 各 Agent 状态判定细节

- **Codex**：从 SQLite 取最近 threads（含 `rolloutPath`），tail 读 rollout JSONL，由 `CodexActivityEventParser` 解析出任务状态（thinking/executing/waiting…）与标题、工作区名（`CodexActivity.swift:312-499`）；今日任务数 = threads 表当天未归档计数（`:600-620`）。
- **DSH**：`~/.dsh/sessions` 最新会话文件为 zstd 压缩，用内置 `CZSTD` 解尾部帧解析事件流 → 状态（`DSHActivityService.swift:131-292`）。
- **Hermes**：读 `state.db` 活跃会话与最后一条消息推断状态（`HermesActivityService.swift:99-200`）。
- **Antigravity**：解析 transcript 的 StepEvent/ToolCall 原子步骤，精确到思考/执行/待确认（`AntigravityActivityService.swift:90-140`）。
- **Pi**：扫描 sessions 目录 JSONL，head 取元数据（工作区/标题）、tail 取最后事件推导状态（`PiActivityService.swift:78-260`）。

---

## 5. 任务跳转（AgentTaskOpener）

三处 UI（独立 Pet 任务条、主窗口任务卡、刘海展开任务区）共用同一打开路由（`AgentTaskOpener.swift:4-9`）：

| Agent | 行为 | 当前状态 |
|---|---|---|
| Codex | 深链 `codex://threads/<id>`；失败回退打开 ChatGPT.app / Codex.app | 启用（`canOpen` 仅对 Codex/Antigravity 为 true，`:11-13`） |
| Antigravity | 打开 `/Applications/Antigravity.app` | 启用 |
| Hermes | `hermes desktop` 启动 Electron 桌面端 | 代码就绪，暂未启用（等官方会话深链） |
| DSH | 打开本地 Web UI `http://127.0.0.1:3080/sessions/<id>` | 代码就绪，暂未启用 |

不支持打开的任务，UI 自动去掉点击手势与小箭头（注释 `:4-5`）。
