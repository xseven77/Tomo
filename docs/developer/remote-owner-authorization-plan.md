# 本机设备审批与撤销

1. 原生 Settings 从当前服务读取待配对云身份、设备公钥摘要、已持久批准设备及当前注册 runtime；不公开 HTTP owner 接口，不显示私钥/断言/回执。
2. 用户逐项选择 runtime 与 discovery/read/write/approve。默认不选择资源，控制权限默认关闭；仅允许当前 runtime 实际声明的动作对应权限，禁止空资源或任意路径。批准使用显示时的 localVersion 做 CAS，变化后要求刷新。
3. 拒绝只结束待配对请求；撤销持久 binding 并递增本机版本，现有 grant/access 后续校验立即失败。旧批准回执不能在撤销后继续返回。
4. 设置显示服务停止/刷新/操作错误，状态和操作按当前服务代次隔离。先进行真实签名/SQLite/HTTPS 回归，再继续真实 live runtime 与原生业务 RPC；本机 UI 实机和云确认仍需验证。

## 2026-10-04 实现与证据

RemoteOwnerSettingsView 已接入正在运行的原生安全服务设置。五秒刷新待请求与持久设备投影，显示经云验签的设备名、用户邮箱、公钥摘要和期限；已批准项显示 user/device、scope、本机版本、撤销状态。资源默认不选，write/approve 默认关闭，只显示当前已注册 runtime 的可能动作所对应的可选范围；后续执行仍受实际 command source 和 grant 约束。服务实例租约阻止旧页面操作新服务，版本 CAS 阻止覆盖其他本机审批。

RemoteProductionService 提供 native-only ownerState/Approve/Reject/Revoke，不添加 HTTP owner 入口，不向 Settings 返回断言、签名回执或私钥。资源须来自实际 registry；主机级目录没有被自动授权为 workspace。ledger 提供本机列表/单项投影，仍持久存储 ACL；撤销增版本。RemoteBindingApproval 的缓存批准与查询重新检查本机 binding，撤销或改版后不返回旧回执。

`swift test --filter 'RemoteBindingApprovalTests|RemoteAuthorizationLedgerTests|RemoteProductionServiceTests|RemoteProductionManagerTests|RemoteRuntimeScopeRegistryTests|RemoteGrantExchangeTests|RemoteHTTPSListenerTests|RemoteOperationServiceTests'`：50 项 XCTest + 7 项 Swift Testing 通过。新增缓存撤销用例；实际 HTTPS 装配测试经 manager 执行批准与撤销，验证未知资源、超出 read-only 能力的 write、过时版本与错误实例租约均被拒绝。随后 3 项 RemoteProductionService 回归通过，新增真实 HTTPS 撤销查询： fresh DPoP 仍返回 403，body 不含原批准 receipt。

首轮旧 TLS fixture 在 SecIdentityCopyCertificate 路径报 invalidConfiguration；临时证书改用唯一主题/序列号并增加实际 OSStatus/openssl 状态诊断，后续上述两轮通过。这不证明原失败根因，也不替代生产证书验收；未安装根证书、未操作用户 Keychain。

云 HTTP 仍使用替身，UI 实机交互、真实云绑定确认、Apple/Android 设备证明和 live Agent 发送/回复/中断闭环仍待完成。当前 Release 包尚未更新，完整 Goal 保持 active。
