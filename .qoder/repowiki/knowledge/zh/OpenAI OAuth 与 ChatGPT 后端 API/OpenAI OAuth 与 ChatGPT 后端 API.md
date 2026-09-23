---
kind: external_dependency
name: OpenAI OAuth 与 ChatGPT 后端 API
slug: openai
category: external_dependency
category_hints:
    - vendor_identity
    - auth_protocol
scope:
    - '**'
---

### OpenAI 集成
- **OAuth 认证**: 使用 PKCE 流程通过 `auth.openai.com/oauth/authorize` 完成授权，本地回调地址为 `http://localhost:1455/auth/callback`
- **额度查询**: 调用 `chatgpt.com/backend-api/wham/usage` 获取主/次级额度和重置券信息
- **订阅周期**: 通过 `chatgpt.com/backend-api/subscriptions` 读取 ChatGPT Plus/Pro 订阅状态
- **Token 存储**: OAuth token 保存在 `~/Library/Application Support/Tomo/oauth_token.json`，权限设为 0600
- **客户端 ID**: 使用固定 client_id `app_EMoamEEZ73f0CkXaXp7hrann`
- **安全边界**: 不接触账号密码、浏览器 Cookie 或 MFA 代码，仅进行只读数据访问