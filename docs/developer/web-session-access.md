# 网页会话授权

本机浏览器里的 TomoGo 网页，用这套流程向桌面申请会话访问。默认关闭，由桌面设置里的开关开启。

## 使用流程

1. 桌面设置 → 手机会话页：打开「允许网页使用会话（仅本机）」。
2. 网页会话页点「连接桌面会话」，页面显示一个 4 位核对码。
3. 桌面弹出确认窗，写明来源和核对码。核对一致，点「允许 1 小时」。默认按钮是「拒绝」，误按回车不会放行。
4. 网页拿到 5 分钟有效的凭证，并在到期前 1 分钟自动续期，直到 1 小时的窗口结束。同一标签页刷新后会自动恢复；新开标签页要再点一次允许。

## 路由

都在桌面服务（默认 58350）上，只接受本机请求。请求必须带 `Origin`。

| 路由 | 说明 |
| --- | --- |
| `POST /api/v1/web-session/request` | 发起请求。返回 `requestId`、核对码和 120 秒有效期；同一来源重复请求得到同一个 |
| `GET /api/v1/web-session/request/<id>` | 轮询：`pending`、`denied`、`expired`，或 `approved`。`approved` 带 `token`、`expiresAt`、`windowExpiresAt`、`mode` 和 `renewal`，续期密钥只在第一次返回 |
| `POST /api/v1/web-session/renew` | `Authorization: Bearer <renewal>`，换一个新凭证 |
| `DELETE /api/v1/web-session/current` | 同样用续期密钥，网页主动断开 |

得到的 `token` 就是已有的开发凭证（`tomo_remote_dev_…`），用来访问 `/api/v1/remote/*`。

## 隐私与安全约束

- **只在本机**：对端必须是回环地址，`Host` 必须是 `127.0.0.1`、`localhost` 或 `[::1]` 加本服务端口。局域网设备和 DNS 重绑定的页面都会被拒绝。
- **只认本机网页**：来源必须是 `http` 的 `localhost`、`127.0.0.1` 或 `[::1]`。互联网上的网站不可能有这些来源，所以连让桌面弹窗都做不到。被拒绝的请求不会产生任何确认窗。
- **来源绑定**：凭证绑定批准时的来源，换一个来源就是 403。CORS 只回显该来源，不用通配。
- **短命**：凭证 5 分钟（`RemoteAccessStore` 的硬上限），窗口 1 小时，最多同时 4 个窗口。凭证不会比窗口活得更久。
- **续期密钥**：桌面只保存它的哈希；网页只放在当前标签页的 `sessionStorage`，不进 `localStorage`，也不跟服务器配置一起保存。
- **最小权限**：只给列会话、读历史；数据源支持时再加发送、中断。审批和回答问题不给，仍在桌面上处理。
- **数据源按需注册**：有窗口时才把 Codex 会话目录注册到这个服务，最后一个窗口结束时注销。
- **随时失效**：窗口到点、桌面上点「断开」、网页自己断开、关掉开关、重启服务器或退出 Tomo，都会立即撤销所有凭证。
- **限频**：每分钟最多 10 次请求，同时最多 3 个等待确认的请求。

## 代码

- `WebSessionAccess.swift`：请求、核对码、窗口、续期和撤销，以及按需注册的会话数据源。
- `WebSessionAccessManager.swift`：桌面开关、确认窗和设置页状态。
- `MobileSyncServer.swift`：四条路由、本机和来源校验、CORS。
- 网页端：`webSessionGrant.ts`（请求、轮询、续期）、`RemoteClient.renewDevelopmentConnection`（换凭证但保留会话状态）、`WebSessionConnectPanel`（会话页上的按钮）。

## 当前限制

- 数据源目前只有 ChatGPT / Codex 的只读目录，所以网页只能查看。发送和中断要接入手机会话的可写运行时。
- 手机用的设备授权没有改动，仍然只给原生 App。
