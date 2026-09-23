---
kind: build_system
name: 构建与发布系统：Swift Package Manager + Bash 脚本 + Docker
category: build_system
scope:
    - '**'
source_files:
    - app/Tomo/Package.swift
    - app/Tomo/package_app.sh
    - app/Tomo/release_app.sh
    - app/Tomo/rebuild_and_run.sh
    - app/Tomo/Resources/Info.plist
    - docker/landing/Dockerfile
    - app/landing/package.json
---

本仓库采用多语言、多产物的构建体系，围绕 macOS 菜单栏应用（Swift/SwiftUI）与 Next.js 落地页两个子项目分别组织构建流程，并通过 Bash 脚本串联打包、签名、DMG 生成与 GitHub Release 发布。

**1. 使用的系统与工具**
- macOS 原生应用：Swift Package Manager（swift-tools-version 6.0，最低平台 macOS 14），通过 `swift build -c release` 编译；使用 `codesign` 进行 ad-hoc 签名，`hdiutil` 生成 UDZO 格式的 DMG，`ditto` 生成 ZIP 压缩包。
- 产品落地页：Next.js App Router（pnpm@9.15.0，Node 22 Alpine 镜像），通过 `pnpm build` 构建为 standalone 模式输出。
- 容器化：`docker/landing/Dockerfile` 提供可复现的 Landing 站点构建环境。
- 版本管理：通过 `Resources/Info.plist` 中的 `CFBundleShortVersionString` 与 `CFBundleVersion` 维护语义化版本号与 build number。

**2. 核心文件与职责**
- `app/Tomo/Package.swift`：定义 Swift 包结构、目标、测试与链接 sqlite3。
- `app/Tomo/package_app.sh`：构建 release 二进制、组装 `.app` Bundle、资源拷贝、ad-hoc 签名、生成 ZIP 与 DMG。
- `app/Tomo/release_app.sh`：交互式发布流程——校验工作区干净、GitHub CLI 登录、读取/递增版本号、调用 `package_app.sh`、验证 DMG、提交 Info.plist 变更、推送分支与 tag、创建/更新 GitHub Release 并上传附件。
- `app/Tomo/rebuild_and_run.sh`：开发快捷入口，重新打包后自动重启已安装的 Tomo.app。
- `app/Tomo/Resources/Info.plist`：应用元数据与版本号来源。
- `docker/landing/Dockerfile`：多阶段构建 Next.js 站点，暴露 3000 端口并提供 HEALTHCHECK。
- `app/landing/package.json`：定义 pnpm scripts（dev/build/start/lint）与依赖。

**3. 架构与约定**
- 构建产物统一输出到各子项目的 `dist/` 目录：`.app`、`.zip`、`.dmg`。
- 版本号由 `release_app.sh` 通过 PlistBuddy 写入 `Info.plist`，支持 patch/minor/major 三种 bump 策略与手动输入。
- 发布流程强制要求：工作区干净、当前处于命名分支（非 detached HEAD）、GitHub CLI 已认证。
- DMG 生成后会自动挂载验证内容（包含 `.app` 与 `/Applications` 软链），失败则中止。
- 应用内嵌 App Update Service，通过 GitHub Releases API 检查最新版本，但当前发布仅做 ad-hoc 签名，未启用 Apple notarization。

**4. 约束与规则**
- 构建失败回退：若 `swift build` 失败且日志包含模块缓存相关错误，会清理 `.build` 重试一次；仍失败则尝试复用已有的 `.build/release/Tomo` 二进制。
- 版本格式校验：`CFBundleShortVersionString` 必须符合 `^[0-9]+(\.[0-9]+){1,2}$`，`CFBundleVersion` 必须为纯数字。
- 发布前检查：`require_clean_worktree` 禁止未提交的改动；`require_branch` 禁止 detached HEAD。
- 失败回滚：若发布过程中版本号已写入但后续步骤失败，脚本会在 EXIT trap 中恢复原始 `Info.plist` 版本。
- DMG 验证：挂载后必须存在 `${APP_NAME}.app` 与指向 `/Applications` 的符号链接，否则报错退出。
- GitHub Release 幂等：若 tag 已存在但不指向当前 HEAD 则直接失败；若 Release 已存在则需确认是否覆盖上传。