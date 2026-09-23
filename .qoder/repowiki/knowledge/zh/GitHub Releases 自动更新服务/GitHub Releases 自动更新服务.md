---
kind: external_dependency
name: GitHub Releases 自动更新服务
slug: github
category: external_dependency
category_hints:
    - vendor_identity
    - sdk_real_api
scope:
    - '**'
---

### GitHub Releases 集成
- **版本检查**: 通过 `api.github.com/repos/xseven77/Tomo/releases/latest` 获取最新版本信息
- **包下载**: 从 Release 中下载 DMG 安装包，支持进度显示和断点续传
- **自动安装**: 使用 hdiutil 挂载 DMG，替换当前应用并自动重启
- **API 版本**: 使用 GitHub API v3，Accept 头设置为 `application/vnd.github+json`，版本标识 `2022-11-28`
- **发布流程**: 支持交互式发布脚本，自动生成 GitHub Release 并上传构建产物