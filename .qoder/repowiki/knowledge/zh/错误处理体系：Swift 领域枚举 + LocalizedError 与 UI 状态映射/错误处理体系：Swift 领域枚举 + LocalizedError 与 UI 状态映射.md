---
kind: error_handling
name: 错误处理体系：Swift 领域枚举 + LocalizedError 与 UI 状态映射
category: error_handling
scope:
    - '**'
source_files:
    - app/Tomo/Sources/Tomo/CodexUsageService.swift
    - app/Tomo/Sources/Tomo/AppDelegate.swift
    - app/Tomo/Sources/Tomo/UsageModels.swift
    - app/Tomo/Sources/Tomo/AppUpdateService.swift
    - app/landing/src/lib/github.ts
---

## 1. 使用的系统与模式
- Swift 端采用 `enum` + `LocalizedError` 协议定义领域错误，通过 `errorDescription` 返回用户可读的中文消息。
- 异步网络/IO 使用 `async throws` 配合 `do/catch` 捕获，错误在调用方转换为 UI 状态（如 `refreshState`、`AppUpdatePhase.failed`）而非直接弹窗。
- Next.js 落地页对 GitHub API 请求采用 try/catch 并回退到静态 fallback 数据，保证页面可用性。

## 2. 核心文件与包
- `app/Tomo/Sources/Tomo/CodexUsageService.swift`：定义 `CodexUsageError`（OAuth、Token、配额不可用等），并在 OAuth 回调服务器、Token 交换、配额抓取中抛出。
- `app/Tomo/Sources/Tomo/AppDelegate.swift`：统一 catch `CodexUsageError`，区分 `noStoredToken` / `invalidTokenResponse` 触发“登录已过期”，其他错误写入 `snapshotStore.markFailed`。
- `app/Tomo/Sources/Tomo/UsageModels.swift`：`UsageSnapshotStore` 提供 `markRefreshing/markDisconnected/markAuthenticationExpired/markFailed` 等状态标记，作为 UI 层唯一错误呈现入口。
- `app/Tomo/Sources/Tomo/AppUpdateService.swift`：定义 `AppUpdateError`（网络、HTTP 状态码、DMG 缺失等），更新流程将异常转为 `AppUpdatePhase.failed(message)`。
- `app/landing/src/lib/github.ts`：Next.js 侧 `fetchJson` 统一 try/catch 返回 null，上层函数以 `FALLBACK_REPO` / `FALLBACK_RELEASES` 兜底。

## 3. 架构与约定
- **领域错误集中化**：所有外部依赖（OpenAI OAuth、ChatGPT Backend、GitHub Releases、文件系统、Keychain）的错误都被封装为明确的 enum case，避免向上冒泡裸 NSError。
- **错误 → 状态映射**：上层不直接展示 Error，而是把错误映射为应用状态字段（`refreshState`、`phase`），UI 仅消费这些状态，从而保证错误表现一致且可测试。
- **可本地化消息**：所有错误枚举均实现 `LocalizedError.errorDescription`，返回中文文案，便于后续接入 i18n。
- **降级与容错**：
  - 缓存/Token 持久化失败被静默吞掉（注释明确“不应阻塞显示最新数据”）。
  - Next.js 侧 GitHub 请求失败返回空数组或默认仓库信息，页面仍可渲染。
  - OAuth 回调超时/取消分别映射为独立 case，避免笼统的网络错误。

## 4. 约定与约束
- 所有可能失败的异步方法必须声明 `throws`，调用方必须显式 `try await` 并用 `do/catch` 处理，禁止隐式崩溃。
- 对外暴露的错误类型必须实现 `LocalizedError`，并提供面向用户的中文描述。
- UI 层不得直接读取 `error.localizedDescription` 以外的错误细节；应通过 `markFailed`、`markAuthenticationExpired` 等状态方法驱动界面。
- 第三方 API 调用失败需映射为领域错误（如 `quotaUnavailable`、`httpStatus(code)`），禁止将原始 HTTP 响应直接上抛。
- 前端工具函数（如 `fetchJson`）遇到异常应返回 null 并由调用方提供 fallback，确保页面不因单点失败而白屏。