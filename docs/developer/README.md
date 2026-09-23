# Tomo 应用开发文档

本目录是桌面端通用开放 API 的首份文档草稿，以及开发文档站的建设方案。文档站尚未创建 React 工程或部署；通用 API 路由和调用来源单独进入实现阶段。

面向希望自行开发 Web、移动端、桌面端、CLI 或服务端应用的用户。接入方式是 HTTP + 配对 Token + SSE，不要求应用安装为 Tomo 插件。

## 阅读顺序

1. [桌面端通用开放 API](desktop-api.md)：当前真实接口、认证、数据结构、SSE、代理和应用接入示例；Web 插件托管作为可选附录。
2. [文档站调研与实施方案](documentation-web-plan.md)：React 框架选择、桌面托管、离线搜索、版本历史、发布流程和验收标准。

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

- API 文档描述核验基线下的已实现行为；实施方案中的目录、路由、设置和发布命令均为待实现设计。
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
