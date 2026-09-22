# Codexling 发布脚本说明

本文档说明如何使用 `release_app.sh` 交互式完成 macOS App 打包和 GitHub Release 发布。

## 脚本位置

```bash
app/Codexling/release_app.sh
```

## 发布顺序

脚本会按下面顺序执行：

1. 检查本机依赖命令。
2. 检查 GitHub CLI 登录状态。
3. 如果未登录，启动 `gh auth login` 的交互式网页登录授权。
4. 授权完成后，检查 Git 工作区是否干净。
5. 提示输入本次发布版本号。
6. 提示输入 build number。
7. 写入 `Resources/Info.plist` 的版本号。
8. 执行 `package_app.sh`，重新生成 `.app`、`.zip` 和 `.dmg`。
9. 挂载 DMG，验证其中包含 `Codexling.app` 和 `Applications` 快捷方式。
10. 如版本文件有变化，自动提交 `Release <version>`。
11. 推送当前分支。
12. 创建并推送 `v<version>` tag。
13. 创建或更新 GitHub Release。
14. 上传本次新生成的 DMG 和 ZIP。

注意：脚本一定会先完成授权检查，再询问版本号；输入版本号之后才会开始打包发布流程。

## 使用方法

在仓库根目录运行：

```bash
cd app/Codexling
./release_app.sh
```

或者从任意目录运行：

```bash
cd app/Codexling
./release_app.sh
```

## 前置依赖

脚本需要以下命令：

- `swift`
- `hdiutil`
- `codesign`
- `gh`

其中 `hdiutil` 和 `codesign` 是 macOS 自带命令。

## Gemini OAuth 构建配置

Gemini 正式发布应使用 Codexling 自己在 Google Cloud 创建的 **Desktop app OAuth Client**。自有桌面客户端采用 PKCE，通常只需要 Client ID。旧 OAuth Client 如果在 Token 接口强制校验 Secret，可以通过仅本机的兼容配置临时注入。

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>clientID</key>
  <string>YOUR_CODEXLING_DESKTOP_CLIENT_ID</string>
</dict>
</plist>
```

仓库中的 `Resources/GeminiOAuthConfig.example.plist` 可以直接复制为自有 Desktop Client 模板。

本机的 `package_local.sh`、`release_local.sh` 会读取同目录下被 Git 忽略的 `.env`：

```bash
CODEXLING_GEMINI_OAUTH_CLIENT_ID='YOUR_CLIENT_ID'
CODEXLING_GEMINI_OAUTH_LEGACY_CLIENT_SECRET='YOUR_LEGACY_CLIENT_SECRET'
```

切换到 Codexling 自有 Desktop Client 后，删除 `CODEXLING_GEMINI_OAUTH_LEGACY_CLIENT_SECRET`，并相应取消本地脚本对它的必填检查。

通过环境变量把文件路径交给打包脚本：

```bash
export CODEXLING_GEMINI_OAUTH_CONFIG_PLIST=/absolute/private/path/GeminiOAuthConfig.plist
./release_app.sh
```

本地开发也可以将文件放在 `Resources/GeminiOAuthConfig.plist`；该路径已被 `.gitignore` 排除。未提供配置时仍可构建和使用其他功能，但 Gemini 新账号登录会提示当前开发版本不包含登录配置。

CI 可以直接把 GitHub Actions Secrets 映射为环境变量，不需要在工作区生成或提交配置文件：

```yaml
env:
  CODEXLING_GEMINI_OAUTH_CLIENT_ID: ${{ secrets.CODEXLING_GEMINI_OAUTH_CLIENT_ID }}
```

`package_app.sh` 会在临时目录生成 plist，只复制到 App bundle，并在脚本结束时删除临时文件。完整发布流程会检查 Client ID 以及 DMG 内的最终 App；缺少配置时发布会立即失败，不会上传一个无法登录 Gemini 的安装包。Client ID 会随桌面应用公开，这是 Installed App OAuth 的正常行为；不要使用或复制 Antigravity、Gemini CLI 等其他应用的 OAuth Client ID。

CI 或本地发布前可以只执行配置预检，不触发编译：

```bash
CODEXLING_REQUIRE_GEMINI_OAUTH_CONFIG=1 ./package_app.sh --validate-oauth-config
```

普通用户不需要配置任何 ID、Secret、plist，也不需要安装 Antigravity Desktop 或 CLI。发布者注入 Codexling 自有 Client ID 并完成 Google OAuth 应用发布/验证后，用户安装 Codexling 并点击“添加 Gemini 账号”即可完成授权。

如果缺少 GitHub CLI，先安装：

```bash
brew install gh
```

## GitHub 授权

脚本启动后会先执行：

```bash
gh auth status
```

如果尚未登录，会自动进入：

```bash
gh auth login --hostname github.com --git-protocol ssh --skip-ssh-key --web
```

你只需要按终端提示复制验证码，并在浏览器中完成 GitHub 授权。

授权完成后，脚本才会继续询问版本号。

## 版本号输入

授权检查完成后，脚本会显示当前 `Info.plist` 中的版本，并提供四种版本更新方式：

```text
当前版本：0.1.0 (1)
请选择版本更新方式：
  1) 修复更新：0.1.0 -> 0.1.1
  2) 小版本更新：0.1.0 -> 0.2.0
  3) 大版本更新：0.1.0 -> 1.0.0
  4) 手动输入版本号
请输入选项 [1-4]（默认 1）：
```

推荐含义：

- 修复更新：只递增 patch，例如 `0.1.0 -> 0.1.1`
- 小版本更新：递增 minor，并把 patch 归零，例如 `0.1.0 -> 0.2.0`
- 大版本更新：递增 major，并把 minor/patch 归零，例如 `0.1.0 -> 1.0.0`
- 手动输入：自行填写完整版本号

版本号格式必须类似：

```text
0.1.1
1.0.0
```

build number 必须是整数。默认值会在当前 build number 基础上加 1。

## 打包产物

脚本会重新运行 `package_app.sh`，并生成：

```text
app/Codexling/dist/Codexling-<version>.dmg
app/Codexling/dist/Codexling-<version>.zip
```

DMG 内容包括：

- `Codexling.app`
- `Applications` 快捷方式

## GitHub Release 行为

脚本会使用 tag：

```text
v<version>
```

例如版本 `0.1.1` 对应：

```text
v0.1.1
```

如果 Release 不存在，脚本会创建新的 GitHub Release。

如果 Release 已存在，脚本会询问是否覆盖上传 DMG/ZIP，并更新 release notes。

## Release Notes

脚本会自动生成 release notes，包含：

- DMG 下载说明
- ZIP 下载说明
- ad-hoc 签名说明

## 注意事项

发布前工作区必须是干净的。如果存在未提交改动，脚本会停止。这样可以避免把错误的代码状态打进 release tag。

当前 App 使用 ad-hoc 签名，没有做 Apple notarization。因此首次打开时，macOS 可能需要用户在系统设置中手动允许。

## 常见问题

### 提示 `缺少命令：gh`

安装 GitHub CLI：

```bash
brew install gh
```

### GitHub 授权失败

重新运行脚本即可。脚本会在版本输入前再次检查授权状态。

### tag 已存在但不指向当前提交

脚本会停止。这通常说明你正在尝试复用一个已经发布过的版本号，但当前代码已经变化。

解决方式：

1. 使用新的版本号发布。
2. 或者手动检查 tag 指向，确认后再处理。

### DMG 验证失败

脚本会挂载 DMG 并检查内容。如果失败，说明打包产物不完整，需要先修复 `package_app.sh` 或构建问题。
