# Tomo & Tomo Go 品牌重构与完整工程迁移方案

## 1. 品牌定义与哲学体系 (Brand Foundation)

### 1.1 命名矩阵与含义解析
* **主品牌 / 桌面端 (macOS App)**：**`Tomo`**
* **移动伴生端 (Mobile Web / PWA / App)**：**`Tomo Go`**
* **发音指引**：
  * `Tomo`：`/ˈtoʊmoʊ/`（双 O 对称长元音，发音温润、流畅，无中二与琐碎感）。
  * `Tomo Go`：`/ˈtoʊmoʊ ɡoʊ/`（律动连贯，双音节加单音节，极具随行轻快感）。
* **品牌含义与哲学**：
  * **友（とも, Tomo）**：象征长驻桌面的 **AI 伙伴 / 智能体伴侣**，彻底摆脱单一技术中间件的冷硬感；
  * **共に（ともに, Tomo-ni）**：意为**“一同、共同、携手同频”**——代表 **Mac 桌面端与手机端随时随地同频流转**，也代表 **开发者与 Coding Agent 的并肩协作**。
  * **Go**：随身随行、即走即连，轻量级随身状态看板。

### 1.2 产品定位与核心价值主张 (The Pitch)
> **Tomo — Your ambient companion & mobile dashboard for coding agents and token runtime.**  
> （与你的开发节拍时刻同频的智能体伴侣与随行看板）

* **Ambient Companion（静默守护与状态感知）**：自动感知本地 Coding Agent（Cursor、Codex、Claude Code 等）的任务流水，将终端漫长的黑盒编译转化为桌面悬浮感知、治愈系 Pets 状态动画与系统通知。
* **Model & Token Gateway（本地多模型路由与配额中枢）**：集成 Anthropic、Gemini、OpenAI 多协议路由，实时监控 Token 水位、配额与健康检查，敏感凭证由系统 Keychain 严密保护。
* **Continuous Flow（Tomo + Tomo Go 跨端流动）**：Mac 桌面端作为核心算力与数据底座；离开电脑拿起手机，通过 `Tomo Go` 与安全隧道实时追踪 Agent 进度、查阅日志与接收异常告警。

---

## 2. 涉及仓库与架构拓扑 (Ecosystem Mapping)

```text
Personal/
├── Tomo/ (当前主工程，原 Codexling)
│   ├── app/Tomo/                     (原 app/Codexling，macOS Swift 原生应用)
│   ├── app/landing/                  (Next.js 16 官网与文档站)
│   └── crates/gateway-server/        (Rust 核心网关，输出 tomo-gateway 二进制)
│
├── TomoGo/ (原 CodexlingMobile)
│   ├── web/                          (Mobile Web 看板，编译为 mobile-web-plugin.zip)
│   ├── ios/ & android/               (移动端 Native 容器)
│   └── scripts/                      (打包与发布脚本)
│
├── TomoLogo/ (原 TokomiLogo)
│   └── g-row.html                    (终选 Logo 画廊，包含 G 系列全套矢量与多尺寸位图)
│
└── qiizo-gateway/ & qiizo-docker-tools/
    └── lib/expose/                   (用于公网 HTTPS 与 FRP 隧道发布的配置)
```

---

## 3. 详细实施路线图 (Phase-by-Phase Plan)

### 阶段 1：视觉系统与 Logo 资产归位 (Visuals & Icons)

以 `TomoLogo` 中 `g-row.html` 终选方案的 **G 系列** 为基准（外框为高饱和度圆角几何底座，中心镂空字母 **T**，移动端内嵌粗体 **GO**，首字母与品牌 100% 契合）：

1. **导出全尺寸 macOS AppIcon**：
   * 尺寸梯队：`16x16`, `32x32`, `64x64`, `128x128`, `256x256`, `512x512`, `1024x1024`（含 `@1x` 与 `@2x` 位图）。
   * 替换目标：`app/Codexling/Resources/Assets.xcassets/AppIcon.appiconset/`。
2. **替换 Web 与移动端静态图标**：
   * `app/landing/public/`：`favicon.ico`, `apple-touch-icon.png`, `site.webmanifest`，替换应用名与图标。
   * `CodexlingMobile/web/public/`：更新 PWA 图标与启动画面。

---

### 阶段 2：Rust 网关重命名与编译校验 (Crates & Helpers)

1. **重命名二进制生成物**：
   * 编辑 `crates/gateway-server/Cargo.toml`：
     ```toml
     [[bin]]
     name = "tomo-gateway"  # 原 codexling-gateway
     path = "src/main.rs"
     ```
2. **更新打包与辅助执行程序路径**：
   * 编辑 `app/Codexling/package_app.sh`：
     ```bash
     # 原：cp "../../target/release/codexling-gateway" "${APP_BUNDLE}/Contents/Helpers/CodexlingGateway"
     cp "../../target/release/tomo-gateway" "${APP_BUNDLE}/Contents/Helpers/TomoGateway"
     chmod +x "${APP_BUNDLE}/Contents/Helpers/TomoGateway"
     ```
3. **验证命令**：
   ```bash
   cargo build --release --bin tomo-gateway
   test -f target/release/tomo-gateway
   ```

---

### 阶段 3：macOS 客户端工程与代码语义迁移 (Swift Level)

1. **更新 Swift Package 声明 (`app/Codexling/Package.swift`)**：
   * 将 `name: "Codexling"` 更名为 `name: "Tomo"`；
   * 将可执行产物 `Codexling`、`CodexlingAgentBridge` 更名为 `Tomo`、`TomoAgentBridge`；
   * 对应 targets 与 testTargets 迁移为 `Tomo`、`TomoTests`。
2. **更新应用属性清单 (`app/Codexling/Resources/Info.plist`)**：
   * `CFBundleName`：`Tomo`
   * `CFBundleExecutable`：`Tomo`
   * `CFBundleIdentifier`：`com.qiizo.tomo`
3. **改造运行时路径与服务宣告**：
   * **`GatewaySupervisor.swift`**：
     * 辅助程序名：`TomoGateway`；
     * 清理孤儿进程正则：`-x TomoGateway`。
   * **`CodexAppServerRuntime.swift`**：
     * `clientInfo` 声明为 `["name": "Tomo", "title": "Tomo", "version": "..."]`。
   * **`WebPluginInstaller.swift` / `MobileSyncServer.swift`**：
     * 默认插件安装目录指向：`~/Library/Application Support/Tomo/Plugins/mobile-web`。
   * **IPC Socket 路径**：
     * `~/Library/Application Support/Tomo/agent-events.sock`。

---

### 阶段 4：用户已有数据平滑继承与兼容策略 (Auto-Migration)

确保老用户版本升级后，已有的 API Key、模型路由设置、桌宠偏好和任务历史 100% 不丢失：

1. **Application Support 目录无感升级**：
   * 在 App 启动初始化时（`AppState` 或 `ApplicationMain`）增加继承检测：
     ```swift
     let fileManager = FileManager.default
     let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
     let oldDir = appSupport.appendingPathComponent("Codexling")
     let newDir = appSupport.appendingPathComponent("Tomo")

     if !fileManager.fileExists(atPath: newDir.path) && fileManager.fileExists(atPath: oldDir.path) {
         try? fileManager.copyItem(at: oldDir, to: newDir)
     }
     ```
2. **Keychain 凭证回退读取 (Fallback Policy)**：
   * 在 `GatewaySecretBroker.swift` 中：
     * 新凭证服务名：`com.qiizo.tomo.gateway`；
     * 读取策略：优先读取 `com.qiizo.tomo.gateway`；若为空，回退尝试读取旧版 `com.qiizo.Codexling.gateway`。读取成功后自动在 `com.qiizo.tomo.gateway` 中创建副本。

---

### 阶段 5：伴生移动端与外部网关同步 (Tomo Go & Gateway)

1. **移动端工程升级 (`CodexlingMobile`)**：
   * UI 显示名称：`Codexling Mobile` ➡️ **`Tomo Go`**；
   * Web 构建产物保持与桌面端安装器解压规则一致；
   * Mobile 握手 API 与心跳客户端标识升级为 `Tomo Go`。
2. **更新 FRP 与公网域名映射**：
   * 官方主站映射：`tomo.qiizo.cn`（原 `codexling.qiizo.cn` 设置 301 重定向）；
   * 移动伴生端映射：`tomo-go.qiizo.cn`；
   * 执行网关挂载命令：
     ```bash
     qiizo-expose add tomo-go \
       --host host.docker.internal \
       --port 58350 \
       --domain tomo-go.qiizo.cn
     ```

---

### 阶段 6：文件夹重命名与 Git 仓库结构归位 (Directories & Git)

在当前分支通过完整编译与测试后，执行物理目录变更：

1. **主工程源码目录重构**：
   ```bash
   git mv app/Codexling app/Tomo
   git mv app/Tomo/Sources/Codexling app/Tomo/Sources/Tomo
   git mv app/Tomo/Sources/CodexlingAgentBridge app/Tomo/Sources/TomoAgentBridge
   git mv app/Tomo/Tests/CodexlingTests app/Tomo/Tests/TomoTests
   ```
2. **本地主目录更名（建议在 IDE 与终端关闭后执行）**：
   ```bash
   mv /Users/qiizo/code/Personal/Codexling /Users/qiizo/code/Personal/Tomo
   mv /Users/qiizo/code/Personal/CodexlingMobile /Users/qiizo/code/Personal/TomoGo
   mv /Users/qiizo/code/Personal/TokomiLogo /Users/qiizo/code/Personal/TomoLogo
   ```
3. **文档与 Landing Page 文案重构**：
   * 全面更新 `PROJECT.md`、`README.md`、`AGENTS.md`；
   * 更新 `app/landing/` 页面标题、Hero 介绍大字与下载产物文件名（如 `Tomo-0.9.0.dmg`）。

---

## 4. 实施核验清单 (Verification Checklist)

- [ ] **视觉交付**：`AppIcon.appiconset` 包含完整的 16~1024 尺寸，高光与圆角在 macOS Dock 栏测试正常。
- [ ] **Rust 编译**：`cargo test` 全绿，`cargo build --release` 产物为 `tomo-gateway`。
- [ ] **Swift 编译**：`swift build` 与 `swift test` 顺利通过，无断头包引用。
- [ ] **应用打包**：`./app/Tomo/package_app.sh` 正常生成 `Tomo.app`，检查其 `Contents/Helpers/TomoGateway` 具备可执行权限。
- [ ] **数据无感迁移**：模拟旧用户环境启动，验证历史 API 密钥、SQLite 数据库无损导入。
- [ ] **跨端联调**：桌面端 `Tomo` 启动 MobileSyncServer，移动端打开 `Tomo Go`（局域网与公网），SSE 连接顺畅且任务状态实时同步。
- [ ] **文档与外链**：Landing 页面 `pnpm build` 通过，所有品牌露出均已更新为 Tomo / Tomo Go。
