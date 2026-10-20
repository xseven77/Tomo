# 正式远程 HTTPS 服务装配

正式监听与旧 plaintext MobileSyncServer 分离。启动必须来自原生当前云会话的 RegisteredServer、同一 Keychain 签名身份、显式 provisioned TLS identity、受信 HTTPS issuer 和本机注册的真实 read adapters。不能使用旧开发 srv_ ID、空假 handler、默认放行平台证明或合成用户。

一个服务生命周期拥有 JWKS 维护、持久 ACL ledger、DPoP、grant exchange、绑定审批、runtime/read registry、session journal 服务、operation store/service 和 HTTPS listener。operation 授权复用正式 principal validator，owner 从已验 grant receipt 得到云 user/device；开发授权仍复用自己的 store。未注册执行 source 的动作拒绝，不把目录读能力当作 live control。

停止关闭监听、连接/SSE 与命令 admission，并失效 JWKS 信任；不因此删除持久 ACL 或启动新的 Agent。启动失败需清理已创建资源。监听实际状态应有 starting/running/stopped/failed 事件，端口占用或运行中失败不能继续显示 running。

此阶段实现装配服务与真实回环 HTTPS 测试，后续接 Settings TLS 选择、owner 审批/撤销、真实 runtime 生命周期、退出/换云停止钩子及原生客户端闭环。

## 装配阶段验证

RemoteProductionService.start 要求原生当前已登记服务器、同 issuer、匹配签名密钥、显式 TLS identity 和非空本机 read adapters。装配持久 ledger、JWKS 维护、真实 RemoteReadService/runtime registry、session journal、operation store/service、DPoP、平台回执校验、配对 router 与 HTTPS。无开发 server ID 或放行 verifier。命令 service 使用 RemotePrincipalValidator 共用边界，正式 owner 来自 grant receipt 的云 user/device。

监听有实际 starting/running/stopped/failed AsyncStream；网络终止通知服务清理。停止先关闭命令 admission、清除内存正式 access，随后断开 HTTP/SSE、失效云信任和清理命令任务；释放服务也触发清理，不删持久 ACL 或启动新的 Agent。

最终 `swift test --filter 'RemoteProductionServiceTests|RemoteHTTPSListenerTests|RemoteBindingApprovalTests|RemoteOperationServiceTests|RemoteGrantExchangeTests|RemoteCloudTrustTests'`：31 项 XCTest + 7 项 Swift Testing 通过。新增 3 项装配测试使用 memory-only 临时证书、真实回环 HTTPS、CryptoKit 签名、SQLite 支持的 ChatGPT 目录 adapter；覆盖未授权业务 401、HTTPS 配对提交、原生内部批准、登记同 key 签名、scope 读权限、停止与已停验签拒绝、issuer/key 不符，以及启动 JWKS await 中退出。另新增 2 项 grant owner/shutdown 测试。

测试云登录/JWKS HTTP 为替身；没有真实邮件、Apple 设备证明或生产云。首轮合测中测试误读 nonce JSON 已按实际 DPoP-Nonce 响应头修正；另一次旧 TLS fixture 创建报 invalidConfiguration，后续三轮相关 TLS 测试通过，实机证书稳定性仍需生产验证。临时证书未安装用户根证书、未操作用户 Keychain。

目前 Settings 还没有 TLS 身份选择和正式服务启动入口；本机审批仍由内部 native API 验证，不等于 owner UI 已完成。真实 live runtime/journal/command sources、云退出立即停止钩子、证书管理、owner ACL 撤销、原生 App 连接与完整会话控制闭环、更新打包仍待完成。


## 手机会话的钥匙串交互

手机会话在启动恢复、网络变化时先以禁止交互的方式读取桌面签名身份；钥匙串锁定、应用签名变化或用户拒绝时，设置页提示「授权钥匙串并重试」。只有用户主动开启或重试才允许系统弹窗。成功读取后复用进程内缓存，拒绝不会触发自动交互重试，也不会删除或重新生成已有身份。

该身份位于旧版登录钥匙串。`TomoKeychain` 统一串行化 App 内的 SecItem 操作，在同步后台读取范围内保存、关闭、恢复旧版钥匙串交互策略，避免影响并发的账号操作。不能仅依赖针对数据保护钥匙串的 LAContext 参数，也不能通过跳过受保护条目把拒绝误当成身份不存在。

必要的 `SecKeychainGet/SetUserInteractionAllowed` 调用隔离在 `CTomoKeychain` C 兼容层中，仅在这两个封装内局部关闭弃用诊断，不关闭项目级警告。待 Apple FB16959400 对文件钥匙串的无交互访问问题解决后再替换此兼容层。

本地 ad-hoc 签名会随构建变化；本次优化避免自动弹窗，并不让旧钥匙串授权跨任意新构建生效。稳定发行应使用同一代码签名身份。
