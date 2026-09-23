---
kind: dependency_management
name: 多语言依赖管理：Swift Package Manager + pnpm 双栈策略
category: dependency_management
scope:
    - '**'
source_files:
    - app/Tomo/Package.swift
    - app/landing/package.json
    - app/landing/pnpm-lock.yaml
    - app/landing/.npmrc
---

本仓库采用**双栈依赖管理**策略，分别针对 Swift/macOS 原生应用与 Next.js 落地页使用不同的包管理器与锁定机制。

### 1. Swift 端（macOS 菜单栏应用）
- **包管理器**：Swift Package Manager (SPM)，`swift-tools-version: 6.0`，目标平台 `macOS(.v14)`。
- **依赖声明位置**：`app/Tomo/Package.swift`，仅声明一个可执行 target `Tomo` 和一个测试 target，未引入第三方 Swift 包依赖，仅链接系统库 `sqlite3`。
- **版本约束**：通过 `platforms` 字段固定最低 macOS 版本，无外部 Swift 包依赖，依赖关系极简。
- **构建缓存**：项目根目录存在 `.pnpm-store/v11/`，但这是 pnpm 的存储，非 SPM 缓存；SPM 默认缓存位于 `~/.build` 或 `DerivedData`，未纳入版本控制。

### 2. JavaScript/TypeScript 端（Next.js 落地页）
- **包管理器**：**pnpm@9.15.0**，通过 `package.json` 中的 `"packageManager": "pnpm@9.15.0"` 字段强制统一版本，确保团队成员使用相同 pnpm。
- **依赖声明**：`app/landing/package.json` 中明确区分 `dependencies`（lucide-react、next、react、react-dom）与 `devDependencies`（eslint、tailwindcss、typescript 等）。
- **锁定文件**：`app/landing/pnpm-lock.yaml`（lockfileVersion '9.0'）完整锁定所有依赖及其子依赖的版本与 integrity hash，保证构建可重现。
- **构建优化**：通过 `pnpm.onlyBuiltDependencies` 配置仅对 `sharp` 和 `unrs-resolver` 执行 native 构建，加速安装。
- **Peer 依赖处理**：`.npmrc` 中设置 `auto-install-peers=true`，自动安装 peer dependencies。

### 3. 架构与约定
- **模块隔离**：Swift 与 JS 依赖完全解耦，各自在独立子目录下管理，无跨语言依赖。
- **无 vendoring**：未使用 `vendor/` 或 `node_modules/` 提交到版本控制，依赖通过包管理器从远程注册表拉取。
- **私有注册表**：未发现 `.npmrc` 中配置私有 registry 或 `GOPRIVATE`，所有依赖来自公共源（npm registry、Apple Swift Package Index）。