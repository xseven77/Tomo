# Tomo

Tomo 是一款原生 macOS 菜单栏 App。它把多家 AI 供应商的账号额度、多个本地 Coding
Agent 的任务状态、桌面宠物和本地 LLM 网关放在随时看得见的地方；需要更多信息时，再用
悬停卡片、刘海面板或独立窗口查看并行任务、今日陪伴时间、重置券、订阅周期与网关遥测。

[下载最新版本](https://github.com/xseven77/Tomo/releases) ·
[访问 Landing](https://tomo.qiizo.cn) ·
[阅读操作手册](docs/manual/00-总览.md)

![Tomo 原生 macOS 主窗口](assets/screenshots/tomo-dashboard.png)

> 截图拍摄于 Tomo 0.3.8 发布包，仅对账号姓名和邮箱做了匿名化处理。0.4+ 版本主窗口
> 已演进为多账号仪表盘（供应商 logo 轮播、多任务卡），设置页也已重排为五大分区；以实物为准。

## 主要能力

- **供应商额度监控**：统一接入 Codex (OpenAI) OAuth、Google Gemini OAuth、DeepSeek 与
  OpenCode (Go/Zen) API Key，统一刷新、按账号轮播展示额度、余额、重置券与订阅周期。
- **Agent 活动监测**：被动只读感知 Codex、DeepSeek Harness (DSH)、Hermes、Antigravity、
  Pi 五家本地 Agent 的会话/状态文件，无需安装任何 hook；任务状态归一为思考、执行、
  检查、等待确认、完成、中止。
- **本地 LLM 网关**：内置 Rust 子进程网关（`127.0.0.1:58349`），同时代理 OpenAI Chat
  Completions、OpenAI Responses 与 Anthropic Messages 三种协议；提供模型健康巡检、
  严格可用性过滤、多账号路由、密钥托管与用量遥测，可一键接入 Hermes、Pi、DSH。
- **菜单栏与刘海面板**：菜单栏胶囊用状态圆灯 + 额度文字表达当前局面；刘海（Notch）
  区域可展开供应商卡片轮播与实时任务面板，支持多屏选择与外接屏拖拽。
- **桌面宠物**：内置 10 只宠物精灵，随 Agent 活动状态切换动画；支持 `~/.codex/pets`
  自定义宠物，与 Codex 双向同步选择，可开启独立置顶宠物窗口。
- **设置中心**：主题、自动刷新、账号轮播、静默启动、登录项、布局方向、活动波浪、
  刘海目标与 App 内更新。

## 系统要求

- macOS 14 或更高版本。
- 查看本地任务和内置 Pet 时，需要安装 Codex/ChatGPT macOS App。
- 查看各家额度时，需要登录相应供应商账号（OAuth）或填入 API Key。
- 监测各 Agent 活动需要对应 Agent 已在本机运行过至少一个会话；Tomo 不向它们
  安装任何 hook 或注入。
- 从源码构建时需要 Xcode Command Line Tools 与 Rust 工具链（网关为 Rust 工程）。

## 安装与首次启动

1. 前往 [GitHub Releases](https://github.com/xseven77/Tomo/releases)。
2. 推荐下载 DMG，打开后把 `Tomo.app` 拖入 `Applications`；也可以下载 ZIP
   并手动解压到 `Applications`。
3. 启动 Tomo。它是菜单栏 App，正常情况下不会在 Dock 中保留常驻图标。
4. 如果 macOS 阻止首次打开，请进入“系统设置 → 隐私与安全性”，确认允许打开 Tomo。

当前发布包使用 ad-hoc 签名，尚未完成 Apple notarization。

首次启动会自动打开主窗口。关闭窗口后 App 仍会留在菜单栏中；这不是异常，也不等于退出。

## 快速开始

1. 点击 macOS 菜单栏中的 Tomo 胶囊，打开主窗口。
2. 进入“设置 → 账户池”，按供应商添加账号：
   - **Codex (OpenAI)**：点击登录，在 `auth.openai.com` 完成 OAuth PKCE 授权，浏览器
     会回调本机 `http://localhost:1455/auth/callback` 后自动同步额度。
   - **Google Gemini**：完成 Google OAuth 授权。
   - **DeepSeek / OpenCode**：直接填入 API Key。
3. 打开任意一家 Agent 开始任务；Tomo 会从本机会话数据中只读归并任务状态，
   菜单栏圆灯与主窗口任务卡随之变化。
4. （可选）打开“设置 → Gateway”或 Gateway 窗口，把本地网关一键接入
   Hermes、Pi、DSH，获得统一模型接入与用量遥测。

登录完成后可以点击“立即刷新”手动同步，也可以在设置中选择自动刷新间隔。
Codex 授权页最多等待 90 秒；如果回调超时或本机 1455 端口被占用，请关闭占用端口的
程序后重试。

## 使用手册

> 本节为速览；逐文件、逐设置项的完整说明见[操作手册](docs/manual/00-总览.md)。

### 菜单栏与刘海面板

菜单栏胶囊由三个独立部分组成：

| 部分 | 含义 |
|---|---|
| 前置圆灯 | 当前优先级最高的 Agent 任务状态，也可切换为额度健康色 |
| 文字 | 任务状态与当前选中账号的额度摘要 |
| 活动波浪 | 任一 Agent 活动时，胶囊背景出现 30fps 波浪流光（可关闭） |

圆灯颜色和任务状态一一对应：

| 颜色 | 状态 |
|---|---|
| 灰色 | 空闲，或本地任务数据暂不可用 |
| 紫色 | 正在思考 |
| 蓝色 | 正在执行 |
| 青色 | 正在检查 |
| 橙色 | 等待确认 |
| 绿色 | 已完成 |
| 红色 | 已中止 |

常用交互：

- **单击胶囊**：打开或唤起主窗口；按下时中性墨水从实际点击位置扩散一次。
- **悬停约 120ms**：显示当前 Pet、任务状态摘要和活跃任务数，不抢键盘焦点。
- **刘海面板**：在带刘海的屏幕上，胶囊可替换为刘海胶囊；收起态贴合刘海，展开态以
  弹性动画扩成约 700pt 宽面板，内含供应商卡片轮播（点击选中该账号）与实时任务区。
- **多屏与拖拽**：刘海目标可选“所有带刘海的屏”或指定显示器；外接屏面板支持水平
  拖拽并按显示器记忆位置；目标屏没有物理刘海时回退为菜单栏区同款胶囊。
- 开启刘海面板后，同一屏幕的菜单栏图标自动隐藏，刘海成为该屏唯一表面。

### 主窗口

主窗口是额度、供应商、宠物一体的 Companion 仪表盘，支持横向/竖向布局切换与置顶：

- 左侧显示当前账号、可获取的订阅周期、当前 Pet 和今日陪伴时间。
- 任务卡展示状态、thread 名称、工作区、Git 分支、模型和截断后的状态摘要；多个任务
  同时运行时按等待确认、执行、检查、思考等优先级汇总，等待确认的任务优先显示。
- 右侧显示主/次级额度、重置时间、重置券；有多张未过期重置券时，点击券面右侧的
  票根可依次查看，已过期的券不会显示。
- 点击 Pet 可以播放一次随机互动动作；任务运行时仍可互动。
- 右上角按钮依次用于布局方向切换与窗口置顶；底部按钮用于设置、打开 Gateway 窗口、
  打开官方 Usage、退出 App 和立即刷新。

“今天一起工作”会累计思考、执行、检查和等待确认的时间。统计每 30 秒写入本机，
单次结算最多计 90 秒，避免 Mac 休眠后把整段离线时间算进去。

### 账号与额度

| 供应商 | 认证模式 | 可读指标 |
|---|---|---|
| Codex (OpenAI) | OAuth 2.0 PKCE | 5h/周限流窗口、重置券、订阅到期、可用模型目录 |
| Google Gemini | Google OAuth 2.0 PKCE | 周度/5h 额度快照（Antigravity 与第三方池） |
| DeepSeek | API Key | 账户余额（总额/赠送/充值）与币种 |
| OpenCode (Go / Zen) | API Key + 计划类型 | 模型目录校验 |

支持同一供应商添加多个账号，全局选中账号在主窗口、菜单栏文字与刘海卡片间保持同步，
可选按 5 秒至 1 分钟自动轮播全部账号。

### Agent 活动监测

| Agent | 监测数据来源 |
|---|---|
| Codex | `~/.codex` thread 索引 (SQLite) + rollout JSONL 尾部 |
| DeepSeek Harness (DSH) | `~/.dsh/sessions` zstd 压缩会话（解压读首尾） |
| Hermes | `~/.hermes/state.db` SQLite |
| Antigravity | `~/.gemini/antigravity/` 会话 transcript |
| Pi | `~/.pi/agent/sessions/*.jsonl` 首尾解析 |

五家 Agent 全部通过读取其本地会话/状态文件被动感知，Tomo 不安装 hook、不注入
进程。设置页“Agents 与 Hooks”展示每家 Agent 的安装探测状态与官方安装指引。

### Gateway 网关

本地网关由 Rust workspace（`crates/`）构建，随 App 以 helper 子进程方式运行：

- **监听与鉴权**：默认 `http://127.0.0.1:58349` + 本地 Bearer token；开启局域网访问后
  绑定 `0.0.0.0`，且非回环来源访问对话与模型端点一律强制鉴权。
- **三协议代理**：`/v1/chat/completions`、`/v1/responses`、`/v1/messages`
  （Anthropic Messages），把 Codex、Gemini、DeepSeek、OpenCode 等账号统一暴露为模型端点。
- **模型健康巡检**：定时 + 手动探测各账号模型可用性与时延；`/v1/models` 仅导出验证
  可用（或瞬时异常）的模型，`/v1/models/all` 提供全量诊断（状态、失败原因、耗时）。
- **路由策略**：每供应商可选“平滑轮询”（多账号均衡）或“固定特定账号”（遇 429/额度
  耗尽自动无缝切换到池内健康账号并回写设置）。
- **一键接入 Agent**：为 Hermes、Pi、DSH 幂等写入网关配置（含模型白名单、容量/模态/
  思考档位声明），可随时刷新模型列表或移除接入；token 轮换自动同步。
- **遥测与诊断**：Token 年度热力图、模型时序、延迟/客户端排行、实时请求流、
  自动化巡检任务编排与 Gateway Doctor 诊断。

### 桌面宠物

App 内置 10 只宠物（BSOD、Codex、Tomo、Dewey、Fireball、Hoots、NullSignal、
Rocky、Seedy、Stacky），另支持 Codex 标准目录的自定义 Pet：

```text
~/.codex/pets/<pet-id>/
├── pet.json
└── spritesheet.webp
```

- 图集每帧为 `192 × 208` 像素，每行 8 帧，宽度必须为 `1536` 像素；高度必须是 `208`
  的整数倍且至少 9 行；行数 ≥11 视为 v2（含检查等新增动画行）。
- 每一行对应一种动画状态（待机、思考/执行、等待确认、检查、完成挥手、失败、点击
  跳跃等）；Agent 状态变化时先连播 3 遍反应动画，再回落慢速待机循环。
- 在 Tomo 中选择 Pet 会写入 Codex 的 `config.toml`；在 Codex 中切换也会被文件
  监控实时同步回来。运行中的 Codex 通常不会热刷新 Pet，出现“Codex 重启后生效”
  提示时，请先确认没有重要任务运行再重启。
- 可选开启独立置顶宠物小窗，宠物常驻桌面边缘（位置、缩放可调）。

设置页还提供 [codex-pets.net](https://codex-pets.net/)、[Petdex](https://petdex.dev/)
和 [Awesome Codex Pet](https://github.com/legeling/awesome-codex-pet) 入口。
损坏、缺少 manifest 或图集规格不兼容的 Pet 不会进入选择列表。

### 设置

设置窗口分为通用、账户池、Agents 与 Hooks、Gateway、状态栏与 Pet 五个分区：

| 设置 | 可选项与行为 |
|---|---|
| 主题 | 跟随系统（默认）、浅色、深色 |
| 自动刷新 | 30 秒、1 分钟（默认）、2 分钟、5 分钟、10 分钟、关闭 |
| 账号轮播 | 关闭（默认）、5 秒、10 秒、30 秒、1 分钟；主窗口与刘海可分别开关 |
| 静默启动 | 开启后启动只驻菜单栏，不弹主窗口 |
| 登录项 | 注册系统登录项（以系统设置为唯一事实来源） |
| 布局方向 | 主窗口横向（默认）/竖向仪表盘 |
| 活动波浪 | 任务活动时状态栏与 Pet 状态胶囊的波浪流光及其配色 |
| 刘海面板 | 显示目标（自动/指定显示器）、外接屏拖拽、重置全部位置 |
| 独立宠物窗 | 开关、贴靠边缘、缩放与自由位置 |
| 应用更新 | 检查 GitHub Releases，发现新版本后下载并安装 DMG |

窗口置顶与布局方向不在设置列表中：请使用主窗口右上角的按钮。

### 检查和安装更新

1. 打开“设置 → 通用”。
2. 点击“检查更新”。
3. 如果发现更高版本，按钮会变为“下载并安装”。
4. Tomo 下载 GitHub Release 中的 DMG，安装完成后自动重新启动。

也可以点击旁边的外链按钮直接打开 GitHub Releases，手动下载 DMG 或 ZIP。
Tomo 不会在启动时自动检查版本，需要你在设置中手动触发。

### 退出登录与退出 App

- **断开账号**：设置页“账户池”中按账号断开；确认后删除对应本地凭证，再次查看
  额度需要重新授权。最近一次额度快照和陪伴统计不会随凭证一起删除。
- **退出 App**：主窗口底部的电源按钮。确认后 Tomo 完全退出，菜单栏图标也会
  消失，本地网关子进程随之终止。
- 关闭普通窗口只会隐藏窗口，不等于退出 App。

## 本地数据与隐私边界

- OAuth 均在官方授权页完成，Tomo 不接收或保存账号密码。
- 所有凭证以 `0600` 权限保存在 `~/Library/Application Support/Tomo/` 下的
  隔离文件中；不读取浏览器 Cookie、MFA code，不绕过 SSO 或组织策略。
- Agent 活动监测只读本机会话/状态文件（SQLite、JSONL、zstd 会话）；解析器只使用
  任务生命周期事件、工具元数据和用户可见的状态摘要文字，不会持久化、上传或展示
  模型 reasoning、完整提示词、工具原始参数、Token 或环境变量。
- 界面展示的 thread 名称、工作区、分支、模型和摘要只留在本机，不另行上传。
- 网关默认只绑定回环地址；本地请求使用 Bearer token 鉴权，非回环来源访问对话与
  模型端点一律强制鉴权，管理端点对所有来源强制鉴权。
- 最后一次成功的额度快照和陪伴统计缓存在本机，用于启动和暂时离线时展示。

常用本地路径：

| 数据 | 路径 |
|---|---|
| 连接注册中心 | `~/Library/Application Support/Tomo/connections-v1.json` |
| Codex OAuth token | `~/Library/Application Support/Tomo/Runtimes/Codex/<UUID>/oauth_token.json` |
| Gemini OAuth token | `~/Library/Application Support/Tomo/gemini_oauth/<handle>.json` |
| DeepSeek / OpenCode Key | `~/Library/Application Support/Tomo/{deepseek,opencode}_credentials/<handle>.json` |
| 网关设置 | `~/Library/Application Support/Tomo/gateway-settings.json` |
| 最近额度快照 | `~/Library/Application Support/Tomo/latest_snapshot.json` |
| 今日陪伴统计 | `~/Library/Application Support/Tomo/companion_stats.json` |
| 自定义 Pet | `~/.codex/pets/` |
| Agent 事件 socket | `~/Library/Application Support/Tomo/agent-events.sock` |

## 常见问题

### 菜单栏没有出现 Tomo

重新打开 `Applications/Tomo.app`。Tomo 是菜单栏 App，不要只在 Dock 中寻找。
若刘海面板已在当前屏幕启用，菜单栏图标会自动隐藏，请查看刘海胶囊。

### 首次打开被 macOS 阻止

进入“系统设置 → 隐私与安全性”，在相关提示旁选择允许打开。当前构建尚未 notarize。

### 显示“未登录”或额度没有更新

打开“设置 → 账户池”确认账号已添加并启用，然后点击“立即刷新”。如果 Codex 授权已
失效，重新完成 OAuth；浏览器停在回调页时，请确认授权未超过 90 秒，并检查是否有
其他程序占用了本机 1455 端口。

### 没有发现任务

确认对应 Agent CLI 已安装并至少创建过一个本地会话。Tomo 只读本地会话文件；
本地格式不可用时任务状态回退为不可用，但额度功能不受影响。

### 找不到内置 Pet

确认 Codex/ChatGPT App 已安装。更新 Codex 后，在 Tomo 设置页重新扫描 Pet。

### 自定义 Pet 没有出现在列表中

确认目录位于 `~/.codex/pets/<pet-id>`，并同时包含有效的 `pet.json` 与
`spritesheet.webp`（1536px 宽、208px 行高、至少 9 行），然后重新扫描。

### 已切换 Pet，但 Codex 中仍显示旧 Pet

查看设置页是否出现“Codex 重启后生效”。当前运行中的 Codex 不会自动刷新 Pet；
在没有重要任务运行时点击“重启 Codex”。

### Gateway 相关问题

打开 Gateway 窗口的“Gateway Doctor”标签诊断回环端口、鉴权与上游桥接。若 58349
端口被占用，结束占用进程后通过设置开关重启网关。

### App 内更新失败

使用设置页旁边的 GitHub Releases 外链，手动下载最新 DMG。替换
`Applications/Tomo.app` 后重新启动。

## 从源码构建

```bash
cd app/Tomo
./package_app.sh
open "dist/Tomo.app"
```

`package_app.sh` 会先构建 Swift 主程序与 Agent 事件桥，再以 Cargo 构建 Rust 网关
（`crates/gateway-server` → `tomo-gateway`），三者一起打入
`Contents/{MacOS,Helpers}`。

交互式打包与发布：

```bash
cd app/Tomo
./release_app.sh
```

详见[发布脚本说明](app/Tomo/RELEASE.zh-CN.md)。如果 `swift build` 提示 Apple SDK
许可未接受，请先在 Terminal 运行：

```bash
sudo xcodebuild -license
```

单独运行 Rust 测试（协议转换与网关）：

```bash
cargo test --workspace
```

## Landing 开发

```bash
cd app/landing
pnpm install
pnpm dev
```

## 项目结构

```text
app/
├── Tomo/       # Swift / SwiftUI 原生 App、事件桥 CLI、测试和发布脚本
└── landing/         # Next.js landing
crates/              # Rust 网关 workspace（三协议转换、路由、遥测、健康巡检）
spikes/              # 可行性验证 spike
docs/
├── manual/          # 操作手册（官方产品使用说明与规范）
└── developer/       # 开发者 API 与集成说明
assets/screenshots/  # README 使用的原生 App 截图
docker/landing/      # landing 容器部署配置
PROJECT.md           # 当前项目状态与技术边界
README.md
```

## 进一步阅读

- [当前项目状态与技术边界](PROJECT.md)
- [操作手册（按源码生成）](docs/manual/00-总览.md)
- [模型能力与推理强度规范](docs/manual/06-模型能力与推理强度规范.md)
- [开放桌面 API 说明](docs/developer/desktop-api.md)

当前仓库公开源码供审阅；文档中的现行行为以当前源码和测试为准。
