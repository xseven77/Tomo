# 05 - Gateway 本地网关

本章介绍 Tomo 的本地 LLM 网关（Gateway）：进程守护、供应商账号路由、密钥托管、遥测分析与自动化巡检。

---

## 1. 架构定位与生命周期

Gateway 是一个绑定本机回环地址的本地 LLM 代理服务，由仓库根部的 Rust workspace 构建（`crates/gateway-server` 产出二进制 `tomo-gateway`，成员含 `gateway-ir`/`gateway-stream`/`gateway-state`/`gateway-routing`/`protocol-openai-chat`/`protocol-openai-responses`/`protocol-anthropic-messages`/`provider-openai-compatible` 等），将 Codex / Gemini / DeepSeek / OpenCode 等多家账号统一暴露为模型端点，供 Hermes、Pi 等 Agent 接入。**同时代理 OpenAI Chat Completions、OpenAI Responses 与 Anthropic Messages 三种协议**（`crates/gateway-server/src/server.rs` 路由表）：

```text
端点（server.rs）：
  对话：  POST /v1/chat/completions  /v1/responses  /v1/messages（及无前缀变体）
  模型：  GET  /v1/models  /v1/models/all
  遥测：  /telemetry/summary  /telemetry/timeseries  /telemetry/breakdown  /telemetry/requests
  健康：  /health  /status
  内部：  /internal/model-check(/cancel|/status)  /internal/models/health  /shutdown
```

```
 Hermes / Pi 等 Agent
        │  http://127.0.0.1:58349  (Bearer localToken)
        ▼
 Tomo Gateway helper（Rust 子进程）
   ├─ 供应商路由（ProviderRoutingMode 每供应商策略）
   ├─ 密钥注入（GatewaySecretBroker / 各凭证目录）
   └─ 遥测记录（GatewayTelemetry）
        ▼
 OpenAI (Codex OAuth) / Gemini OAuth / DeepSeek Key / OpenCode Key
```

- **监听**：`http://127.0.0.1:58349`，携带本地 token 鉴权（`GatewaySupervisor.swift:13-15`）。开启「局域网访问」后绑定 `0.0.0.0`。
- **按来源强制鉴权**：`GatewayServer::peer_requires_bearer(is_loopback, authorized)`（`crates/gateway-server/src/server.rs`）——**非回环来源**访问 `/v1/chat/completions` 与 `/v1/models` 必须携带 local bearer token，回环来源行为不变。此前这两条路径在任何接口上都免鉴权，于是打开局域网访问即等于把用户的模型额度公开给整个网段，而界面却宣称「local token 鉴权保护中」；现在界面文案与实现一致。`/status`、`/v1/models/all`、`/internal/*` 等管理端点依旧对**所有**来源强制鉴权。
- **多模态附件转发**：`message_text` 只读取 `text` 分片，因此两个结构化上游适配器曾**静默丢弃**用户的图片，模型会对着一张它从未收到的图作答。现由 `message_image_urls` / `parse_inline_data_url` 统一提取，并按协议转换：Gemini Cloud Code 走 `inlineData`（`gemini_inline_data_parts`），Codex Responses 走 `input_image`（`codex_user_content_parts`），OpenAI 兼容透传路径本就原样转发。远端 http(s) 图片在 Gemini 侧无对应字段，因此跳过而非误当文本；`data:` URL 之外的形式不会污染文本。
- **守护**：`GatewaySupervisor.shared` 在 App 启动时立即拉起（`AppDelegate.swift:32`），与 Gateway 窗口无关。helper 二进制查找顺序：`Contents/Helpers/TomoGateway` → bundle auxiliary → 开发目录 `target/(release|debug)/tomo-gateway`（`GatewaySupervisor.swift:45-91`）；找不到时进入 mock loopback 模式（`:101-102`）。
- **启动握手**：以 `--port 58349 --token <token> --auto-check` 启动子进程，读取 stdout 首行 JSON（host/port/token）确认就绪；握手失败则尝试接管已有的健康 Gateway 而不是误报运行（`:142-161`）。
- **自愈**：子进程意外退出触发 `handleUnexpectedGatewayExit`，连续健康检查失败计数 `consecutiveHealthFailures` 驱动恢复调度（`:173-180`）。
- **自动启动开关**：`tomo.gateway.autostart`（UserDefaults，默认 true，`:23-27`），在 Gateway 窗口内可切换。
- **Gemini 联动**：启动 helper 时只注入公开的 OAuth client ID 环境变量，不泄露 refresh token（`:115-121`）。

---

## 2. Gateway 窗口结构

菜单栏/主窗口动作「打开 Gateway 窗口」（`AppDelegate.swift:132-134`）唤起 `GatewayWindowController.shared`。左侧导航共 7 个标签（`GatewayStore.swift:6-39`）：

| Tab | 副标题 | 视图文件 |
|---|---|---|
| 接入与模型 | 管理本地网关服务、已连接供应商账号与全量模型接入 | GatewayConnectView |
| 自动化任务 | 编排并管理本地模型定时巡检与自动化计划 | GatewayAutomationView |
| 一键接入 Agent | 一键配置并同步 Hermes、Pi、DSH 等第三方 Agent 客户端 | GatewayAgentsView |
| 监控概览 | 外部 Agent 伴侣工作时长、流量指标与协议中枢拓扑 | GatewayOverviewView |
| 用量分析 | Token 年度用量热力分布、模型消耗趋势与工具调用统计 | GatewayAnalyticsView |
| 实时请求 | 经本地网关反代的实时请求与流式明细 | GatewayRequestsView |
| Gateway Doctor | 环回端口、鉴权与上游桥接诊断 | GatewayDoctorView |

---

## 3. 接入与模型（Connect）

- 按供应商分组展示账号卡（`GatewayProviderSection` / `GatewayAccountModelGroup` / `GatewayExportedModel`，`GatewayStore.swift:75-195`）：每个 Codex/Gemini 账号导出哪些模型一目了然。
- **每供应商路由策略**（`ProviderRoutingMode`，`GatewaySettings.swift:3-33`）：
  - **平滑过渡 (smooth)**：多账号轮询均衡负载，各账号额度平滑消耗、防并发限频。
  - **固定特定账号 (pinnedAccount)**：流量优先直通所选账号（记录 `pinnedAccountId`）。当该固定账号遭遇 429 限频、额度耗尽或凭证异常时，网关将自动降级为平滑过渡策略（`smooth`），清除该固定账号绑定并持久化回写 `gateway-settings.json`，由平滑池接管后续请求，而不再固定到其他某个账号。
  - 设置入口 `GatewayStore.setProviderRoutingMode`（`GatewayStore.swift:365`），持久化于 `~/Library/Application Support/Tomo/gateway-settings.json`（`GatewaySettings.swift:303-322`）。
- **供应商合并展示**：`isProviderConsolidated` / `setProviderConsolidated` 将同供应商多账号折叠为一组（`GatewayStore.swift:349-357`）。聚合模式下点击查看模型抽屉，直接呈现可访问的可用模型清单，并动态展示调度流向（固定直通或多账号均衡调度）。

---

## 4. 自动化任务（Automation）

任务类型目前为「模型健康巡检」（`AutomationTaskType.modelHealthCheck`，`GatewaySettings.swift:59-81`）：按计划自动探测并验证指定供应商与账号下模型的可用性与时延。

- **任务字段**（`GatewayAutomationTask`，`GatewaySettings.swift:83-105`）：名称、启用开关、目标供应商列表 `providers`、`allAccounts` 或指定 `accountIds`、运行小时表 `hours: [Int]`（0-23 任意小时，空=未设置，24 个=全天候）。
- **全局巡检节奏**（`HealthCheckInterval`，`GatewaySettings.swift:35-57`）：每 1 小时 / 每 6 小时 / 每天 0 点。
- CRUD 与手动触发：`addAutomationTask` / `updateAutomationTask` / `deleteAutomationTask` / `toggleAutomationTask` / `runAutomationTaskNow`（`GatewayStore.swift:384-404`，立即执行走 `triggerModelCheck`）。
- 编辑器：`AutomationTaskEditorSheet`（`GatewayAutomationView.swift:627`），小时选择使用自定义 `FlowLayout` 圆片网格。
- 任务回写 `lastRunAt` / `lastRunStatus` / `lastRunSummary` 供列表展示。

---

## 5. 模型健康检查（Model Health）

- 数据模型：`GatewayModelHealthSummary` / `GatewayModelHealthItem` / `GatewayAccountHealth` / `GatewayModelCheckJobStatus`（`GatewayModelHealthModels.swift`）。
- Gateway 启动就绪后立即 `GatewayStore.shared.refreshModelHealth()`（`GatewaySupervisor.swift:169-171`）；随后按上述自动化计划巡检。
- 巡检结果驱动「接入与模型」页的健康角标与过滤。

---

## 6. 一键接入 Agent（Agents）

为 Hermes、Pi 与 DSH 提供非手动改配置的接入器（幂等地写入/还原）：

- **Hermes**（`HermesGatewayConfigurator.configure(baseURL:apiKey:models:defaultModel:)`，`HermesGatewayConfigurator.swift:235`）：通过 `hermes` CLI 子命令完成模型提供方注册；`unconfigure()` 撤销（`:198`）。
- **Pi**（`PiGatewayConfigurator.configure(...)`，`PiGatewayConfigurator.swift:154`）：以 agent 目录为上下文调用 `pi` CLI 注册网关模型；`unconfigure()` 撤销（`:116`）。
- **DSH（DeepSeek Harness）**（`DSHGatewayConfigurator`，`DSHGatewayConfigurator.swift`）：DSH 无 settings/credentials CLI，接入面就是 DSH 自己的 Models 页所写的那两个文档：
  - `~/.dsh/settings.yaml` → `llm-pi-ai.providers.tomo`（`api: openai-completions`、`baseURL`、`apiKeyEnv`、`models` 白名单、`X-Agent-Name: DSH`）。
  - `~/.dsh/.credentials.yaml` → `refs.TOMO_GATEWAY_TOKEN`（必须 0600，否则 DSH 凭据提供方在解析内容前即拒绝读取）。
  - `llm-pi-ai` 适配器由 `dsh-base` 组合包**休眠挂载**，settings 分节一提供 profile 即热注册路由，因此接入/刷新/移除均**无需重启 dsh**。
  - 两个文档为共享文档（DSH 自身的 Models 页与设置 seam 也在写），因此所有编辑都是**按缩进定位的窄域跨度替换**，绝不解析-重排：注释、键序、未知键，以及用户经 Models 页添加的**同门路由**在接入与移除后逐字节保留。空模型列表、非块映射的 `providers`、旧版扁平凭据文档都会明确报错并回滚，而不是留下半套配置。
  - **模型容量显式声明**：`/v1/models` 只发布 `id`/`name`/`owned_by`，不含容量元数据。若条目不带 `contextWindow`/`maxTokens`，适配器会采用 262,144 / 32,768 的默认值——而过度声明的代价是提供方在轮次中途拒绝、消息已持久化、会话反复重试一个不可能成功的请求。故每条目写入保守下限容量（`DSHModelCapacity`）。留空默认值时该路由也用不上 pi-ai 的 catalog。
  - **输入模态显式声明**：模态解析顺序为「条目 `input` → 已安装 catalog 条目 → 路由 `defaultInput`（默认 `[text]`）」，而手工路由**没有任何已安装条目**，因此缺省 `input` 的条目就是纯文本模型，DSH 会在**客户端**直接拒绝附件（提示「当前模型不支持图片，请切换支持图片的模型」），请求根本不会到达网关。故每条目写入 `input: [text, image]` 或 `input: [text]`（`DSHModelModality`，flow 风格单行以便跨度编辑器改写）。可声明视觉的家族刻意收窄为 `gemini` / `claude` / `*-vl` / `vision`——多声明的代价是提供方在轮次中途拒绝，远比少声明昂贵。
  - **思考档位显式声明**：`resolveModelReasoning` 同样先读条目的 `reasoningEfforts`，再回退到已安装 catalog 条目——手工路由没有这份回退，于是 `reasoning` 解析为 `false`，选择器**完全不出现思考控件**。每条目按家族写入 `reasoningEfforts`（`DSHModelReasoning`）：`off:`（**不给值**，pi-ai 读作「支持但不发送」，从而保留提供方默认）、`low: low`、`medium: medium`、`high: high`。只声明网关**真正兑现**的档位——`gemini_thinking_budget` 仅映射 `none/off/disabled/low/medium/high`，因此 `minimal`/`xhigh`/`max` 不声明（声明了也是一个静默无效的控件）；Codex Responses 路径完全不读 `reasoning_effort`，故 `openai/*` 不声明；通用透传路径虽原样转发但未经验证，同样暂不声明。
  - **自动同步指纹覆盖完整条目**：指纹为 `id|contextWindow|maxTokens|input|reasoning`，容量、模态或思考档位的任何变化都会触发自动重写；纯改名不触发。
  - **刷新模型列表**：`refreshDSHModels()` 就地重写 `tomo` 路由的 `models:` 数组（DSH 的 `models` 是数组、整体替换），下架模型随之消失、新模型随即出现，整个替换在**单次原子写入**内完成，因此不存在「先移除再接入」的空窗期——「移除后重新接入」这条退路被收敛为一次跨度替换。`refreshModels` 返回文档是否真正变化，UI 据此区分「已刷新」与「已是最新」。
  - **默认模型**：可选写入 `agent-default-model.provider/model`；移除时仅当 `provider` 仍指向 `tomo` 才清除，且**保留**用户原有的 `reasoningEffort`。刷新若使原默认模型下架，会自动改指新清单首个模型，避免 DSH 以 `UNKNOWN_MODEL` 失败。
  - **环境变量遮蔽检测**：DSH 解析引用时**进程环境优先于受管文档**且不可从进程内覆盖，故若存在 `TOMO_GATEWAY_TOKEN` 环境变量，写入会被静默遮蔽；此时接入直接失败并给出提示，卡片也常驻警示。
- Agent 目录模型白名单随账号刷新动态同步：账号刷新成功后仅在官方模型目录真正变化时调用 `GatewayStore.shared.syncConfiguredAgentCatalogsIfNeeded()`（`GatewayStore.swift:4101`），三家各自持有 UserDefaults 指纹（`Tomo.hermesCatalogFingerprint` / `Tomo.piCatalogFingerprint` / `Tomo.dshCatalogFingerprint`）。
- Token 轮换（`rotateAuthToken()`）会平滑同步至全部已接入 Agent，含 DSH 的 `refs.TOMO_GATEWAY_TOKEN`。
- **已知限制（上游参数白名单）**：网关重建上游请求体，只透传 `temperature`/`top_p`/`max_tokens`/`tools`/`tool_choice`/`reasoning_effort`/`thinking`。因此 `stream_options.include_usage` 不会到达上游，流式响应的 `usage` 字段缺失，DSH 侧 token 计量为空（功能不受影响）。修正需逐上游验证兼容性，暂缓。

---

## 7. 监控概览 / 用量分析 / 实时请求

- **监控概览 (Overview)**：`GatewayAgentWorkRow` 展示各外部 Agent 的工作时长与流量指标、协议拓扑（`GatewayStore.swift:43`，`GatewayOverviewView.swift`）。
- **用量分析 (Analytics)**（`GatewayTelemetryModels.swift`）：
  - 日期范围 `GatewayDateRange`（含自定义起止日期，`GatewayCommon.swift:56-103` 提供选择器）。
  - 年度/区间 **Token 热力图**（`GatewayHeatmapCell/Summary`），模型时序（`GatewayModelTimeseriesPoint`），Token 构成（`GatewayTokenComposition`），模型排行 / 延迟排行 / 客户端排行（`GatewayModelRankingItem` / `GatewayLatencyRankingItem` / `GatewayClientRankingItem`），可按维度分组（`GatewayBreakdownDimension`）。
- **实时请求 (Requests)**：
  - `GatewayRequestRow` 逐条展示经网关反代的请求（含流式明细）；服务端数据来自遥测接口（`GatewayRequestsResponse`）。
  - 分页：`goToPage/nextPage/prevPage/setPageSize`（`GatewayStore.swift:558-579`）。
  - **列设置**：`GatewayRequestColumn` 枚举全部可显示列，按 `GatewayColumnCategory` 分类；`GatewayColumnSettingsSheet`（`GatewayColumnSettingsView.swift:3`）中勾选，`isColumnVisible/toggleColumn`（`GatewayStore.swift:608-612`）持久化。

---

## 8. Gateway Doctor（诊断）

`GatewayDoctorCheck`（`GatewayStore.swift:256`）驱动的诊断页（`GatewayDoctorView.swift`）：环回端口占用/连通、local token 鉴权、上游供应商桥接逐项体检。

---

## 9. 密钥托管（SecretBroker）

`GatewaySecretBroker` 用 macOS Keychain 保存网关侧账号密钥（`saveSecret/retrieveSecret/deleteSecret`，`GatewaySecretBroker.swift:33-86`），并提供 `migrateLegacyFile` 将旧版明文文件凭证迁移进 Keychain（`:100`）。Agent 侧只需拿到指向 127.0.0.1:58349 的配置与 local token，真实上游密钥不出网关进程。
