# Tomo 应用开发文档

本目录维护桌面端通用开放 API 的单一 Markdown 内容源。Next.js 静态文档工程已创建于 `app/api-docs`，默认由独立 Swift 端口 58351 提供离线查阅，桌面设置和打包流程已接入；正式 App 打包/UI 和历史版本冻结仍需验收。

面向希望自行开发 Web、移动端、桌面端、CLI 或服务端应用的用户。接入方式是 HTTP + 配对 Token + SSE，不要求应用安装为 Tomo 插件。

## 阅读顺序

1. [桌面端通用开放 API](desktop-api.md)：当前真实接口、认证、数据结构、SSE、代理和应用接入示例；Web 插件托管作为可选附录。
2. [文档站调研与实施方案](documentation-web-plan.md)：历史框架调研与验收要求；当前 Next.js 实施以 API 第 21 节和工程 README 为准。

路由迁移更新：在上述基线之后，工作区已统一 /api/v1/、删除 /mobile/ 并增加调用来源；这些改动尚未冻结成正式文档版本。

## 核验基线

| 项目 | 基线 |
| --- | --- |
| 核验日期 | 2026-09-18 |
| 桌面端版本 | Info.plist：0.8.3，build 100 |
| 源码提交 | `e79c2eba10dce96a9188538711a3a75fdc5abc33` |
| snapshot schemaVersion | 1 |
| 文档状态 | 草稿，尚未发布首个冻结版本 |

版本号来自当前源码，不代表用户机器安装的应用已经包含全部接口。接入前需要确认实际安装版本和接口能力。

## 文档规则

- API 文档描述核验基线与标明日期的工作区行为；实现状态须逐项核对，历史调研方案不能作为已交付证明。
- 示例只使用虚构数据和 Token 占位符，不包含真实账号、配对凭证或供应商密钥。
- 文档版本、桌面应用版本、snapshot schemaVersion 分别管理，不混为一个版本。
- 历史版本必须对应可核验的源码与发布记录；不能把今天的接口说明套用到旧版本。
- 首次实现文档站时，将 API 草稿拆分成导航章节，形成首个正式文档快照；目前不提前制造历史版本。

## 当前事实来源

- [MobileSyncServer.swift](../../app/Tomo/Sources/Tomo/MobileSyncServer.swift)：HTTP 路由、认证、JSON 结构、SSE、代理和静态资源。
- [MobileSyncManager.swift](../../app/Tomo/Sources/Tomo/MobileSyncManager.swift)：快照来源、连接字段、工作时长和凭证导出。
- [WebPluginInstaller.swift](../../app/Tomo/Sources/Tomo/WebPluginInstaller.swift)：安装目录、ZIP 和 manifest。
- [MobileSyncServerTests.swift](../../app/Tomo/Tests/TomoTests/MobileSyncServerTests.swift)：现有服务测试。

源码与文档冲突时，先核对对应提交下的行为，再修正文档。此目录不承诺尚未实现的多插件安装、任务操作、历史任务 API 或细粒度 Token 权限。
