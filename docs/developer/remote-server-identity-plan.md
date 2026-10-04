# 桌面服务器签名身份

正式服务器身份与 HTTPS 证书分开管理。桌面生成 P-256 签名密钥，保存在本机非同步 Keychain，重新启动复用同一密钥；损坏、锁定、存储失败必须报告错误，不能静默换钥。首次创建采用原子 insert-if-absent，竞争者读取获胜密钥。

云端登记遵循 `Auth::Servers`：在原生受信任云端会话中获取 challenge，校验 challenge ID、当前 session ID、ES256、五分钟有效期及固定 `TomoServer/server-registration/v1` 命名空间，签署原始 signingInput。上传公开 PEM 与标准 Base64 DER ECDSA 签名。不能接受设备登记文本、任意签名文本或 WebCore 提供的服务器密钥。

登记成功后，只有云端登记的服务器 ID、公钥摘要与本机密钥相符，才创建配对审批服务。审批使用同一持久密钥，私钥不提供给 WebCore，不提供通用远程签名接口。

此阶段先实现身份存储、登记证明和审批服务工厂，通过真实密码学测试及 Ruby 验证证明兼容性。桌面云端登录、登记网络协调、受信 HTTPS 生命周期和 Settings 审批界面仍需后续接入。

## 当前验证

- `swift test --filter 'RemoteServerIdentityTests|RemoteBindingApprovalTests'`：10 项通过。涵盖重启复用、原子插入竞争、损坏/不可用存储拒绝换钥、精确挑战的真实 DER 签名、错误会话/命名空间/算法/期限/非规范 nonce 拒绝，以及登记摘要不符不能建立审批服务。存储测试为内存实现，未读写用户真实 Keychain。
- TomoServer `docker compose -f compose.dev.yml run --rm -e RAILS_ENV=test web bundle exec rails runner test/interop/verify_swift_server_identity.rb`：实际 OpenSSL 与 Auth::Servers.register 接受 Swift CryptoKit 证明，公钥摘要一致、重放拒绝、事务回滚。公开 fixture 不包含私钥。
- 生产 Keychain 解锁/重签后权限、桌面 OTP 登录与实际云登记、可信 HTTPS 生命周期、Settings 本机审批 UI 未完成，不能据此称正式端到端已完成。
