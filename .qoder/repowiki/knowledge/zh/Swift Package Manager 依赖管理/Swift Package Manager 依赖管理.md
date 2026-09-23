---
kind: external_dependency
name: Swift Package Manager 依赖管理
slug: swift-package-manager
category: external_dependency
category_hints:
    - framework_behavior
scope:
    - '**'
---

### SPM 配置
- **平台要求**: macOS 14+，使用 swift-tools-version 6.0
- **系统库链接**: 链接 sqlite3 用于本地任务数据解析
- **包结构**: 单一可执行目标 `Tomo`，包含测试目标 `TomoTests`
- **构建系统**: 基于 Swift Package Manager 的原生构建，无需第三方框架依赖