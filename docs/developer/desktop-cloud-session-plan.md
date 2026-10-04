# 桌面云会话与服务器登记

原生桌面云账号与供应商账号隔离。受信 HTTPS issuer 由桌面配置提供，固定 `/api/v1` 路径，禁止重定向转发凭据。邮件 OTP 使用随机 PKCE，云会话保存在本机非同步 Keychain，WebCore 只接收无凭据摘要。

服务拥有 login challenge、当前会话和请求代次。退出、过期、撤销或更换登录使在途结果失效。OTP 与刷新 token 一次使用；丢失回复不能重放。刷新前清除旧 token，验证同 user/session 与更换后的 access/refresh token。迟到登录成功应尽力撤销。

服务器登记先获取当前会话挑战，使用 RemoteServerIdentity 校验并签署，随后上传 PEM/DER。每个 await 后复核代次、会话与有效期；响应的 server ID、登记时间、名称与本机摘要必须匹配。此元数据仅表示已登记，不代表 VIP、设备证明或桌面 ACL 授权。生产 HTTPS 和本机审批必须另行建立。

先实现原生协调服务与注入 HTTP/存储的真实签名测试，再接入 Settings 登录与审批。不得把测试云地址、OTP 码或测试 TLS 信任作为正式默认配置。

## 阶段验证

`swift test --filter 'DesktopCloudSessionTests|RemoteServerIdentityTests|RemoteBindingApprovalTests'` 最终 20 项通过，其中 DesktopCloudSessionTests 10 项。覆盖 PKCE 计算、会话持久恢复、实际 CryptoKit DER 登记签名、OTP 不重放、错误挑战会话/摘要、撤销清理、退出发生在挑战/登记/登录 await 时的迟到结果、在途 access 过期、轮换 token、丢失 refresh 回复不重用、issuer 限制及跨 issuer 存储清理。HTTP 与存储由测试替身注入，未发送真实邮件或访问生产云；用户真实 Keychain 未被测试读写。

URLSession 默认传输使用系统 TLS 校验、禁止重定向、无 cookie/cache、30 秒请求超时和 64 KiB 流式响应上限。网络层仍待真实受信 HTTPS 环境验证。初次协调服务验证时 Settings 尚无登录入口；后续接入结果见下节。服务器元数据不跨进程持久保存，重启需要重新登记同一签名公钥；Rails 同用户同公钥可返回同 server ID。生产 HTTPS、JWKS 更新与 owner 审批 UI 继续保留为完整 Goal 的待办。

## Settings 接入

移动端伴生设置增加 DesktopCloudSettingsView，由 DesktopCloudManager.shared 持有原生协调服务。用户配置受信 HTTPS issuer 后可获取邮件验证码、登录、查看用户/会话期限、登记本机服务器、查看 server ID/公钥摘要、刷新、退出或更换云服务。没有测试云地址默认值；UserDefaults 只保存 issuer，凭据仍归 Keychain。打开已有配置会检查/恢复原生会话。

主线程观察状态与请求代次保证旧操作不覆盖退出或新配置后的界面。退出按钮在登录/登记中仍可使用；Keychain 删除失败保留配置与明确提示，允许解锁后重试，并尽力云撤销。Settings 未提供 token/私钥/任意签名字段，也未自动开启 HTTPS 监听或扩大权限。

最终 26 项 DesktopCloudManager/Session/RemoteServerIdentity/BindingApproval 测试通过，新增 6 项 manager 测试覆盖完整用户操作、同 issuer 恢复、退出与邮件/登记响应竞争、撤销，以及 Keychain 删除失败后的清理重试。swift test 编译了新增 SwiftUI 设置源码。Mac 当前锁定，CUA 实机窗口显示、真实 Keychain 和邮件云连接未验收；旧 App/ZIP/DMG 未更新。生产安全监听、JWKS 维护与本机 owner 审批界面仍待接入。
