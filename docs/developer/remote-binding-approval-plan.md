# 桌面绑定审批与签名回执

正式 HTTPS 生命周期之前，必须具备云身份校验、桌面本地审批和云绑定回执。TomoServer 当前 binding-challenges 返回 ES256 tomo-binding-identity+jwt，绑定服务器/用户/设备/设备公钥摘要/挑战/nonce/下一绑定版本/短有效期。桌面只能使用显式可信云公钥验证，不接受 token 自带密钥。

桌面将已验证身份作为有界待审批项目供本机 owner 查阅。手机号端不能直接写入 scopes/resources 或调用本机 approve。owner 选择显式权限和资源后，以已注册云服务器的私钥签名 tomo-binding-receipt+jwt，并持久写入 RemoteAuthorizationLedger；签名或本地 CAS 审批失败不能返回成功回执。回执绑定原挑战身份及 owner 选择的精确权限，有效期不超过云挑战。先有本地 ACL，后由原生回传云建立 binding。

同一挑战原样请求须归并，不因重试追加本机版本；已审批项目保存原回执供有界原样重试。过期、篡改及同挑战不同断言失败。签名密钥由正式服务器身份管理提供，不能复用开发 token/临时自动密钥。生产 TLS/云公钥更新、Keychain 服务器身份、Settings 审批 UI 和实际原生云回传仍是后续步骤。

## 当前验证

RemoteCloudGrantVerifier.verifyBindingIdentity 与 RemoteBindingApproval 已实现以上密码学/本机审批边界。批准前重新验证云信任期限，未通过 ledger CAS 不返回回执。21 项绑定审批、云 grant、持久授权与平台回执测试通过。测试密钥为临时生成，不代表正式服务器已注册。

Swift CryptoKit 实际生成的回执已交给实际 Rails Auth::Bindings.create / ruby-jwt，验证 public key RFC7638 摘要、签名、身份、挑战、精确权限及同回执重试成功；在 test 数据库事务内完整回滚。保存无私钥样本 TomoServer/test/fixtures/files/remote-binding-swift.json，复验命令（TomoServer 根目录）：

```sh
docker compose -f compose.dev.yml run --rm -e RAILS_ENV=test web bundle exec rails runner test/interop/verify_swift_binding.rb
```

该阶段尚未挂载 HTTP 配对路由；后续 HTTPS 配对通道的实现记录见下方。桌面原生设置审批、Keychain 身份或正式 TLS 生命周期仍未完成，不据此宣称完整配对完成。

## HTTPS 配对通道

固定 /api/v1/remote/bindings/nonce 以云 identityAssertion 换取绑定设备的短期 DPoP nonce。POST /api/v1/remote/bindings/requests 要求同断言与设备 DPoP（ath/method/精确 HTTPS target/nonce/重放）；返回 pending requestId，不授予业务权限。GET /api/v1/remote/bindings/requests/{challengeId} 要求 DPoP Authorization 身份断言及新的设备 proof，只允许原断言查询原挑战。批准后返回桌面回执，未批准只返回 pending，拒绝不返回回执。端口只接受 HTTPS，Origin/重复头/查询参数/不匹配断言均拒绝。

此通道仅提交和读取待审状态，owner approve/reject 不暴露为 HTTP 操作。HTTPS listener 显式注入配对 router 才启用；默认不启用、旧 plaintext 服务不挂载。

RemoteBindingRouter 与 listener 注入已实现。27 项绑定审批、DPoP、grant 交换测试通过，含临时证书与真实回环 HTTPS 上的 pending → 本机 API 批准 → approved 回执、错设备拒绝，以及已有真实 HTTPS 交换/SSE 回归。TLS 证书与 cloud/device 密钥为测试生成，未安装用户根证书；审批通过内部 owner API 模拟点击，未验收实际桌面 UI。尚未完成生产配置和自动启动。
