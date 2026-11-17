# Tomo 桌面 API 文档站

Next.js App Router 静态导出站点。唯一 API 内容源为 `docs/developer/desktop-api.md`；构建时由 Markdown AST 生成章节和内容摘要，不维护第二套接口表。

```sh
pnpm install --frozen-lockfile
pnpm dev       # 本机开发端口 58352
pnpm build
pnpm verify
```

`out/` 是完整离线站点，桌面打包脚本将其复制到 `Contents/Resources/ApiDocs`。运行时由独立 Swift 文档服务托管，默认回环端口 58351；不需要 Node，不开放业务 API，不注入真实 Token。局域网查阅必须在桌面设置中明确打开。

当前仅提供未发布 `next` 工作区文档，页面记录原始 Markdown 的 SHA-256 和构建源码基线。尚未冻结正式历史版本，也不虚构历史版本；发布快照与版本切换仍需后续完成。

本地搜索按章节索引匹配中文、路径和字段，可点击结果定位正文。代码支持复制，表格可横向滚动，支持浅色/深色和手机目录。站点不提供在线接口执行或凭证输入功能。
