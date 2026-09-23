---
kind: configuration_system
name: 配置系统 — UserDefaults + Next.js 环境变量分层管理
category: configuration_system
scope:
    - '**'
source_files:
    - app/Tomo/Sources/Tomo/AppSettings.swift
    - app/landing/.env.example
    - app/landing/src/lib/site.ts
    - app/landing/src/lib/github.ts
    - app/landing/next.config.ts
---

本仓库包含两个独立应用，各自采用不同的配置加载与分层策略：

**1. macOS 菜单栏应用（Swift/SwiftUI）**
- 核心配置存储：`AppSettingsStore`（`app/Tomo/Sources/Tomo/AppSettings.swift`）统一通过 `UserDefaults.standard` 持久化所有用户偏好。
- 配置键命名规范：以 `tomo.` 为前缀（如 `tomo.theme`、`tomo.autoRefreshInterval`、`tomo.petsEnabled` 等），集中定义在内部 `Keys` 枚举中。
- 默认值策略：每个配置项在初始化时提供明确的默认值（如主题默认为 `.system`、刷新间隔默认为 `minutes1`、宠物开关默认为 `true` 等）。
- 旧版迁移：支持从旧 suite `com.qiizo.codex-light` 及 key 前缀 `codexLight.` 自动迁移历史配置到新的 `tomo.` 命名空间。
- 响应式更新：所有可写属性使用 `didSet` 触发回调（`onThemeChanged`、`onPetSettingsChanged`、`onAutoRefreshIntervalChanged`、`onDashboardOrientationChanged`），实现 UI 即时响应。
- 主题系统：`AppThemePreference` 枚举支持跟随系统/浅色/深色三种模式，并映射到 NSAppearance 与 SwiftUI ColorScheme。
- 运行时配置：部分设置（如自动刷新间隔）会动态影响后台定时器行为。

**2. Next.js 产品落地页**
- 构建期配置：`next.config.ts` 仅设置 `output: "standalone"`，无其他复杂配置。
- 运行期环境变量：通过 `.env.example` 模板提供 `NEXT_PUBLIC_SITE_URL`（站点 URL）和可选的 `GITHUB_TOKEN`（GitHub API 速率限制）。
- 前端环境变量：`siteConfig`（`src/lib/site.ts`）集中暴露站点元数据，URL 字段读取 `process.env.NEXT_PUBLIC_SITE_URL` 并提供回退值。
- 服务端环境变量：`github.ts` 中通过 `process.env.GITHUB_TOKEN` 注入认证头，用于提升 GitHub API 调用频率限制。
- 部署约定：`.env.example` 明确标注部署后需将 `NEXT_PUBLIC_SITE_URL` 改为实际域名。

**3. 跨项目约定**
- 配置文件不纳入版本控制：macOS 应用的 UserDefaults 由系统管理，Next.js 的 `.env` 文件通过 `.gitignore` 排除。
- 环境隔离：客户端环境变量以 `NEXT_PUBLIC_` 前缀区分，服务端变量直接访问 `process.env`。
- 向后兼容：Swift 端内置旧配置格式迁移逻辑，确保升级平滑。